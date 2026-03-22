import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/model_definition.dart';
import '../models/remote_agent.dart';
import '../services/model_registry.dart';
import '../services/remote_agent_service.dart';
import '../services/local_database_service.dart';
import '../services/token_service.dart';
import 'os_tool_select_screen.dart';
import 'skill_select_screen.dart';
import 'model_select_screen.dart';
import 'model_management_screen.dart';

/// 添加远端助手界面
class AddRemoteAgentScreen extends StatefulWidget {
  /// Optional callback used in desktop embedded mode.
  /// When provided, called instead of Navigator.pop after completion.
  final VoidCallback? onDone;

  const AddRemoteAgentScreen({super.key, this.onDone});

  @override
  State<AddRemoteAgentScreen> createState() => _AddRemoteAgentScreenState();
}

enum AgentCreationMode {
  create, // 创建本地配置，生成 Token
  connect, // 连接到远端 Agent，输入 Token
}

class _AddRemoteAgentScreenState extends State<AddRemoteAgentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  final _endpointController = TextEditingController();
  final _tokenController = TextEditingController();
  final _systemPromptController = TextEditingController();
  final _remoteAgentIdController = TextEditingController();

  AgentCreationMode _mode = AgentCreationMode.create;
  String _selectedAvatar = '🤖';
  bool _isCreating = false;
  bool _allowExternalAccess = false;

  // 连接模式：从完整 URL 中解析出的 agentId（用于本地 agent 外部访问）
  String? _parsedTargetAgentId;

  // 主模型选择（从 ModelRegistry 中选择）
  String? _selectedMainModelId;

  // OS 工具配置
  Set<String> _enabledOsTools = {};

  // Skills 配置
  Set<String> _enabledSkills = {};

  // Tool Models 配置（toolName → 场景描述，空字符串表示使用全局描述）
  Map<String, String> _toolModelScenarios = {};

  late RemoteAgentService _agentService;

  void _finish() {
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.pop(context, true);
    }
  }

  @override
  void initState() {
    super.initState();
    final dbService = LocalDatabaseService();
    final tokenService = TokenService(dbService);
    _agentService = RemoteAgentService(dbService, tokenService);
    // Auto-parse token + agentId from a full URL pasted into the endpoint field
    _endpointController.addListener(_onEndpointChanged);
  }

  /// When the user pastes a full URL like ws://host:port?token=xxx&agentId=yyy,
  /// automatically split it: strip query params from the endpoint field, fill
  /// the token field, and remember the agentId for later.
  void _onEndpointChanged() {
    final text = _endpointController.text;
    // Only try to parse if the text looks like a URL with query params
    if (!text.contains('?')) return;

    Uri parsed;
    try {
      parsed = Uri.parse(text);
    } catch (_) {
      return;
    }

    final tokenParam = parsed.queryParameters['token'];
    final agentIdParam = parsed.queryParameters['agentId'];

    // Only auto-fill when at least one param is recognised
    if (tokenParam == null && agentIdParam == null) return;

    // Remove listener temporarily so our programmatic changes don't re-trigger
    _endpointController.removeListener(_onEndpointChanged);

    // Rewrite endpoint field to base URL (no query params)
    final cleanEndpoint = parsed.replace(query: '').toString();
    // replace() leaves a trailing '?', strip it
    _endpointController.value = TextEditingValue(
      text: cleanEndpoint.replaceAll(RegExp(r'\?$'), ''),
      selection: TextSelection.collapsed(
        offset: cleanEndpoint.replaceAll(RegExp(r'\?$'), '').length,
      ),
    );

    setState(() {
      if (tokenParam != null && tokenParam.isNotEmpty) {
        _tokenController.text = tokenParam;
      }
      _parsedTargetAgentId = (agentIdParam != null && agentIdParam.isNotEmpty)
          ? agentIdParam
          : null;
      _remoteAgentIdController.text = agentIdParam ?? '';
    });

    // Re-attach listener
    _endpointController.addListener(_onEndpointChanged);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _endpointController.removeListener(_onEndpointChanged);
    _endpointController.dispose();
    _tokenController.dispose();
    _systemPromptController.dispose();
    _remoteAgentIdController.dispose();
    super.dispose();
  }

  void _selectMainModel(String? modelId) {
    setState(() {
      _selectedMainModelId = modelId;
    });
  }

  void _generateRandomToken() {
    setState(() {
      _tokenController.text = const Uuid().v4();
    });
  }

  Future<void> _createAgent() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      // 构建 metadata（包含 LLM 配置）
      final Map<String, dynamic> metadata = {};
      AgentStatus? initialStatus;
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
          // Local LLM agents are always available
          initialStatus = AgentStatus.online;

          // Save enabled OS tools
          if (_enabledOsTools.isNotEmpty) {
            metadata['enabled_os_tools'] = _enabledOsTools.toList();
          }

          // Save enabled skills
          if (_enabledSkills.isNotEmpty) {
            metadata['enabled_skills'] = _enabledSkills.toList();
          }

          // Save enabled tool models and scenarios
          if (_toolModelScenarios.isNotEmpty) {
            metadata['enabled_tool_models'] = _toolModelScenarios.keys.toList();
            final nonEmptyScenarios = Map<String, String>.fromEntries(
              _toolModelScenarios.entries.where((e) => e.value.isNotEmpty),
            );
            if (nonEmptyScenarios.isNotEmpty) {
              metadata['tool_model_scenarios'] = nonEmptyScenarios;
            }
          }

          // Save allow_external_access
          metadata['allow_external_access'] = _allowExternalAccess;
        }
      }
      // system_prompt is a general agent config, independent of LLM provider
      if (_systemPromptController.text.trim().isNotEmpty) {
        metadata['system_prompt'] = _systemPromptController.text.trim();
      }

      await _agentService.createAgent(
        name: _nameController.text.trim(),
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: _endpointController.text.trim(),
        bio: _bioController.text.trim().isEmpty
            ? null
            : _bioController.text.trim(),
        avatar: _selectedAvatar,
        metadata: metadata,
        initialStatus: initialStatus,
      );

      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.addAgent_createSuccess),
          backgroundColor: Colors.green,
        ),
      );
      _finish();
    } on AgentDuplicateException catch (e) {
      if (!mounted) return;

      await _showDuplicateAgentDialog(e);

      setState(() {
        _isCreating = false;
      });
    } catch (e) {
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.addAgent_createFailed(e.toString())),
          backgroundColor: Colors.red,
        ),
      );

      setState(() {
        _isCreating = false;
      });
    }
  }

  Future<void> _connectToAgent() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      // Build metadata: store the targetAgentId when connecting to a local
      // agent exposed externally (parsed from the full access URL).
      final Map<String, dynamic> connectMetadata = {};
      final manualAgentId = _remoteAgentIdController.text.trim();
      final targetId = manualAgentId.isNotEmpty ? manualAgentId : _parsedTargetAgentId;
      if (targetId != null && targetId.isNotEmpty) {
        connectMetadata['target_agent_id'] = targetId;
      }

      final tempAgent = await _agentService.createAgentWithToken(
        name: _nameController.text.trim(),
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        endpoint: _endpointController.text.trim(),
        token: _tokenController.text.trim(),
        bio: _bioController.text.trim().isEmpty
            ? null
            : _bioController.text.trim(),
        avatar: _selectedAvatar,
        metadata: connectMetadata,
      );

      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Text(l10n.addAgent_testingConnection),
            ],
          ),
          duration: const Duration(seconds: 5),
        ),
      );

      final isHealthy = await _agentService.checkAgentHealth(
        tempAgent.id,
        timeout: const Duration(seconds: 10),
      );

      if (!mounted) return;

      if (isHealthy) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.addAgent_connectSuccess),
            backgroundColor: Colors.green,
          ),
        );
        _finish();
      } else {
        final shouldKeep = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.addAgent_connectFailTitle),
            content: Text(l10n.addAgent_connectFailContent),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.addAgent_deleteConfig),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.addAgent_keepConfig),
              ),
            ],
          ),
        );

        if (shouldKeep != true) {
          await _agentService.deleteAgent(tempAgent.id);

          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.addAgent_configDeleted),
              backgroundColor: Colors.orange,
            ),
          );
        } else {
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.addAgent_configKeptOffline),
              backgroundColor: Colors.orange,
            ),
          );
        }

        if (mounted) {
          _finish();
        }
      }
    } on AgentDuplicateException catch (e) {
      if (!mounted) return;

      await _showDuplicateAgentDialog(e);

      setState(() {
        _isCreating = false;
      });
    } catch (e) {
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.addAgent_operationFailed(e.toString())),
          backgroundColor: Colors.red,
        ),
      );

      setState(() {
        _isCreating = false;
      });
    }
  }

  Future<void> _showDuplicateAgentDialog(AgentDuplicateException e) async {
    final existingAgent = e.existingAgent;
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.addAgent_duplicateTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.message),
            const SizedBox(height: 12),
            Text(
              l10n.addAgent_existingInfo,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(l10n.addAgent_existingName(existingAgent.name)),
            if (existingAgent.endpoint.isNotEmpty)
              Text('Endpoint: ${existingAgent.endpoint}'),
            Text(l10n.addAgent_existingProtocol(existingAgent.protocol.name)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: Navigator.canPop(context),
        title: Text(_mode == AgentCreationMode.connect ? l10n.addAgent_connectTitle : l10n.addAgent_createTitle),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 模式切换 - SegmentedButton
              _buildModeSwitch(colorScheme),
              const SizedBox(height: 20),

              // 头像区域 - 渐变背景
              _buildAvatarSection(colorScheme),
              const SizedBox(height: 20),

              // 基本信息卡片
              _buildBasicInfoCard(colorScheme),
              const SizedBox(height: 16),

              // 连接配置卡片
              if (_mode == AgentCreationMode.connect)
                _buildConnectConfigCard(colorScheme),

              // 创建模式 - LLM 配置卡片
              if (_mode == AgentCreationMode.create)
                _buildLLMConfigCard(colorScheme),

              // 创建模式 - 允许外部访问开关
              if (_mode == AgentCreationMode.create) ...[
                const SizedBox(height: 16),
                _buildExternalAccessCard(colorScheme),
              ],

              // 创建模式 - OS 工具 / 技能 / 工具模型导航入口
              if (_mode == AgentCreationMode.create && _selectedMainModelId != null) ...[
                const SizedBox(height: 16),
                _buildConfigNavigationTiles(colorScheme),
              ],

              const SizedBox(height: 16),

              // 说明步骤卡片（仅连接模式显示）
              if (_mode == AgentCreationMode.connect) ...[
                _buildInstructionCard(colorScheme),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 24),

              // 操作按钮 - 渐变圆角
              _buildActionButton(colorScheme),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  /// 模式切换 - SegmentedButton
  Widget _buildModeSwitch(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<AgentCreationMode>(
        segments: [
          ButtonSegment<AgentCreationMode>(
            value: AgentCreationMode.create,
            icon: const Icon(Icons.add_circle_outline),
            label: Text(l10n.addAgent_modeCreate),
          ),
          ButtonSegment<AgentCreationMode>(
            value: AgentCreationMode.connect,
            icon: const Icon(Icons.link),
            label: Text(l10n.addAgent_modeConnect),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (Set<AgentCreationMode> selected) {
          setState(() {
            _mode = selected.first;
          });
        },
      ),
    );
  }

  /// 头像区域 - 渐变背景装饰
  Widget _buildAvatarSection(ColorScheme colorScheme) {
    return Center(
      child: GestureDetector(
        onTap: _showAvatarPicker,
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primaryContainer,
                colorScheme.secondaryContainer,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.2),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                _selectedAvatar,
                style: const TextStyle(fontSize: 52),
              ),
              Positioned(
                bottom: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.edit,
                    size: 14,
                    color: colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 基本信息卡片
  Widget _buildBasicInfoCard(ColorScheme colorScheme) {
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
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.addAgent_agentNameRequired;
                }
                return null;
              },
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

  /// 连接配置卡片（连接模式）
  Widget _buildConnectConfigCard(ColorScheme colorScheme) {
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

            // 端点 URL（移到第一位）
            TextFormField(
              controller: _endpointController,
              decoration: InputDecoration(
                labelText: l10n.addAgent_endpointUrl,
                hintText: l10n.addAgent_endpointUrlHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.language),
                helperText: l10n.addAgent_endpointHelper,
              ),
              keyboardType: TextInputType.url,
              validator: (value) {
                if (_mode == AgentCreationMode.connect) {
                  if (value == null || value.trim().isEmpty) {
                    return l10n.addAgent_endpointRequired;
                  }
                  if (!value.startsWith('http://') &&
                      !value.startsWith('https://') &&
                      !value.startsWith('ws://') &&
                      !value.startsWith('wss://')) {
                    return l10n.addAgent_endpointInvalid;
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Token 输入 - 特殊样式
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.vpn_key, size: 16, color: colorScheme.tertiary),
                      const SizedBox(width: 6),
                      Text(
                        l10n.addAgent_tokenAuth,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.tertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _tokenController,
                    decoration: InputDecoration(
                      hintText: l10n.addAgent_tokenHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.casino),
                        onPressed: _generateRandomToken,
                        tooltip: l10n.addAgent_generateToken,
                      ),
                    ),
                    validator: (value) {
                      if (_mode == AgentCreationMode.connect) {
                        if (value == null || value.trim().isEmpty) {
                          return l10n.addAgent_tokenRequired;
                        }
                      }
                      return null;
                    },
                    enableSuggestions: false,
                    autocorrect: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

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

  /// LLM 配置卡片（创建模式）——从模型管理列表中选择主模型
  Widget _buildLLMConfigCard(ColorScheme colorScheme) {
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
              ],
            ),
            const SizedBox(height: 12),

            if (defs.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ModelManagementScreen(),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: Text(l10n.toolModel_goToManagement),
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 13),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
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
                  // Compact display with type chips for the selected value
                  return Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF48FB1).withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            def.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      ...def.modelTypes.take(2).map((t) => Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: _modelTypeColor(t).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _modelTypeLabel(t),
                            style: TextStyle(
                              fontSize: 10,
                              color: _modelTypeColor(t),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      )),
                    ],
                  );
                }).toList(),
                items: defs.map((def) {
                  return DropdownMenuItem<String>(
                    value: def.id,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF48FB1).withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    def.displayName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              ...def.modelTypes.map((t) => Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _modelTypeColor(t).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _modelTypeColor(t).withValues(alpha: 0.3),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Text(
                                    _modelTypeLabel(t),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: _modelTypeColor(t),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              )),
                            ],
                          ),
                          if (def.route.model != null && def.route.model!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                def.route.model!,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.outline,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (val) => _selectMainModel(val),
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

  /// Navigation tiles for OS Tools, Skills, and Tool Models sub-pages.
  Widget _buildConfigNavigationTiles(ColorScheme colorScheme) {
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
            leading: Icon(Icons.build_circle, color: colorScheme.primary),
            title: Text(l10n.osTool_configTitle),
            subtitle: Text(
              _enabledOsTools.isEmpty
                  ? l10n.addAgent_noOsTools
                  : l10n.addAgent_osToolsCount(_enabledOsTools.length),
              style: TextStyle(
                color: _enabledOsTools.isEmpty
                    ? colorScheme.outline
                    : colorScheme.primary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await Navigator.push<Set<String>>(
                context,
                MaterialPageRoute(
                  builder: (_) => OsToolSelectScreen(
                    enabledTools: _enabledOsTools,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _enabledOsTools = result;
                });
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
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
        ],
      ),
    );
  }

  /// 说明步骤卡片（仅连接模式）
  Widget _buildInstructionCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    final steps = [
      (l10n.addAgent_connectStep1, Icons.vpn_key),
      (l10n.addAgent_connectStep2, Icons.language),
      (l10n.addAgent_connectStep3, Icons.chat),
    ];

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cable,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.addAgent_connectSteps,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...List.generate(steps.length, (index) {
              final (text, icon) = steps[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(icon, size: 18, color: colorScheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 允许外部访问卡片（创建模式）
  Widget _buildExternalAccessCard(ColorScheme colorScheme) {
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
        value: _allowExternalAccess,
        onChanged: (value) {
          setState(() => _allowExternalAccess = value);
        },
      ),
    );
  }

  /// 操作按钮 - 渐变色 + 圆角
  Widget _buildActionButton(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    final defs = ModelRegistry.instance.definitions;
    final isDisabled = _isCreating ||
        (_mode == AgentCreationMode.create && defs.isEmpty);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: isDisabled
            ? null
            : LinearGradient(
                colors: [
                  colorScheme.primary,
                  colorScheme.tertiary,
                ],
              ),
        color: isDisabled ? colorScheme.surfaceContainerHighest : null,
        boxShadow: isDisabled
            ? null
            : [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: isDisabled
              ? null
              : (_mode == AgentCreationMode.connect
                  ? _connectToAgent
                  : _createAgent),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _isCreating
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _mode == AgentCreationMode.connect
                              ? Icons.link
                              : Icons.add_circle,
                          color: isDisabled
                              ? colorScheme.outline
                              : Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _mode == AgentCreationMode.connect
                              ? l10n.addAgent_connectButton
                              : l10n.addAgent_createButton,
                          style: TextStyle(
                            color: isDisabled
                                ? colorScheme.outline
                                : Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Returns a color for a given model type tag.
  Color _modelTypeColor(ModelType modelType) {
    switch (modelType) {
      case ModelType.text:
        return const Color(0xFF1976D2);
      case ModelType.imageUnderstanding:
        return const Color(0xFF388E3C);
      case ModelType.imageGeneration:
        return const Color(0xFF7B1FA2);
      case ModelType.audioUnderstanding:
        return const Color(0xFFE64A19);
      case ModelType.videoUnderstanding:
        return const Color(0xFF0097A7);
      case ModelType.videoGeneration:
        return const Color(0xFF00796B);
      case ModelType.tts:
        return const Color(0xFFF57C00);
    }
  }

  /// Returns a short label for a given model type.
  String _modelTypeLabel(ModelType modelType) {
    switch (modelType) {
      case ModelType.text:
        return 'Text';
      case ModelType.imageUnderstanding:
        return 'Vision';
      case ModelType.imageGeneration:
        return 'ImgGen';
      case ModelType.audioUnderstanding:
        return 'Audio';
      case ModelType.videoUnderstanding:
        return 'Video';
      case ModelType.videoGeneration:
        return 'VideoGen';
      case ModelType.tts:
        return 'TTS';
    }
  }

  void _showAvatarPicker() {
    final l10n = AppLocalizations.of(context);
    final avatars = [
      '🤖', '🦾', '🧠', '💡', '🌟', '⚡', '🔮', '🎯',
      '🚀', '🛸', '🌈', '🔥', '💎', '🎨', '🎭', '🎪',
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
                    _selectedAvatar = avatar;
                  });
                  Navigator.pop(context);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _selectedAvatar == avatar
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
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
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
        ],
      ),
    );
  }
}
