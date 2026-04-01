import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../models/prompt_stack_config.dart';
import '../services/remote_agent_service.dart';
import '../services/local_database_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/token_service.dart';
import '../services/model_registry.dart';
import '../models/model_definition.dart';
import '../models/llm_provider_config.dart';
import '../services/skill_registry.dart';
import '../services/channel_tunnel_service.dart';
import '../services/local_network_service.dart';
import '../main.dart' show globalACPServer, kAcpServerPortKey, kAcpServerDefaultPort, kAcpServerEnabledKey;
import 'skill_select_screen.dart';
import 'model_select_screen.dart';
import 'cli_command_select_screen.dart';
import 'chat_screen.dart';
import 'cli_config_management_screen.dart';
import '../utils/layout_utils.dart';

/// 远端 Agent 详情页面（从聊天页进入）
class RemoteAgentDetailScreen extends StatefulWidget {
  final RemoteAgent agent;

  const RemoteAgentDetailScreen({
    super.key,
    required this.agent,
  });

  @override
  State<RemoteAgentDetailScreen> createState() =>
      _RemoteAgentDetailScreenState();
}

class _RemoteAgentDetailScreenState extends State<RemoteAgentDetailScreen> {
  late RemoteAgent _agent;
  bool _isDeleting = false;
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isRegeneratingToken = false;

  // 独立刷新状态（外部访问区域）
  Future<List<String>>? _lanAddressesFuture;
  Future<String?>? _publicUrlFuture;
  bool _isRefreshingLan = false;
  bool _isRefreshingPublicUrl = false;

  // 编辑用的控制器
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  late TextEditingController _endpointController;
  late TextEditingController _tokenController;
  late TextEditingController _systemPromptController;
  late TextEditingController _remoteAgentIdController;
  String _editingAvatar = '';

  // 主模型选择（从 ModelRegistry 中选择）
  String? _selectedMainModelId;

  ProtocolType _editingProtocol = ProtocolType.acp;
  ConnectionType _editingConnectionType = ConnectionType.websocket;

  // Skills 配置
  Set<String> _enabledSkills = {};

  // Tool Models 配置（toolName → 场景描述）
  Map<String, String> _toolModelScenarios = {};

  // CLI 命令配置
  Set<String> _enabledCliCommands = {};

  // 本地上传的头像文件路径（相对路径）
  String? _localAvatarPath;

  // 外部访问相关（用于编辑模式）
  bool _editingAllowExternalAccess = false;

  // Channel 配置编辑用控制器
  late TextEditingController _channelServerUrlController;
  late TextEditingController _channelIdController;
  late TextEditingController _channelSecretController;
  late TextEditingController _channelEndpointController;

  final ImagePicker _imagePicker = ImagePicker();
  final LocalFileStorageService _fileStorage = LocalFileStorageService();

  /// True when this agent should be treated as a local LLM agent.
  /// She is always treated as local even before a model is configured.
  bool get _isLocalMode =>
      _agent.metadata['llm_provider'] != null ||
      _agent.metadata['is_she'] == true;

  @override
  void initState() {
    super.initState();
    _agent = widget.agent;
    _initEditingControllers();
    _lanAddressesFuture = _loadLanAddresses();
    _publicUrlFuture = _loadPublicUrl();
    // Auto-start tunnel if this agent has external access enabled with channel config
    _maybeStartTunnel(_agent);
  }

  /// Start the channel tunnel if the agent has external access enabled and a
  /// channel config, and the tunnel is not already running.
  void _maybeStartTunnel(RemoteAgent agent) {
    if (!agent.allowExternalAccess) return;
    final cfg = agent.channelConfig;
    if (cfg == null) return;
    final tunnelService = ChannelTunnelService.instance;
    if (!tunnelService.isRunning) {
      tunnelService.startWithConfig(cfg);
    }
  }

