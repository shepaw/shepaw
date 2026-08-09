import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/avatar_image.dart';
import '../l10n/l10n_helpers.dart';
import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import '../services/remote_agent_service.dart';
import '../services/she_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/model_registry.dart';
import '../models/agent_scenario_models.dart';
import '../models/llm_provider_config.dart';
import '../services/skill_registry.dart';
import '../services/cli_namespace_registry.dart';
import '../service_locator.dart' show getIt;
import 'skill_select_screen.dart';
import 'cli_command_select_screen.dart';
import 'prompt_stack_config_screen.dart';
import 'chat_screen.dart';
import '../widgets/agent_model_config_card.dart';
import 'she_circle_screen.dart';
import '../utils/layout_utils.dart';
import '../models/prompt_stack_config.dart';
import '../storage/runtime_share_service.dart';

/// 远端 Agent 详情页面（从聊天页进入）
class RemoteAgentDetailScreen extends StatefulWidget {
  final RemoteAgent agent;

  /// 若为 true，打开页面即进入编辑模式
  final bool initialEditMode;

  const RemoteAgentDetailScreen({
    super.key,
    required this.agent,
    this.initialEditMode = false,
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
  Timer? _autoSaveDebounce;

  /// Whether remote-session sync is enabled for this peer agent (default on).
  bool _peerSyncEnabled = true;

  /// Upstream model list from the paired device's agent (peer agents only).
  List<PeerAgentModel> _peerModels = const [];
  String? _peerCurrentModel;
  bool _peerModelsLoading = false;
  bool _peerModelSetting = false;
  String? _peerModelsError;

  // 编辑用的控制器
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  late TextEditingController _endpointController;
  late TextEditingController _systemPromptController;
  late TextEditingController _remoteAgentIdController;
  late TextEditingController _maxToolRoundsController;
  late TextEditingController _taskTimeoutController;
  String _editingAvatar = '';

  // 主模型选择（从 ModelRegistry 中选择）
  String? _selectedMainModelId;

  ProtocolType _editingProtocol = ProtocolType.acp;
  ConnectionType _editingConnectionType = ConnectionType.websocket;

  // Skills 配置
  Set<String> _enabledSkills = {};

  // 场景模型
  AgentScenarioModels _scenarioModels = const AgentScenarioModels();

  // CLI 命令配置
  Set<String> _enabledCliCommands = {};

  /// Editable prompt-stack flags (persisted in metadata).
  late PromptStackConfig _promptStackConfig;


  // 本地上传的头像文件路径（相对路径）
  String? _localAvatarPath;

  // 外部访问相关（用于编辑模式）。开启后该 agent 可被已配对设备通过 P2P 访问。
  bool _editingAllowExternalAccess = false;

  final ImagePicker _imagePicker = ImagePicker();
  final LocalFileStorageService _fileStorage = LocalFileStorageService();

  /// peer 连接状态变化订阅：peer agent 的在线状态需实时跟随来源设备上/下线。
  StreamSubscription<PeerConnectionEvent>? _peerConnSub;

  /// True when this agent should be treated as a local LLM agent.
  /// She is always treated as local even before a model is configured.
  bool get _isLocalMode =>
      _agent.isLocal ||
      _agent.metadata['is_she'] == true;

  @override
  void initState() {
    super.initState();
    _agent = widget.agent;
    _isEditing = widget.initialEditMode;
    _initEditingControllers();

    // peer agent 的在线状态完全取决于来源配对设备是否在线，订阅连接状态变化
    // 以便设备上/下线时即时刷新页面顶部的状态徽标。
    if (_agent.isPeerAgent) {
      _peerConnSub =
          PeerConnectionManager.instance.events.listen((event) {
        if (event.peerId != _agent.sourcePeerId || !mounted) return;
        if (event.type == PeerConnectionEventType.connected) {
          unawaited(_loadPeerModels());
        }
        setState(() {});
      });
      _loadPeerSyncPref();
      if (_isEditing) _loadPeerModels();
    }
  }

  Future<void> _loadPeerModels() async {
    final l10n = AppLocalizations.of(context);
    if (!_agent.isPeerAgent) return;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      if (mounted) {
        setState(() {
          _peerModels = const [];
          _peerCurrentModel = null;
          _peerModelsError = l10n.agentDetail_peerOffline;
          _peerModelsLoading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _peerModelsLoading = true;
        _peerModelsError = null;
      });
    }
    final list = await PeerAgentClientService.instance.fetchModels(
      peerId: peerId,
      remoteAgentId: remoteId,
    );
    if (!mounted) return;
    setState(() {
      _peerModelsLoading = false;
      _peerModels = list.models;
      _peerCurrentModel = list.current;
      if (list.models.isEmpty) {
        _peerModelsError = l10n.agentDetail_modelSwitchUnsupported;
      }
    });
  }

  Future<void> _onPeerModelSelected(String? value) async {
    final l10n = AppLocalizations.of(context);
    if (value == null || value == _peerCurrentModel || _peerModelSetting) return;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    setState(() => _peerModelSetting = true);
    final ok = await PeerAgentClientService.instance.setModel(
      peerId: peerId,
      remoteAgentId: remoteId,
      model: value,
    );
    if (!mounted) return;
    setState(() {
      _peerModelSetting = false;
      if (ok) _peerCurrentModel = value;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.agentDetail_modelSwitched : l10n.agentDetail_modelSwitchFailed),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _loadPeerSyncPref() async {
    final prefs = await SharedPreferences.getInstance();
    final disabled = prefs.getBool('peer_sync_disabled_${_agent.id}') == true;
    if (mounted) setState(() => _peerSyncEnabled = !disabled);
  }

  Future<void> _setPeerSyncEnabled(bool enabled) async {
    setState(() => _peerSyncEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('peer_sync_disabled_${_agent.id}', !enabled);
  }

  /// 页面展示用的在线状态。peer agent 跟随来源设备的 P2P 连接状态，其余 agent
  /// 沿用自身 [RemoteAgent.status]。
  AgentStatus get _displayStatus {
    if (!_agent.isPeerAgent) return _agent.status;
    final peerId = _agent.sourcePeerId;
    if (peerId == null) return AgentStatus.offline;
    return PeerConnectionManager.instance.getPeerState(peerId) ==
            PeerConnectionState.connected
        ? AgentStatus.online
        : AgentStatus.offline;
  }

  void _initEditingControllers() {
    _nameController = TextEditingController(text: _agent.name);
    _bioController = TextEditingController(text: _agent.bio ?? '');
    _endpointController = TextEditingController(text: _agent.endpoint);
    _systemPromptController = TextEditingController(
      text: _agent.metadata['system_prompt'] as String? ?? '',
    );
    _remoteAgentIdController = TextEditingController(
      text: (_agent.metadata['target_agent_id'] as String?) ?? '',
    );
    _maxToolRoundsController = TextEditingController(
      text: (_agent.metadata['max_tool_rounds'] as num? ?? 100).toString(),
    );
    _taskTimeoutController = TextEditingController(
      text: (_agent.metadata['task_timeout_seconds'] as num? ?? 600).toString(),
    );
    _editingAvatar = _agent.avatar;
    _localAvatarPath = null;
    _editingProtocol = _agent.protocol;
    _editingConnectionType = _agent.connectionType;
    _editingAllowExternalAccess = _agent.allowExternalAccess;

    // Load skills from metadata
    _enabledSkills = _agent.enabledSkills;

    _scenarioModels = AgentScenarioModels.loadForEditing(
      metadata: _agent.metadata,
      enabledToolModels: _agent.enabledToolModels,
      modelRouting: _agent.modelRouting,
      definitions: ModelRegistry.instance.definitions,
    );

    // Load CLI commands from metadata
    _enabledCliCommands = _agent.enabledCliCommands;
    _promptStackConfig = _agent.promptStackConfig;


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

  }

  @override
  void deactivate() {
    _autoSaveDebounce?.cancel();
    if (_isEditing) {
      unawaited(_persistChanges());
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _nameController.dispose();
    _bioController.dispose();
    _endpointController.dispose();
    _systemPromptController.dispose();
    _remoteAgentIdController.dispose();
    _maxToolRoundsController.dispose();
    _taskTimeoutController.dispose();
    _peerConnSub?.cancel();
    super.dispose();
  }

  void _enterEditMode() {
    _syncControllersFromAgent();
    setState(() => _isEditing = true);
    if (_agent.isPeerAgent) {
      unawaited(_loadPeerModels());
    }
  }

  void _scheduleAutoSave() {
    if (!_isEditing) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistChanges());
    });
  }

  void _syncControllersFromAgent() {
    final l10n = AppLocalizations.of(context);
    _nameController.text = _agent.isShe
        ? SheService.resolveDisplayName(_agent.name, l10n.she_name)
        : _agent.name;
    _bioController.text = _agent.bio ?? '';
    _endpointController.text = _agent.endpoint;
    _systemPromptController.text =
        _agent.metadata['system_prompt'] as String? ?? '';
    _remoteAgentIdController.text =
        (_agent.metadata['target_agent_id'] as String?) ?? '';
    _maxToolRoundsController.text =
        (_agent.metadata['max_tool_rounds'] as num? ?? 100).toString();
    _taskTimeoutController.text =
        (_agent.metadata['task_timeout_seconds'] as num? ?? 600).toString();
    _editingAvatar = _agent.avatar;
    _localAvatarPath = null;
    _editingProtocol = _agent.protocol;
    _editingConnectionType = _agent.connectionType;
    _editingAllowExternalAccess = _agent.allowExternalAccess;
    _enabledSkills = _agent.enabledSkills;
    _enabledCliCommands = _agent.enabledCliCommands;
    _promptStackConfig = _agent.promptStackConfig;
    _scenarioModels = AgentScenarioModels.loadForEditing(
      metadata: _agent.metadata,
      enabledToolModels: _agent.enabledToolModels,
      modelRouting: _agent.modelRouting,
      definitions: ModelRegistry.instance.definitions,
    );
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
  }

  void _applyScenarioModelsMetadata(Map<String, dynamic> metadata) {
    if (_scenarioModels.isEmpty) {
      metadata.remove('scenario_models');
    } else {
      metadata['scenario_models'] = _scenarioModels.toJson();
      metadata.remove('model_routing');
    }
  }

  Future<void> _persistChanges({bool showFeedback = false}) async {
    final l10n = AppLocalizations.of(context);
    if (!_isEditing) return;
    var name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    if (_agent.isShe) {
      name = SheService.normalizeStoredName(name, l10n.she_name);
    }

    if (_isSaving) {
      _autoSaveDebounce?.cancel();
      _autoSaveDebounce = Timer(const Duration(milliseconds: 400), () {
        unawaited(_persistChanges(showFeedback: showFeedback));
      });
      return;
    }

    // v2.1: token is no longer required — authentication is handled via Noise
    // public-key pinning. Keep reading the field so users who still have an
    // old token stored can clear or update it, but never block saving on it.

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

      // peer agent：本地一旦改过头像，打上标记，后续从对端同步时以本地为准，
      // 不再被对端分享的头像覆盖。
      if (_agent.isPeerAgent && avatar != _agent.avatar) {
        metadata['avatar_overridden'] = true;
      }

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

        // Save tool models derived from generation scenario config
        final enabledTools =
            _scenarioModels.enabledGenerationToolModels(ModelRegistry.instance);
        if (enabledTools.isNotEmpty) {
          metadata['enabled_tool_models'] = enabledTools.toList();
        } else {
          metadata.remove('enabled_tool_models');
        }
        metadata.remove('tool_model_scenarios');

        // Save CLI commands
        if (_enabledCliCommands.isNotEmpty) {
          metadata['enabled_cli_commands'] = _enabledCliCommands.toList();
        } else {
          metadata.remove('enabled_cli_commands');
        }

        _applyScenarioModelsMetadata(metadata);
      } else {
        // No model selected — clear LLM config
        metadata.remove('llm_provider');
        metadata.remove('main_model_id');
        metadata.remove('llm_model');
        metadata.remove('llm_api_base');
        metadata.remove('llm_api_key');
      }

      // Prompt stack applies to local / She agents regardless of model selection.
      if (_isLocalMode || _selectedMainModelId != null) {
        metadata['prompt_stack_config'] = _promptStackConfig.toJson();
      }

      // Save allow_external_access for local agents
      if (_isLocalMode || _selectedMainModelId != null) {
        metadata['allow_external_access'] = _editingAllowExternalAccess;
      }

      // 旧的 per-agent 公网 Channel 配置已废弃，外部访问统一走 P2P peer 连接。
      // 清理可能残留的旧字段。
      metadata.remove('channel_config');

      // Save remote agent ID (target_agent_id)
      final remoteAgentId = _remoteAgentIdController.text.trim();
      if (remoteAgentId.isNotEmpty) {
        metadata['target_agent_id'] = remoteAgentId;
      } else {
        metadata.remove('target_agent_id');
      }

      // Save tool call limits (local / self-managed remote agents only)
      if (!_agent.isPeerAgent) {
        final maxToolRounds = int.tryParse(_maxToolRoundsController.text.trim());
        if (maxToolRounds != null && maxToolRounds >= 1 && maxToolRounds <= 500) {
          metadata['max_tool_rounds'] = maxToolRounds;
        } else {
          metadata['max_tool_rounds'] = 100;
        }
      }
      final taskTimeout = int.tryParse(_taskTimeoutController.text.trim());
      if (taskTimeout != null && taskTimeout >= 60 && taskTimeout <= 3600) {
        metadata['task_timeout_seconds'] = taskTimeout;
      } else {
        metadata['task_timeout_seconds'] = 600;
      }

      final updatedAgent = _agent.copyWith(
        name: name,
        bio: _bioController.text.trim().isEmpty ? null : _bioController.text.trim(),
        avatar: avatar,
        endpoint: _endpointController.text.trim(),
        protocol: _editingProtocol,
        connectionType: _editingConnectionType,
        metadata: metadata,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      final agentService = getIt<RemoteAgentService>();
      await agentService.updateAgent(updatedAgent);

      setState(() {
        _agent = updatedAgent;
        _isSaving = false;
      });

      if (mounted && showFeedback) {
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
      final agentService = getIt<RemoteAgentService>();
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
                  _scheduleAutoSave();
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
      _scheduleAutoSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_saveImageFailed('$e')), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ==================== 头像展示 ====================

  Widget _buildAvatarWidget(String avatar, double size) {
    final borderRadius = size * 0.25;
    final fallback = Icon(Icons.smart_toy, size: size * 0.6);

    return AvatarImage(
      avatar: avatar.isNotEmpty ? avatar : '🤖',
      size: size,
      borderRadius: borderRadius,
      fallback: fallback,
    );
  }

  // ==================== Build ====================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: widget.initialEditMode || !_isEditing,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _autoSaveDebounce?.cancel();
        unawaited(_persistChanges().then((_) {
          if (mounted) setState(() => _isEditing = false);
        }));
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.agentDetail_editTitle : l10n.agentDetail_title),
        centerTitle: true,
        actions: [
          if (_isEditing && _isSaving)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (!_isDeleting && !_isEditing)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.agentDetail_editTooltip,
              onPressed: _enterEditMode,
            ),
        ],
      ),
      body: _isDeleting
          ? const Center(child: CircularProgressIndicator())
          : _isEditing
              ? Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: _buildEditBody(),
                      ),
                    ),
                    _buildDetailBottomBar(),
                  ],
                )
              : Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: _buildDetailBody(),
                      ),
                    ),
                    _buildDetailBottomBar(),
                  ],
                ),
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
        if (_agent.isShe && !_agent.isPeerAgent) ...[
          const SizedBox(height: 16),
          _buildSheCircleEntry(),
        ],
        if (_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildSkillsCard(),
          const SizedBox(height: 16),
          _buildCliCommandsCard(),
          // 分享给配对设备（仅本地 agent 显示）
          const SizedBox(height: 16),
          _buildExternalAccessCard(),
        ],
        // She is a built-in agent and cannot be deleted
        if (_agent.metadata['is_she'] != true) ...[
          const SizedBox(height: 24),
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
      ],
    );
  }

  Widget _buildHeader() {
    final l10n = AppLocalizations.of(context);
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
          SheService.resolveDisplayName(
            _agent.name,
            AppLocalizations.of(context).she_name,
          ),
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
        Builder(builder: (context) {
          // peer agent 用跟随设备的展示状态，其余 agent 用自身状态。
          final displayAgent = _agent.isPeerAgent
              ? _agent.copyWith(status: _displayStatus)
              : _agent;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _getStatusColor(displayAgent.status).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(displayAgent.statusIcon, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Text(
                  displayAgent.localizedStatusText(l10n),
                  style: TextStyle(
                    fontSize: 14,
                    color: _getStatusColor(displayAgent.status),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        }),
        if (_agent.isPeerAgent) ...[
          const SizedBox(height: 8),
          _buildPeerSourceChip(),
        ],
      ],
    );
  }

  /// Toggle whether we auto-detect and sync this peer agent's remote sessions
  /// (list + history) on entry. Turning it off stops sync and prompts; turning
  /// it on enables silent auto-sync. The first chat entry asks once until a
  /// choice is saved here or via the sync dialog.
  Widget _buildPeerSyncToggle() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        title: Text(l10n.agentDetail_sessionSync, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          l10n.agentDetail_sessionSyncHint,
          style: const TextStyle(fontSize: 12),
        ),
        value: _peerSyncEnabled,
        onChanged: _setPeerSyncEnabled,
      ),
    );
  }

  /// Upstream model picker — switches the remote agent's LLM via
  /// `agent.models.setCurrent` on the paired device.
  Widget _buildPeerModelPicker() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final busy = _peerModelsLoading || _peerModelSetting;
    final effectiveCurrent = _peerCurrentModel ??
        (_peerModels.length == 1 ? _peerModels.first.value : null);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                l10n.agentDetail_model,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: l10n.agentDetail_refreshModels,
                  onPressed: _loadPeerModels,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.agentDetail_switchModelHint,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          if (_peerModelsError != null && _peerModels.isEmpty)
            Text(
              _peerModelsError!,
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            )
          else if (_peerModels.isEmpty && _peerModelsLoading)
            const SizedBox.shrink()
          else if (_peerModels.isEmpty)
            Text(
              l10n.agentDetail_noModels,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            )
          else
            DropdownButtonFormField<String>(
              value: effectiveCurrent != null &&
                      _peerModels.any((m) => m.value == effectiveCurrent)
                  ? effectiveCurrent
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: colorScheme.surface,
              ),
              hint: Text(l10n.addAgent_selectModel),
              selectedItemBuilder: (context) => _peerModels
                  .map(
                    (m) => Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        m.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              items: _peerModels
                  .map(
                    (m) => DropdownMenuItem<String>(
                      value: m.value,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(m.displayName, overflow: TextOverflow.ellipsis),
                          if (m.description.isNotEmpty)
                            Text(
                              m.description,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: busy ? null : _onPeerModelSelected,
            ),
        ],
      ),
    );
  }

  /// 来源标识：标记该 agent 来自某台配对设备（通过 P2P 隧道访问）。
  Widget _buildPeerSourceChip() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sourceName = _agent.sourcePeerName ?? l10n.peerPairing_title;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_outlined, size: 14, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            l10n.agentDetail_fromSource(sourceName),
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 她的朋友圈：仅本机 She 详情入口（已从储物袋迁出）。
  Widget _buildSheCircleEntry() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(Icons.favorite_outline, color: colorScheme.primary),
        title: Text(l10n.storage_sheCircleSection),
        subtitle: Text(
          l10n.storage_sheCircleHint,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const SheCircleScreen(),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoCard() {
    final l10n = AppLocalizations.of(context);
    final systemPrompt = _agent.metadata['system_prompt'] as String?;
    final llmProviderType = _agent.metadata['llm_provider'] as String?;
    final llmModel = _agent.metadata['llm_model'] as String?;
    final llmApiBase = _agent.metadata['llm_api_base'] as String?;

    // 主模型优先从 ModelRegistry 按 main_model_id 解析（保存时只存 id，
    // llm_model / llm_api_base 会被清除），找不到再回退到 legacy 字段。
    final mainModelId = _agent.metadata['main_model_id'] as String?;
    final modelDef = mainModelId != null
        ? ModelRegistry.instance.getById(mainModelId)
        : null;
    final displayModel = modelDef != null && modelDef.displayName.isNotEmpty
        ? modelDef.displayName
        : llmModel;
    final displayApiBase = modelDef?.route.apiBase ?? llmApiBase;

    // Derive a friendly provider name from the model definition.
    // Try to match by apiBase first (unique per provider), then fall back to
    // capitalising the stored providerType string.
    String? llmProvider;
    if (llmProviderType != null) {
      final apiBase = displayApiBase;

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
            // Remote-only connection fields (peer agents use P2P tunnel)
            if (!_isLocalMode && !_agent.isPeerAgent) ...[
              _buildInfoRow(l10n.agentDetail_protocol, _agent.localizedProtocolName(l10n)),
              const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_connectionType, _agent.localizedConnectionTypeName(l10n)),
              if (_agent.endpoint.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(l10n.agentDetail_endpoint, _agent.endpoint),
              ],
              const SizedBox(height: 8),
              _buildInfoRow('Agent ID',
                  (_agent.metadata['target_agent_id'] as String?) ?? _agent.id),
            ],
            // Peer agent：来源设备 + P2P 隧道连接
            if (_agent.isPeerAgent) ...[
              _buildInfoRow(l10n.agentDetail_sourceDevice,
                  _agent.sourcePeerName ?? _agent.sourcePeerId ?? '-'),
              const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_connectionType, l10n.agentDetail_peerTunnel),
            ],
            if (_agent.capabilities.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildInfoRow(l10n.agentDetail_capabilities, _agent.capabilities.join(', ')),
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
              if (displayModel != null && displayModel.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow(l10n.agentDetail_model, displayModel),
              ],
              if (displayApiBase != null && displayApiBase.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInfoRow('API Base', displayApiBase),
              ],
            ] else if (_isLocalMode) ...[
              // She / local agent with no model configured yet
              Text(
                l10n.agentDetail_noAiModel,
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
            if (!_agent.isPeerAgent) ...[
              _buildInfoRow(l10n.agentDetail_maxToolRounds,
                  l10n.agentDetail_maxToolRoundsValue((_agent.metadata['max_tool_rounds'] as num? ?? 100).toInt())),
              const SizedBox(height: 8),
            ],
            _buildInfoRow(l10n.agentDetail_taskTimeout,
                l10n.agentDetail_taskTimeoutValue((_agent.metadata['task_timeout_seconds'] as num? ?? 600).toInt())),
            // 本地 / peer agent 的 Agent ID 放在底部信息区（远端 agent 已在连接区展示）
            if (_isLocalMode || _agent.isPeerAgent) ...[
              const SizedBox(height: 8),
              _buildInfoRow('Agent ID', _agent.id),
            ],
            const SizedBox(height: 8),
            _buildInfoRow(l10n.agentDetail_createdAt, _formatTimestamp(_agent.createdAt)),
            const SizedBox(height: 8),
            _buildInfoRow(l10n.agentDetail_updatedAt, _formatTimestamp(_agent.updatedAt)),
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
          color: hasItems ? colorScheme.primary : colorScheme.onSurfaceVariant,
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
        leading: Icon(Icons.auto_awesome, size: 18, color: colorScheme.primary),
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
                  color: colorScheme.onSurfaceVariant,
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
                              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
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

  /// CLI 命令卡（详情模式，仅本地 agent）。
  ///
  /// 与编辑页的 [CliCommandSelectScreen] 对应：`enabledCliCommands` 为空表示
  /// 全部放行（默认），非空表示仅放行选中的命令。按命名空间分组展示。
  Widget _buildCliCommandsCard() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final registry = CliNamespaceRegistry.instance;
    final enabledCommands = _agent.enabledCliCommands;
    final isRestricted = enabledCommands.isNotEmpty;

    // 按顶层命名空间分组已放行的命令，便于浏览
    final grouped = registry.namespaces.values
        .map((ns) => MapEntry(
            ns, ns.commands.where(enabledCommands.contains).toList()))
        .where((entry) => entry.value.isNotEmpty)
        .toList();

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        leading: Icon(Icons.terminal, size: 18, color: colorScheme.primary),
        title: Row(
          children: [
            Text(
              l10n.agentDetail_cliCommands,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const Spacer(),
            _buildCountBadge(
              '${isRestricted ? enabledCommands.length : registry.allCommandIds.length}',
              true,
              colorScheme,
            ),
          ],
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        initiallyExpanded: false,
        children: [
          const SizedBox(height: 8),
          if (!isRestricted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.agentDetail_allCliCommands,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...grouped.map((entry) {
              final ns = entry.key;
              final commands = entry.value;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: colorScheme.onSurface,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${ns.label} (${commands.length})',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          Text(
                            commands.join(', '),
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant),
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

  // ==================== 外部访问卡片 ====================

  /// 分享给配对设备卡片（详情模式，仅本地 agent）。
  ///
  /// 开启后走 P2P：该 agent 对已配对设备可见，对方可在会话列表中对话。
  Widget _buildExternalAccessCard() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isEnabled = _agent.allowExternalAccess;

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
                const Spacer(),
                Icon(
                  isEnabled ? Icons.check_circle : Icons.cancel,
                  size: 18,
                  color: isEnabled ? Colors.green : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const Divider(height: 24),
            Text(
              isEnabled
                  ? l10n.agent_externalAccessPeerEnabled
                  : l10n.agent_externalAccessDisabled,
              style: TextStyle(
                color: isEnabled ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
                fontStyle: isEnabled ? FontStyle.normal : FontStyle.italic,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分享给配对设备开关（编辑模式，仅本地 agent）
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
        onChanged: (value) {
          setState(() => _editingAllowExternalAccess = value);
          _scheduleAutoSave();
        },
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

        // 卡片 2: 连接配置（仅自管远端 agent，不含 peer agent）
        if (!_isLocalMode && !_agent.isPeerAgent) ...[
          _buildEditConnectionCard(colorScheme),
          const SizedBox(height: 16),
        ],

        // peer agent：会话同步 + 远端模型（编辑页配置）
        if (_agent.isPeerAgent) ...[
          _buildPeerSyncToggle(),
          const SizedBox(height: 16),
          _buildPeerModelPicker(),
          const SizedBox(height: 16),
        ],

        // 卡片 3: 模型配置（仅本地 agent 显示）
        if (_isLocalMode) ...[
          AgentModelConfigCard(
            mainModelId: _selectedMainModelId,
            onMainModelChanged: (id) {
              setState(() => _selectedMainModelId = id);
              _scheduleAutoSave();
            },
            scenarioModels: _scenarioModels,
            onScenarioModelsChanged: (models) {
              setState(() => _scenarioModels = models);
              _scheduleAutoSave();
            },
            showRequiredBadge: true,
            mainModelValidator: (val) {
              if (val == null || val.isEmpty) {
                return AppLocalizations.of(context).addAgent_modelRequired;
              }
              return null;
            },
          ),
        ],

        // 卡片 4: 允许外部访问（仅本地 agent 显示）
        if (_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildEditExternalAccessCard(colorScheme),
        ],

        // 卡片 5: OS 工具 / 技能 / 生成能力导航入口（仅在选择了主模型时显示）
        if (_selectedMainModelId != null) ...[
          const SizedBox(height: 16),
          _buildEditConfigNavigationTiles(colorScheme),
        ],
      ],
    );
  }

  Widget _buildDetailBottomBar() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: SizedBox(
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
              onChanged: (_) => _scheduleAutoSave(),
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
              onChanged: (_) => _scheduleAutoSave(),
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
              onChanged: (_) => _scheduleAutoSave(),
            ),
            if (!_agent.isPeerAgent) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _maxToolRoundsController,
                decoration: InputDecoration(
                  labelText: l10n.agentDetail_maxToolRounds,
                  hintText: l10n.agentDetail_maxToolRoundsDefault,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.repeat),
                  helperText: l10n.agentDetail_maxToolRoundsHelper,
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => _scheduleAutoSave(),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final n = int.tryParse(value.trim());
                  if (n == null || n < 1 || n > 500) return l10n.agentDetail_maxToolRoundsInvalid;
                  return null;
                },
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _taskTimeoutController,
              decoration: InputDecoration(
                labelText: l10n.agentDetail_taskTimeoutSeconds,
                hintText: l10n.agentDetail_taskTimeoutDefault,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.timer),
                helperText: l10n.agentDetail_taskTimeoutHelper,
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) => _scheduleAutoSave(),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return null;
                final n = int.tryParse(value.trim());
                if (n == null || n < 60 || n > 3600) return l10n.agentDetail_taskTimeoutInvalid;
                return null;
              },
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
              onChanged: (_) => _scheduleAutoSave(),
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
              onChanged: (_) => _scheduleAutoSave(),
            ),
          ],
        ),
      ),
    );
  }


  /// Navigation tiles for Skills and CLI Commands sub-pages (edit mode).
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
            leading: Icon(Icons.auto_awesome, color: colorScheme.primary),
            title: Text(l10n.skill_configTitle),
            subtitle: Text(
              _enabledSkills.isEmpty
                  ? l10n.addAgent_noSkills
                  : l10n.addAgent_skillsCount(_enabledSkills.length),
              style: TextStyle(
                color: _enabledSkills.isEmpty
                    ? colorScheme.onSurfaceVariant
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
                _scheduleAutoSave();
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.terminal, color: colorScheme.primary),
            title: const Text('CLI Commands'),
            subtitle: Text(
              _enabledCliCommands.isEmpty
                  ? 'All CLI commands available (OS tools still require confirmation)'
                  : '${_enabledCliCommands.length} command(s) selected (restricted)',
              style: TextStyle(
                color: _enabledCliCommands.isEmpty
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
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
                _scheduleAutoSave();
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.share_outlined, color: colorScheme.primary),
            title: Text(
              Localizations.localeOf(context).languageCode.startsWith('zh')
                  ? '分享运行时上下文'
                  : 'Share runtime context',
            ),
            subtitle: Text(
              Localizations.localeOf(context).languageCode.startsWith('zh')
                  ? '将 runtime/${_agent.id}/ 只读分享给 Owner 配对设备'
                  : 'Share runtime/${_agent.id}/ read-only with Owner peers',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final n = await RuntimeShareService.instance
                  .shareOwnerRuntimeWithOwnerPeers(_agent.id);
              if (!mounted) return;
              final zh =
                  Localizations.localeOf(context).languageCode.startsWith('zh');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(zh
                      ? '已向 $n 台 Owner 设备分享运行时前缀'
                      : 'Shared runtime prefix with $n Owner peer(s)'),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.layers, color: colorScheme.primary),
            title: Text(
              Localizations.localeOf(context).languageCode.startsWith('zh')
                  ? '提示词栈'
                  : 'Prompt Stack',
            ),
            subtitle: Text(
              Localizations.localeOf(context).languageCode.startsWith('zh')
                  ? '工具 / 记忆 / 认知等系统提示词分层'
                  : 'Tools, memory, cognition layers in the system prompt',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<PromptStackConfig>(
                context,
                MaterialPageRoute(
                  builder: (_) => PromptStackConfigScreen(
                    initial: _promptStackConfig,
                    isShe: _agent.isShe,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _promptStackConfig = result;
                });
                _scheduleAutoSave();
              }
            },
          ),
        ],
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