  void _initEditingControllers() {
    _nameController = TextEditingController(text: _agent.name);
    _bioController = TextEditingController(text: _agent.bio ?? '');
    _endpointController = TextEditingController(text: _agent.endpoint);
    _tokenController = TextEditingController(text: _agent.token);
    _systemPromptController = TextEditingController(
      text: _agent.metadata['system_prompt'] as String? ?? '',
    );
    _remoteAgentIdController = TextEditingController(
      text: (_agent.metadata['target_agent_id'] as String?) ?? '',
    );
    _editingAvatar = _agent.avatar;
    _localAvatarPath = null;
    _editingProtocol = _agent.protocol;
    _editingConnectionType = _agent.connectionType;
    _editingAllowExternalAccess = _agent.allowExternalAccess;

    // Load skills from metadata
    _enabledSkills = _agent.enabledSkills;

    // Load tool models from metadata
    _toolModelScenarios = {
      for (final t in _agent.enabledToolModels) t: _agent.toolModelScenarios[t] ?? '',
    };

    // Load CLI commands from metadata
    _enabledCliCommands = _agent.enabledCliCommands;

    // Match main model — prefer stored main_model_id, then fall back to
    // matching by llm_model + llm_api_base for legacy agents.
    _selectedMainModelId = null;
    final storedId = _agent.metadata['main_model_id'] as String?;
    if (storedId != null && ModelRegistry.instance.getById(storedId) != null) {
      _selectedMainModelId = storedId;
    } else {
      final savedModel = _agent.metadata['llm_model'] as String?;
      final savedBase = _agent.metadata['llm_api_base'] as String?;
      if (savedModel != null) {
        for (final def in ModelRegistry.instance.definitions) {
          if (def.route.model == savedModel && def.route.apiBase == savedBase) {
            _selectedMainModelId = def.id;
            break;
          }
        }
        if (_selectedMainModelId == null) {
          for (final def in ModelRegistry.instance.definitions) {
            if (def.route.model == savedModel) {
              _selectedMainModelId = def.id;
              break;
            }
          }
        }
      }
    }

    // Channel config controllers
    final cfg = _agent.channelConfig;
    _channelServerUrlController = TextEditingController(text: cfg?.serverUrl ?? '');
    _channelIdController = TextEditingController(text: cfg?.channelId ?? '');
    _channelSecretController = TextEditingController(text: cfg?.secret ?? '');
    _channelEndpointController = TextEditingController(text: cfg?.channelEndpoint ?? '');

    // Load She-exclusive feature toggles from PromptStackConfig
    // (Removed - She CLI commands are now managed in CLI Management page)
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _endpointController.dispose();
    _tokenController.dispose();
    _systemPromptController.dispose();
    _remoteAgentIdController.dispose();
    _channelServerUrlController.dispose();
    _channelIdController.dispose();
    _channelSecretController.dispose();
    _channelEndpointController.dispose();
    super.dispose();
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _initEditingControllers();
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _initEditingControllers();
      // Refresh public URL section after edit is cancelled (channel config may have changed)
      _publicUrlFuture = _loadPublicUrl();
    });
  }

  Future<void> _saveEdit() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.agentDetail_nameRequired),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Token is required for remote agents (She and local-LLM agents don't need one)
    final isRemoteAgent = !_isLocalMode;
    final newToken = _tokenController.text.trim();
    if (isRemoteAgent && newToken.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.agentDetail_tokenRequired),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      // 如果有本地上传的图片，先解析出完整路径存储
      String avatar = _editingAvatar;
      if (_localAvatarPath != null) {
        final fullPath = await _fileStorage.getFullPath(_localAvatarPath!);
        avatar = fullPath;
      }

      // Build updated metadata
      final Map<String, dynamic> metadata = Map<String, dynamic>.from(_agent.metadata);

      // System prompt
      final systemPrompt = _systemPromptController.text.trim();
      if (systemPrompt.isNotEmpty) {
        metadata['system_prompt'] = systemPrompt;
      } else {
        metadata.remove('system_prompt');
      }

      // LLM config
      if (_selectedMainModelId != null) {
        final mainModel = ModelRegistry.instance.getById(_selectedMainModelId!);
        if (mainModel != null) {
          final route = mainModel.route;
          // Only store the model definition ID — full config is looked up at
          // call time via ModelRegistry. llm_provider is kept solely as the
          // sentinel for isLocalAgent().
          metadata['main_model_id'] = _selectedMainModelId!;
          metadata['llm_provider'] = (route.provider != null && route.provider!.isNotEmpty)
              ? route.provider!
              : 'openai';
          // Remove any previously-stored redundant fields so they can't
          // interfere with the ModelRegistry lookup.
          metadata.remove('llm_model');
          metadata.remove('llm_api_base');
          metadata.remove('llm_api_key');
        }

        // Save skills
        if (_enabledSkills.isNotEmpty) {
          metadata['enabled_skills'] = _enabledSkills.toList();
        } else {
          metadata.remove('enabled_skills');
        }

        // Save tool models
        if (_toolModelScenarios.isNotEmpty) {
          metadata['enabled_tool_models'] = _toolModelScenarios.keys.toList();
          final nonEmptyScenarios = Map<String, String>.fromEntries(
            _toolModelScenarios.entries.where((e) => e.value.isNotEmpty),
          );
          if (nonEmptyScenarios.isNotEmpty) {
            metadata['tool_model_scenarios'] = nonEmptyScenarios;
          } else {
            metadata.remove('tool_model_scenarios');
          }
        } else {
          metadata.remove('enabled_tool_models');
          metadata.remove('tool_model_scenarios');
        }

        // Save CLI commands
        if (_enabledCliCommands.isNotEmpty) {
          metadata['enabled_cli_commands'] = _enabledCliCommands.toList();
        } else {
          metadata.remove('enabled_cli_commands');
        }
      } else {
        // No model selected — clear LLM config
        metadata.remove('llm_provider');
        metadata.remove('main_model_id');
        metadata.remove('llm_model');
        metadata.remove('llm_api_base');
        metadata.remove('llm_api_key');
      }

      // Save allow_external_access for local agents
      if (_isLocalMode || _selectedMainModelId != null) {
        metadata['allow_external_access'] = _editingAllowExternalAccess;
      }

      // Save channel config for local agents
      if (_editingAllowExternalAccess &&
          _channelServerUrlController.text.trim().isNotEmpty &&
          _channelIdController.text.trim().isNotEmpty) {
        final rawChannelId = _channelIdController.text.trim();
        // Validate: channel ID must not contain spaces (common paste mistake)
        if (rawChannelId.contains(' ')) {
          setState(() => _isSaving = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Channel ID 格式无效，不能包含空格'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
        final channelConfig = ChannelTunnelConfig(
          serverUrl: _channelServerUrlController.text.trim(),
          channelId: rawChannelId,
          secret: _channelSecretController.text.trim(),
          channelEndpoint: _channelEndpointController.text.trim().isNotEmpty
              ? _channelEndpointController.text.trim()
              : null,
          autoConnect: false,
        );
        metadata['channel_config'] = channelConfig.toJson();
      } else if (!_editingAllowExternalAccess) {
        // Clear channel config when external access is disabled
        metadata.remove('channel_config');
      }

      // Save remote agent ID (target_agent_id)
      final remoteAgentId = _remoteAgentIdController.text.trim();
      if (remoteAgentId.isNotEmpty) {
        metadata['target_agent_id'] = remoteAgentId;
      } else {
        metadata.remove('target_agent_id');
      }

      // Note: She prompt stack configuration is now managed in CLI Management page

      final updatedAgent = _agent.copyWith(
        name: name,
        bio: _bioController.text.trim().isEmpty ? null : _bioController.text.trim(),
        avatar: avatar,
        endpoint: _endpointController.text.trim(),
        protocol: _editingProtocol,
        connectionType: _editingConnectionType,
        token: newToken.isNotEmpty ? newToken : null,
        metadata: metadata,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);
      final agentService = RemoteAgentService(dbService, tokenService);
      await agentService.updateAgent(updatedAgent);

      setState(() {
        _agent = updatedAgent;
        _isEditing = false;
        _isSaving = false;
        // Refresh public URL with new channel config
        _publicUrlFuture = _loadPublicUrl();
      });

      // Start or stop the tunnel based on the updated agent config
      _maybeStartTunnel(updatedAgent);
      // If external access was disabled, stop any running tunnel for this agent
      if (!_editingAllowExternalAccess) {
        final tunnelService = ChannelTunnelService.instance;
        if (tunnelService.isRunning) {
          // Only stop if no other agent has a channel config that needs the tunnel
          // (for simplicity, we stop it; it will be restarted if another agent needs it)
          tunnelService.stop();
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_saveSuccess)),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.agentDetail_saveFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Color _getStatusColor(AgentStatus status) {
    switch (status) {
      case AgentStatus.online:
        return Colors.green;
      case AgentStatus.offline:
        return Colors.orange;
      case AgentStatus.error:
        return Colors.red;
    }
  }

  Future<void> _deleteAgent() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.agentDetail_confirmDelete),
        content: Text(
          l10n.agentDetail_deleteContent(_agent.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.agentDetail_deleteAgent),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);

    try {
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);
      final agentService = RemoteAgentService(dbService, tokenService);
      await agentService.deleteAgent(_agent.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_deleted(_agent.name))),
        );
        Navigator.pop(context, 'deleted');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.agentDetail_deleteFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startConversation() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          agentId: _agent.id,
          agentName: _agent.name,
          agentAvatar: _agent.avatar,
        ),
      ),
    );
  }

  /// Regenerate the agent's token (both local and remote agents).
  Future<void> _regenerateToken() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.agent_regenerateTokenConfirmTitle),
        content: Text(l10n.agent_regenerateTokenConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(l10n.agent_regenerateToken),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRegeneratingToken = true);
    try {
      final dbService = LocalDatabaseService();
      final tokenService = TokenService(dbService);
      final agentService = RemoteAgentService(dbService, tokenService);
      final newToken = await agentService.regenerateToken(_agent.id);
      final updatedAgent = _agent.copyWith(token: newToken);
      setState(() {
        _agent = updatedAgent;
        _isRegeneratingToken = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agent_tokenRegenerated)),
        );
      }
    } catch (e) {
      setState(() => _isRegeneratingToken = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.agent_tokenRegenerateFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ==================== 头像选择 ====================

  void _showAvatarPicker() {
    final l10n = AppLocalizations.of(context);
    LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: Text(l10n.agentDetail_selectBuiltinAvatar),
            onTap: () {
              Navigator.pop(ctx);
              _showBuiltinAvatarPicker();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.agentDetail_selectFromGallery),
            onTap: () {
              Navigator.pop(ctx);
              _pickImageFromGallery();
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: Text(l10n.agentDetail_takePhoto),
            onTap: () {
              Navigator.pop(ctx);
              _pickImageFromCamera();
            },
          ),
        ],
      ),
    );
  }

  void _showBuiltinAvatarPicker() {
    final l10n = AppLocalizations.of(context);
    final avatars = [
      '🤖', '🦾', '🧠', '💡', '🌟', '⚡', '🔮', '🎯',
      '🚀', '🛸', '🌈', '🔥', '💎', '🎨', '🎭', '🎪',
      '🐱', '🐶', '🦊', '🐼', '🦉', '🦋', '🐝', '🐙',
      '👤', '👩‍💻', '🧑‍🔬', '🧑‍🚀', '🧙', '🥷', '🦸', '🤹',
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.addAgent_selectAvatar),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: avatars.length,
            itemBuilder: (context, index) {
              final avatar = avatars[index];
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _editingAvatar = avatar;
                    _localAvatarPath = null;
                  });
                  Navigator.pop(ctx);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _editingAvatar == avatar && _localAvatarPath == null
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      avatar,
                      style: const TextStyle(fontSize: 32),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.common_cancel),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImageFromGallery() async {
    final l10n = AppLocalizations.of(context);
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      await _savePickedImage(File(image.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_galleryFailed('$e')), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickImageFromCamera() async {
    final l10n = AppLocalizations.of(context);
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (image == null) return;
      await _savePickedImage(File(image.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_cameraFailed('$e')), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _savePickedImage(File imageFile) async {
    final l10n = AppLocalizations.of(context);
    try {
      final relativePath = await _fileStorage.saveImage(
        imageFile,
        type: ResourceType.avatars,
      );
      final fullPath = await _fileStorage.getFullPath(relativePath);
      setState(() {
        _localAvatarPath = relativePath;
        _editingAvatar = fullPath;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_saveImageFailed('$e')), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ==================== 头像展示 ====================

  /// 判断 avatar 是否为本地文件路径
  bool _isLocalFilePath(String avatar) {
    return avatar.startsWith('/') && !avatar.startsWith('http');
  }

  /// 判断 avatar 是否为网络 URL
  bool _isNetworkUrl(String avatar) {
    return avatar.startsWith('http://') || avatar.startsWith('https://');
  }

  Widget _buildAvatarWidget(String avatar, double size) {
    final borderRadius = BorderRadius.circular(size * 0.25);
    if (_isLocalFilePath(avatar)) {
      final file = File(avatar);
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Icon(Icons.smart_toy, size: size * 0.6);
          },
        ),
      );
    } else if (_isNetworkUrl(avatar)) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.network(
          avatar,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Icon(Icons.smart_toy, size: size * 0.6);
          },
        ),
      );
    } else {
      // Emoji
      return Text(
        avatar,
        style: TextStyle(fontSize: size * 0.4),
      );
    }
  }

  // ==================== Build ====================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.agentDetail_editTitle : l10n.agentDetail_title),
        centerTitle: true,
        actions: [
          if (!_isEditing && !_isDeleting)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.agentDetail_editTooltip,
              onPressed: _enterEditMode,
            ),
        ],
      ),
      body: _isDeleting
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _isEditing ? _buildEditBody() : _buildDetailBody(),
            ),
    );
  }

  // ==================== 详情模式 ====================

  Widget _buildDetailBody() {
    final l10n = AppLocalizations.of(context);
    // DEBUG: Check if this is She
    if (_agent.name == 'She' || _agent.metadata['is_she'] == true) {
      debugPrint('DEBUG: She Agent found! '
          'isPinned=${_agent.isPinned}, '
          'name=${_agent.name}, '
          'isShe=${_agent.isShe}, '
          'metadata[is_she]=${_agent.metadata['is_she']}');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const SizedBox(height: 24),
        _buildInfoCard(),
        if (_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildSkillsCard(),
          if (_agent.hasToolModels) ...[
            const SizedBox(height: 16),
            _buildToolModelsCard(),
          ],
          // 外部访问卡片（仅本地 agent 显示）
          const SizedBox(height: 16),
          _buildExternalAccessCard(),
        ],
        // Token 卡片（仅远端 agent 显示）
        if (!_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildTokenCard(),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _startConversation,
            icon: const Icon(Icons.chat),
            label: Text(l10n.agentDetail_startConversation),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // She is a built-in agent and cannot be deleted
        if (_agent.metadata['is_she'] != true)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _deleteAgent,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: Text(l10n.agentDetail_deleteAgent),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(25),
          ),
          alignment: Alignment.center,
          child: _buildAvatarWidget(_agent.avatar, 100),
        ),
        const SizedBox(height: 16),
        Text(
          _agent.name,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        if (_agent.bio != null && _agent.bio!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _agent.bio!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _getStatusColor(_agent.status).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_agent.statusIcon, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Text(
                _agent.statusText,
                style: TextStyle(
                  fontSize: 14,
                  color: _getStatusColor(_agent.status),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard() {
    final l10n = AppLocalizations.of(context);
    final systemPrompt = _agent.metadata['system_prompt'] as String?;
    final llmProviderType = _agent.metadata['llm_provider'] as String?;
    final llmModel = _agent.metadata['llm_model'] as String?;
    final llmApiBase = _agent.metadata['llm_api_base'] as String?;

    // Derive a friendly provider name from the model definition.
    // Try to match by apiBase first (unique per provider), then fall back to
    // capitalising the stored providerType string.
    String? llmProvider;
    if (llmProviderType != null) {
      final mainModelId = _agent.metadata['main_model_id'] as String?;
      final modelDef = mainModelId != null
          ? ModelRegistry.instance.getById(mainModelId)
          : null;
      final apiBase = modelDef?.route.apiBase ?? llmApiBase;

      if (apiBase != null && apiBase.isNotEmpty) {
        // Match by defaultApiBase (strip trailing slash for comparison).
        final normalised = apiBase.replaceAll(RegExp(r'/+$'), '');
        final matched = llmProviders.where((p) =>
            p.defaultApiBase.replaceAll(RegExp(r'/+$'), '') == normalised);
        if (matched.isNotEmpty) {
          llmProvider = matched.first.name;
        }
      }

      // Fallback: match solely by providerType when it's unambiguous (claude, glm).
      if (llmProvider == null) {
        final byType = llmProviders.where((p) => p.providerType == llmProviderType);
        if (byType.length == 1) {
          llmProvider = byType.first.name;
        } else {
          // Capitalise the raw providerType as last resort.
          llmProvider = llmProviderType[0].toUpperCase() + llmProviderType.substring(1);
        }
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isLocalMode ? l10n.agentDetail_llmConfig : l10n.agentDetail_connectionInfo,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const Divider(height: 24),
            // Remote-only connection fields
            if (!_isLocalMode) ...[
              _buildInfoRow(l10n.agentDetail_protocol, _agent.protocolName),
              const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_connectionType, _agent.connectionTypeName),
              if (_agent.endpoint.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(l10n.agentDetail_endpoint, _agent.endpoint),
              ],
              const SizedBox(height: 8),
              _buildInfoRow('Agent ID',
                  (_agent.metadata['target_agent_id'] as String?) ?? _agent.id),
              if (_agent.capabilities.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(l10n.agentDetail_capabilities, _agent.capabilities.join(', ')),
              ],
            ],
            if (systemPrompt != null && systemPrompt.isNotEmpty) ...[
              if (!_isLocalMode) const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_systemPrompt, systemPrompt),
            ],
            if (llmProvider != null) ...[
              if (_isLocalMode) const SizedBox(height: 0) else const Divider(height: 24),
              if (!_isLocalMode) ...[
                Text(
                  l10n.agentDetail_llmConfig,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
              ],
              _buildInfoRow(l10n.agentDetail_provider, llmProvider),
              if (llmModel != null && llmModel.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(l10n.agentDetail_model, llmModel),
              ],
              if (llmApiBase != null && llmApiBase.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow('API Base', llmApiBase),
              ],
            ] else if (_isLocalMode) ...[
              // She / local agent with no model configured yet
              Text(
                '尚未配置 AI 模型',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.orange.shade700,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (_agent.lastHeartbeat != null) ...[
              const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_lastActive, _formatTimestamp(_agent.lastHeartbeat!)),
            ],
            const SizedBox(height: 8),
            _buildInfoRow(l10n.agentDetail_createdAt, _formatTimestamp(_agent.createdAt)),
          ],
        ),
      ),
    );
  }

  Widget _buildCountBadge(String text, bool hasItems, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: hasItems
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: hasItems ? colorScheme.primary : colorScheme.outline,
        ),
      ),
    );
  }

  Widget _buildSkillsCard() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final skillRegistry = SkillRegistry.instance;
    final enabledSkills = _agent.enabledSkills;

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        leading: Icon(Icons.auto_stories, size: 18, color: colorScheme.primary),
        title: Row(
          children: [
            Text(
              l10n.skill_configTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const Spacer(),
            _buildCountBadge(
              '${enabledSkills.length}',
              enabledSkills.isNotEmpty,
              colorScheme,
            ),
          ],
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        initiallyExpanded: false,
        children: [
          const SizedBox(height: 8),
          if (enabledSkills.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.agentDetail_noSkillsEnabled,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...enabledSkills.map((skillName) {
              final def = skillRegistry.getDefinition(skillName);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.article,
                      size: 16,
                      color: colorScheme.onSurface,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            def?.displayName ?? skillName,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          if (def != null)
                            Text(
                              def.description,
                              style: TextStyle(fontSize: 11, color: colorScheme.outline),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildToolModelsCard() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final enabledToolModels = _agent.enabledToolModels;
    final toolModelScenarios = _agent.toolModelScenarios;
    final toolModelRegistry = ModelRegistry.instance;

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        leading: Icon(Icons.hub, size: 18, color: colorScheme.primary),
        title: Row(
          children: [
            Text(
              l10n.toolModel_configTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const Spacer(),
            _buildCountBadge(
              '${enabledToolModels.length}',
              enabledToolModels.isNotEmpty,
              colorScheme,
            ),
          ],
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        initiallyExpanded: false,
        children: [
          const SizedBox(height: 8),
          if (enabledToolModels.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.agentDetail_noToolModelsEnabled,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...enabledToolModels.map((toolName) {
              final def = toolModelRegistry.getDefinition(toolName);
              final scenario = toolModelScenarios[toolName];
              final effectiveDesc = scenario != null && scenario.isNotEmpty
                  ? scenario
                  : def?.description ?? '';
              final modelTypes = def?.modelTypes ?? <ModelType>{};
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.hub,
                        size: 16,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            def?.displayName ?? toolName,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          if (modelTypes.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: modelTypes.map((t) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: colorScheme.tertiaryContainer.withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      t.name,
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: colorScheme.onTertiaryContainer,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          if (effectiveDesc.isNotEmpty)
                            Text(
                              effectiveDesc,
                              style: TextStyle(fontSize: 11, color: colorScheme.outline),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildTokenCard() {
    final l10n = AppLocalizations.of(context);
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.key,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.agentDetail_authToken,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const Spacer(),
                if (_isRegeneratingToken)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: l10n.agent_regenerateToken,
                    onPressed: _regenerateToken,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _agent.token,
                style: const TextStyle(
                  fontFamily: 'Courier',
                  color: Colors.greenAccent,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _agent.token));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.agentDetail_tokenCopied),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy),
                label: Text(l10n.agentDetail_copyToken),
              ),
            ),
          ],
        ),
      ),
    );
  }


  // ==================== 外部访问卡片 ====================

  /// 外部访问卡片（详情模式，仅本地 agent）
  Widget _buildExternalAccessCard() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isEnabled = _agent.allowExternalAccess;
    final isRunning = globalACPServer.isRunning;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.open_in_new_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.agent_allowExternalAccess,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            if (!isEnabled)
              Text(
                l10n.agent_externalAccessDisabled,
                style: TextStyle(color: colorScheme.outline, fontStyle: FontStyle.italic),
              )
            else if (!isRunning)
              Row(
                children: [
                  Icon(Icons.warning_amber_outlined, size: 16, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.agent_externalAccessNeedsService,
                      style: TextStyle(color: Colors.orange.shade700, fontSize: 13),
                    ),
                  ),
                ],
              )
            else
              _buildAccessUrlSection(l10n, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildAccessUrlSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLanAddressSection(l10n, colorScheme),
        const SizedBox(height: 12),
        _buildPublicUrlSection(l10n, colorScheme),
      ],
    );
  }

  Widget _buildLanAddressSection(AppLocalizations l10n, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label + refresh button
        Row(
          children: [
            Text(
              l10n.agent_externalAccessUrlLan,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const Spacer(),
            _isRefreshingLan
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: l10n.common_refresh,
                    onPressed: _refreshLanAddresses,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  ),
          ],
        ),
        const SizedBox(height: 6),
        FutureBuilder<List<String>>(
          future: _lanAddressesFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            final addresses = snapshot.data!;
            if (addresses.isEmpty) {
              return Text(
                l10n.settings_noLanAddress,
                style: TextStyle(color: colorScheme.outline, fontSize: 13, fontStyle: FontStyle.italic),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: addresses.map((addr) {
                final url = '$addr?token=${_agent.token}&agentId=${_agent.id}';
                return _buildUrlRow(url, colorScheme, l10n);
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPublicUrlSection(AppLocalizations l10n, ColorScheme colorScheme) {
    final channelConfig = _agent.channelConfig;

    // No channel config on this agent
    if (channelConfig == null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              l10n.agent_channelNotConfigured,
              style: TextStyle(
                color: colorScheme.outline,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          TextButton(
            onPressed: _enterEditMode,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            child: Text(l10n.agent_channelConfigure, style: const TextStyle(fontSize: 13)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label + refresh button
        Row(
          children: [
            Text(
              l10n.agent_externalAccessUrlPublic,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const Spacer(),
            _isRefreshingPublicUrl
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: l10n.common_refresh,
                    onPressed: _refreshPublicUrl,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  ),
          ],
        ),
        const SizedBox(height: 6),
        FutureBuilder<String?>(
          future: _publicUrlFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData && snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            final url = snapshot.data;
            if (url == null || url.isEmpty) {
              return const SizedBox.shrink();
            }
            return _buildUrlRow(url, colorScheme, l10n);
          },
        ),
      ],
    );
  }

  // ── Async loaders ──────────────────────────────────────────────────────────

  Future<List<String>> _loadLanAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(kAcpServerPortKey) ?? kAcpServerDefaultPort;
    return LocalNetworkService.getACPServerAddresses(port: port);
  }

  Future<String?> _loadPublicUrl() async {
    final config = _agent.channelConfig;
    if (config == null) return null;
    final tunnelService = ChannelTunnelService.instance;
    final endpoint = tunnelService.getPublicEndpoint(config);
    if (endpoint == null || endpoint.isEmpty) return null;
    return '$endpoint?token=${_agent.token}&agentId=${_agent.id}';
  }

  // ── Refresh methods ────────────────────────────────────────────────────────

  void _refreshLanAddresses() {
    setState(() {
      _isRefreshingLan = true;
      _lanAddressesFuture = _loadLanAddresses();
    });
    _lanAddressesFuture!.whenComplete(() {
      if (mounted) setState(() => _isRefreshingLan = false);
    });
  }

  void _refreshPublicUrl() {
    setState(() {
      _isRefreshingPublicUrl = true;
      _publicUrlFuture = _loadPublicUrl();
    });
    _publicUrlFuture!.whenComplete(() {
      if (mounted) setState(() => _isRefreshingPublicUrl = false);
    });
  }

  Widget _buildUrlRow(String url, ColorScheme colorScheme, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                url,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: l10n.agent_copyAccessUrl,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.agent_accessUrlCopied),
                        const SizedBox(height: 2),
                        Text(
                          l10n.agent_accessUrlCopiedHint,
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  /// 外部访问开关卡片（编辑模式，仅本地 agent）
  Widget _buildEditExternalAccessCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: Icon(Icons.open_in_new_outlined, color: colorScheme.primary),
        title: Text(
          l10n.agent_allowExternalAccess,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          l10n.agent_allowExternalAccessDesc,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        value: _editingAllowExternalAccess,
        onChanged: (value) async {
          if (value) {
            // 检查全局 ACP Server 开关状态
            final prefs = await SharedPreferences.getInstance();
            final acpEnabled = prefs.getBool(kAcpServerEnabledKey) ?? true;
            if (!acpEnabled && mounted) {
              // 总控关闭，弹出提示
              final shouldEnableService = await showDialog<bool>(
                context: context,
                builder: (ctx) {
                  final dialogL10n = AppLocalizations.of(ctx);
                  return AlertDialog(
                    title: Text(dialogL10n.agent_enableExternalAccessTitle),
                    content: Text(dialogL10n.agent_enableExternalAccessNeedService),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(dialogL10n.agent_keepDisabled),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(dialogL10n.agent_enableServiceAndContinue),
                      ),
                    ],
                  );
                },
              );
              if (shouldEnableService == true) {
                // 自动开启总控：写入 SharedPreferences + 启动 ACP Server
                await prefs.setBool(kAcpServerEnabledKey, true);
                try {
                  await globalACPServer.start();
                } catch (_) {}
              }
              // 无论用户选择"开启服务"还是"仅保存设置"，都保存 agent 的外部访问开关
            }
          }
          if (mounted) {
            setState(() => _editingAllowExternalAccess = value);
          }
        },
      ),
    );
  }

  /// Channel 配置卡片（编辑模式，仅在允许外部访问时显示）
  Widget _buildEditChannelConfigCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.agent_channelConfig,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _channelServerUrlController,
              decoration: InputDecoration(
                labelText: l10n.agent_channelServerUrl,
                hintText: 'https://channel.example.com',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.dns_outlined),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _channelIdController,
              decoration: InputDecoration(
                labelText: l10n.agent_channelId,
                hintText: 'abc-123',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.tag),
              ),
              // Prevent accidental paste of "uuid --secret ..." style strings
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _channelSecretController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.agent_channelSecret,
                hintText: 'ch_sec_xxx',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _channelEndpointController,
              decoration: InputDecoration(
                labelText: l10n.agent_channelEndpoint,
                hintText: 'endpoint from channel service',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 编辑模式 ====================

  Widget _buildEditBody() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头像编辑
        Center(
          child: GestureDetector(
            onTap: _showAvatarPicker,
            child: Stack(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(25),
                  ),
                  alignment: Alignment.center,
                  child: _buildAvatarWidget(_editingAvatar, 100),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: _showAvatarPicker,
            icon: const Icon(Icons.edit, size: 16),
            label: Text(l10n.agentDetail_changeAvatar),
          ),
        ),
        const SizedBox(height: 16),

        // 卡片 1: 基本信息
        _buildEditBasicInfoCard(colorScheme),
        const SizedBox(height: 16),

        // 卡片 2: 连接配置（仅远端 agent 显示）
        if (!_isLocalMode) ...[
          _buildEditConnectionCard(colorScheme),
          const SizedBox(height: 16),
        ],

        // 卡片 3: 模型配置（仅本地 agent 显示）
        if (_isLocalMode)
          _buildEditLLMConfigCard(colorScheme),

        // 卡片 4: 允许外部访问（仅本地 agent 显示）
        if (_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildEditExternalAccessCard(colorScheme),
          // Channel 配置（仅在外部访问开启时显示）
          if (_editingAllowExternalAccess) ...[
            const SizedBox(height: 16),
            _buildEditChannelConfigCard(colorScheme),
          ],
        ],

        // 卡片 5: OS 工具 / 技能 / 模型路由导航入口（仅在选择了主模型时显示）
        if (_selectedMainModelId != null) ...[
          const SizedBox(height: 16),
          _buildEditConfigNavigationTiles(colorScheme),
        ],
        const SizedBox(height: 16),

        // 保存 / 取消按钮
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : _cancelEdit,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(l10n.common_cancel),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveEdit,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save),
                label: Text(l10n.common_save),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditBasicInfoCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.addAgent_basicInfo,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_agentName,
                hintText: l10n.addAgent_agentNameHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.badge),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _bioController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_agentBio,
                hintText: l10n.addAgent_agentBioHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.description),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _systemPromptController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_systemPrompt,
                hintText: l10n.addAgent_systemPromptHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.tune),
                alignLabelWithHint: true,
              ),
              maxLines: 4,
              minLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditConnectionCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.addAgent_connectConfig,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 端点 URL
            TextFormField(
              controller: _endpointController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_endpointUrl,
                hintText: l10n.addAgent_endpointUrlHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.language),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),

            // Token（可编辑）
            TextFormField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Token',
                hintText: l10n.agentDetail_tokenHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: l10n.agentDetail_copyTokenTooltip,
                  onPressed: () {
                    final t = _tokenController.text.trim();
                    if (t.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: t));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.agentDetail_tokenCopied),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            const SizedBox(height: 16),

            // 远端 Agent ID（可选）
            TextFormField(
              controller: _remoteAgentIdController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_remoteAgentId,
                hintText: l10n.addAgent_remoteAgentIdHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.fingerprint),
                helperText: l10n.addAgent_remoteAgentIdHelper,
              ),
              enableSuggestions: false,
              autocorrect: false,
            ),
          ],
        ),
      ),
    );
  }


  /// Navigation tiles for Skills, Tool Models, and CLI Commands sub-pages (edit mode).
  Widget _buildEditConfigNavigationTiles(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.auto_stories, color: colorScheme.primary),
            title: Text(l10n.skill_configTitle),
            subtitle: Text(
              _enabledSkills.isEmpty
                  ? l10n.addAgent_noSkills
                  : l10n.addAgent_skillsCount(_enabledSkills.length),
              style: TextStyle(
                color: _enabledSkills.isEmpty
                    ? colorScheme.outline
                    : colorScheme.primary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<Set<String>>(
                context,
                MaterialPageRoute(
                  builder: (_) => SkillSelectScreen(
                    enabledSkills: _enabledSkills,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _enabledSkills = result;
                });
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.hub, color: colorScheme.primary),
            title: Text(l10n.toolModel_configTitle),
            subtitle: Text(
              _toolModelScenarios.isEmpty
                  ? l10n.addAgent_noToolModels
                  : l10n.addAgent_toolModelsCount(_toolModelScenarios.length),
              style: TextStyle(
                color: _toolModelScenarios.isEmpty
                    ? colorScheme.outline
                    : colorScheme.primary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<Map<String, String>>(
                context,
                MaterialPageRoute(
                  builder: (_) => ModelSelectScreen(
                    toolModelScenarios: _toolModelScenarios,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _toolModelScenarios = result;
                });
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.terminal, color: colorScheme.primary),
            title: const Text('CLI Commands'),
            subtitle: Text(
              _enabledCliCommands.isEmpty
                  ? 'All CLI commands available'
                  : '${_enabledCliCommands.length} command(s) selected (restricted)',
              style: TextStyle(
                color: _enabledCliCommands.isEmpty
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<Set<String>>(
                context,
                MaterialPageRoute(
                  builder: (_) => CliCommandSelectScreen(
                    enabledCommands: _enabledCliCommands,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _enabledCliCommands = result;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEditLLMConfigCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    final defs = ModelRegistry.instance.definitions;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.addAgent_modelConfig,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  l10n.common_required,
                  style: TextStyle(fontSize: 12, color: colorScheme.error),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (defs.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_outlined, size: 16, color: colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.addAgent_noModels,
                        style: TextStyle(fontSize: 12, color: colorScheme.error),
                      ),
                    ),
                  ],
                ),
              )
            else
              DropdownButtonFormField<String>(
                value: _selectedMainModelId,
                isExpanded: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.memory),
                  isDense: true,
                ),
                hint: Text(l10n.addAgent_selectModel),
                selectedItemBuilder: (context) => defs.map((def) {
                  final typeLabel = def.modelTypes.isNotEmpty
                      ? ' [${def.modelTypes.map((t) => t.name).join(', ')}]'
                      : '';
                  return Text(
                    '${def.displayName}$typeLabel',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  );
                }).toList(),
                items: defs.map((def) {
                  return DropdownMenuItem<String>(
                    value: def.id,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          def.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (def.route.model != null && def.route.model!.isNotEmpty)
                          Text(
                            def.route.model!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.outline,
                            ),
                          ),
                        if (def.modelTypes.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              children: def.modelTypes.map((t) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: colorScheme.tertiaryContainer
                                        .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    t.name,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: colorScheme.onTertiaryContainer,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedMainModelId = val),
                validator: (val) {
                  if (val == null || val.isEmpty) {
                    return l10n.addAgent_modelRequired;
                  }
                  return null;
                },
              ),
          ],
        ),
      ),
    );
  }

  // ==================== 工具方法 ====================

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: Colors.grey[600],
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(int timestampMs) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return l10n.agentDetail_justNow;
    } else if (diff.inMinutes < 60) {
      return l10n.agentDetail_minutesAgo(diff.inMinutes);
    } else if (diff.inHours < 24) {
      return l10n.agentDetail_hoursAgo(diff.inHours);
    } else {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }
}
