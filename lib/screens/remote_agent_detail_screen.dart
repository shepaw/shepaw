import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/avatar_image.dart';
import '../l10n/l10n_helpers.dart';
import '../l10n/app_localizations.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/engine_session_modes.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import '../services/remote_agent_service.dart';
import '../services/she_service.dart';
import '../services/agent_soul_service.dart';
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
import 'agent_memory_detail_screen.dart';
import 'agent_runtime_context_screen.dart';
import 'agent_soul_edit_screen.dart';
import 'storage_directory_opener.dart';
import '../storage/agent_workspace_uris.dart';
import '../storage/store_protocol.dart';
import '../widgets/host_directory_picker.dart';

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

  /// Cached soul text for view mode (loaded from file / peer / metadata).
  String _displaySoul = '';
  bool _soulLoading = false;

  /// Peer agent: host allows remote soul edit.
  bool _peerSoulEditable = false;

  /// Local agent: allow paired devices to edit soul.
  bool _allowPeerSoulEdit = false;
  bool _allowPeerMemoryEdit = false;

  /// Upstream model list from the paired device's agent (peer agents only).
  List<PeerAgentModel> _peerModels = const [];
  String? _peerCurrentModel;
  bool _peerModelsLoading = false;
  bool _peerModelSetting = false;
  String? _peerModelsError;

  /// Upstream session-mode list from the paired device's agent (peer agents only).
  List<PeerAgentMode> _peerModes = const [];
  String? _peerCurrentMode;
  bool _peerModesLoading = false;
  bool _peerModeSetting = false;
  String? _peerModesError;

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

  bool get _canEditSoul => !_agent.isPeerAgent || _peerSoulEditable;

  /// Keep first occurrence for each [keyOf] — DropdownButton requires unique values.
  static List<T> _uniqueByValue<T>(
    Iterable<T> items,
    String Function(T item) keyOf,
  ) {
    final seen = <String>{};
    final out = <T>[];
    for (final item in items) {
      final key = keyOf(item);
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(item);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _agent = widget.agent;
    _isEditing = widget.initialEditMode;
    _allowPeerSoulEdit = _agent.peerBoundaryConfig.allowPeerSoulEdit;
    _allowPeerMemoryEdit = _agent.peerBoundaryConfig.allowPeerMemoryEdit;
    _initEditingControllers();
    unawaited(_loadSoul());

    // peer agent 的在线状态完全取决于来源配对设备是否在线，订阅连接状态变化
    // 以便设备上/下线时即时刷新页面顶部的状态徽标。
    if (_agent.isPeerAgent) {
      _peerConnSub =
          PeerConnectionManager.instance.events.listen((event) {
        if (event.peerId != _agent.sourcePeerId || !mounted) return;
        if (event.type == PeerConnectionEventType.connected) {
          unawaited(_loadPeerModels());
          unawaited(_loadPeerModes());
          unawaited(_loadSoul());
        }
        setState(() {});
      });
      _loadPeerSyncPref();
      unawaited(_refreshPeerAgentRow());
      if (_isEditing) {
        _loadPeerModels();
        _loadPeerModes();
      }
    }
  }

  Future<void> _refreshPeerAgentRow() async {
    try {
      final latest = await getIt<RemoteAgentService>().getAgentById(_agent.id);
      if (!mounted || latest == null) return;
      setState(() => _agent = latest);
    } catch (_) {}
  }

  Future<void> _loadSoul() async {
    if (!mounted) return;
    setState(() => _soulLoading = true);
    try {
      if (_agent.isPeerAgent) {
        final peerId = _agent.sourcePeerId;
        final remoteId = _agent.remoteAgentId;
        if (peerId != null &&
            remoteId != null &&
            PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
          final info = await PeerAgentClientService.instance.fetchSoulInfo(
            peerId: peerId,
            remoteAgentId: remoteId,
          );
          if (!mounted) return;
          setState(() {
            _displaySoul = info?.soul ?? '';
            _peerSoulEditable = info?.editable ?? false;
            _systemPromptController.text = _displaySoul;
            _soulLoading = false;
          });
          return;
        }
      }

      final soul = await AgentSoulService.instance.getSoul(_agent);
      if (!mounted) return;
      setState(() {
        _displaySoul = soul;
        _systemPromptController.text = soul;
        _soulLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _soulLoading = false);
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
      _peerModels = _uniqueByValue(list.models, (m) => m.value);
      _peerCurrentModel = list.current;
      if (_peerModels.isEmpty) {
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

  Future<void> _loadPeerModes() async {
    final l10n = AppLocalizations.of(context);
    if (!_agent.isPeerAgent) return;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    final catalog = catalogModesList(
      _agent.metadata['engine'] as String?,
    );
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      if (mounted) {
        setState(() {
          _peerModes = _uniqueByValue(catalog.modes, (m) => m.value);
          _peerCurrentMode = catalog.current;
          _peerModesError = catalog.modes.isEmpty
              ? l10n.agentDetail_peerOffline
              : null;
          _peerModesLoading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _peerModesLoading = true;
        _peerModesError = null;
        if (catalog.modes.isNotEmpty) {
          _peerModes = _uniqueByValue(catalog.modes, (m) => m.value);
          _peerCurrentMode = catalog.current;
        }
      });
    }
    final list = await PeerAgentClientService.instance.fetchModes(
      peerId: peerId,
      remoteAgentId: remoteId,
    );
    if (!mounted) return;
    final live = list.modes.isNotEmpty ? list : catalog;
    setState(() {
      _peerModesLoading = false;
      _peerModes = _uniqueByValue(live.modes, (m) => m.value);
      _peerCurrentMode = live.current;
      if (live.modes.isEmpty) {
        _peerModesError = l10n.agentDetail_modeSwitchUnsupported;
      }
    });
  }

  Future<void> _onPeerModeSelected(String? value) async {
    final l10n = AppLocalizations.of(context);
    if (value == null || value == _peerCurrentMode || _peerModeSetting) return;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    setState(() => _peerModeSetting = true);
    final ok = await PeerAgentClientService.instance.setMode(
      peerId: peerId,
      remoteAgentId: remoteId,
      mode: value,
    );
    if (!mounted) return;
    setState(() {
      _peerModeSetting = false;
      if (ok) _peerCurrentMode = value;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.agentDetail_modeSwitched : l10n.agentDetail_modeSwitchFailed),
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
    _systemPromptController = TextEditingController(text: '');
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
    _allowPeerSoulEdit = _agent.peerBoundaryConfig.allowPeerSoulEdit;
    _allowPeerMemoryEdit = _agent.peerBoundaryConfig.allowPeerMemoryEdit;

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
    unawaited(_loadSoul());
    if (_agent.isPeerAgent) {
      unawaited(_loadPeerModels());
      unawaited(_loadPeerModes());
    }
  }

  void _scheduleAutoSave() {
    if (!_isEditing) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistChanges());
    });
  }

  /// 打开 Soul 详情（可查看；无编辑权时页面内只读）。
  Future<void> _openSoulDetail({required bool requireEditable}) async {
    final l10n = AppLocalizations.of(context);
    if (requireEditable && !_canEditSoul) return;
    if (_agent.isPeerAgent) {
      final peerId = _agent.sourcePeerId;
      if (peerId == null ||
          !PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.agentDetail_peerOffline)),
          );
        }
        return;
      }
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AgentSoulEditScreen(agent: _agent),
      ),
    );
    if (mounted) unawaited(_loadSoul());
  }

  Future<void> _openSoulEditor() => _openSoulDetail(requireEditable: true);

  Future<void> _openMemoryDetail() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentMemoryDetailScreen(agent: _agent),
      ),
    );
  }

  void _syncControllersFromAgent() {
    final l10n = AppLocalizations.of(context);
    _nameController.text = _agent.isShe
        ? SheService.resolveDisplayName(_agent.name, l10n.she_name)
        : _agent.name;
    _bioController.text = _agent.bio ?? '';
    _endpointController.text = _agent.endpoint;
    _systemPromptController.text = _displaySoul;
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
    _allowPeerSoulEdit = _agent.peerBoundaryConfig.allowPeerSoulEdit;
    _allowPeerMemoryEdit = _agent.peerBoundaryConfig.allowPeerMemoryEdit;
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

  /// Mutate state without scheduling a rebuild during Overlay teardown / dispose.
  void _safeSetState(VoidCallback fn) {
    if (!mounted) {
      fn();
      return;
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(fn);
      return;
    }
    fn();
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

    // Snapshot controller values before any await — deactivate/dispose may
    // run in this same frame while Overlay is rebuilding.
    final avatarSeed = _editingAvatar;
    final localAvatarPath = _localAvatarPath;
    final bioText = _bioController.text.trim();
    final endpoint = _endpointController.text.trim();
    final remoteAgentId = _remoteAgentIdController.text.trim();
    final maxToolRoundsText = _maxToolRoundsController.text.trim();
    final taskTimeoutText = _taskTimeoutController.text.trim();

    // v2.1: token is no longer required — authentication is handled via Noise
    // public-key pinning. Keep reading the field so users who still have an
    // old token stored can clear or update it, but never block saving on it.

    _safeSetState(() => _isSaving = true);

    try {
      // 如果有本地上传的图片，先解析出完整路径存储
      String avatar = avatarSeed;
      if (localAvatarPath != null) {
        final fullPath = await _fileStorage.getFullPath(localAvatarPath);
        avatar = fullPath;
      }

      // Build updated metadata
      final Map<String, dynamic> metadata = Map<String, dynamic>.from(_agent.metadata);

      // peer agent：本地一旦改过头像，打上标记，后续从对端同步时以本地为准，
      // 不再被对端分享的头像覆盖。
      if (_agent.isPeerAgent && avatar != _agent.avatar) {
        metadata['avatar_overridden'] = true;
      }

      // Soul 权威在储物袋 cognition/<agent>/soul.md；agent 行不再携带 system_prompt。
      metadata.remove('system_prompt');

      // Peer-inbound boundary (local agents shared over P2P).
      if (_isLocalMode) {
        metadata['peer_boundary'] = _agent.peerBoundaryConfig
            .copyWith(
              allowPeerSoulEdit: _allowPeerSoulEdit,
              allowPeerMemoryEdit: _allowPeerMemoryEdit,
            )
            .toJson();
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

      if (remoteAgentId.isNotEmpty) {
        metadata['target_agent_id'] = remoteAgentId;
      } else {
        metadata.remove('target_agent_id');
      }

      // Save tool call limits (local / self-managed remote agents only)
      if (!_agent.isPeerAgent) {
        final maxToolRounds = int.tryParse(maxToolRoundsText);
        if (maxToolRounds != null && maxToolRounds >= 1 && maxToolRounds <= 500) {
          metadata['max_tool_rounds'] = maxToolRounds;
        } else {
          metadata['max_tool_rounds'] = 100;
        }
      }
      final taskTimeout = int.tryParse(taskTimeoutText);
      if (taskTimeout != null && taskTimeout >= 60 && taskTimeout <= 3600) {
        metadata['task_timeout_seconds'] = taskTimeout;
      } else {
        metadata['task_timeout_seconds'] = 600;
      }

      final updatedAgent = _agent.copyWith(
        name: name,
        bio: bioText.isEmpty ? null : bioText,
        avatar: avatar,
        endpoint: endpoint,
        protocol: _editingProtocol,
        connectionType: _editingConnectionType,
        metadata: metadata,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      final agentService = getIt<RemoteAgentService>();
      await agentService.updateAgent(updatedAgent);

      _safeSetState(() {
        _agent = updatedAgent;
        _isSaving = false;
      });

      if (mounted && showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.agentDetail_saveSuccess)),
        );
      }
    } catch (e) {
      _safeSetState(() => _isSaving = false);
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
    final colorScheme = Theme.of(context).colorScheme;
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
        const SizedBox(height: 16),
        _buildSoulEntry(),
        const SizedBox(height: 16),
        _buildMemoryEntry(),
        const SizedBox(height: 16),
        _buildRuntimeContextEntry(),
        const SizedBox(height: 16),
        _buildWorkspaceViewEntry(),
        if (_agent.isShe && !_agent.isPeerAgent) ...[
          const SizedBox(height: 16),
          _buildSheCircleEntry(),
        ],
        if (_isLocalMode) ...[
          const SizedBox(height: 16),
          _buildSkillsCard(),
          const SizedBox(height: 16),
          _buildCliCommandsCard(),
          // 分享给配对设备（仅本地 agent 显示，查看模式只读）
          const SizedBox(height: 16),
          _buildExternalAccessCard(colorScheme),
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
    final models = _uniqueByValue(_peerModels, (m) => m.value);
    final effectiveCurrent = _peerCurrentModel ??
        (models.length == 1 ? models.first.value : null);
    final dropdownValue = effectiveCurrent != null &&
            models.any((m) => m.value == effectiveCurrent)
        ? effectiveCurrent
        : null;

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
          if (_peerModelsError != null && models.isEmpty)
            Text(
              _peerModelsError!,
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            )
          else if (models.isEmpty && _peerModelsLoading)
            const SizedBox.shrink()
          else if (models.isEmpty)
            Text(
              l10n.agentDetail_noModels,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            )
          else
            DropdownButtonFormField<String>(
              value: dropdownValue,
              isExpanded: true,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: colorScheme.surface,
              ),
              hint: Text(l10n.addAgent_selectModel),
              selectedItemBuilder: (context) => models
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
              items: [
                for (final m in models)
                  DropdownMenuItem<String>(
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
              ],
              onChanged: busy ? null : _onPeerModelSelected,
            ),
        ],
      ),
    );
  }

  /// Upstream session-mode picker — switches the remote agent's native mode
  /// via `agent.modes.setCurrent` on the paired device.
  Widget _buildPeerModePicker() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final busy = _peerModesLoading || _peerModeSetting;
    final modes = _uniqueByValue(_peerModes, (m) => m.value);
    final effectiveCurrent = _peerCurrentMode ??
        (modes.length == 1 ? modes.first.value : null);
    final dropdownValue = effectiveCurrent != null &&
            modes.any((m) => m.value == effectiveCurrent)
        ? effectiveCurrent
        : null;

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
              Icon(Icons.tune_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                l10n.agentDetail_mode,
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
                  tooltip: l10n.agentDetail_refreshModes,
                  onPressed: _loadPeerModes,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.agentDetail_switchModeHint,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          if (_peerModesError != null && modes.isEmpty)
            Text(
              _peerModesError!,
              style: TextStyle(fontSize: 12, color: colorScheme.error),
            )
          else if (modes.isEmpty && _peerModesLoading)
            const SizedBox.shrink()
          else if (modes.isEmpty)
            Text(
              l10n.agentDetail_noModes,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            )
          else
            DropdownButtonFormField<String>(
              value: dropdownValue,
              isExpanded: true,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: colorScheme.surface,
              ),
              hint: Text(l10n.agentDetail_mode),
              selectedItemBuilder: (context) => modes
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
              items: [
                for (final m in modes)
                  DropdownMenuItem<String>(
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
              ],
              onChanged: busy ? null : _onPeerModeSelected,
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

  /// 打开该 Agent 已挂载的储物袋工作区（主 + 附加）。
  /// Hub 可管理实例支持设置主工作区、增删附加工作区。
  Widget _buildWorkspaceViewEntry() {
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final canEditWorkspace = _agent.isPeerAgent &&
        _agent.peerAgentManageable &&
        _agent.sourcePeerId != null &&
        _agent.remoteAgentId != null;
    return FutureBuilder<List<String>>(
      future: collectAgentWorkspaceUris(_agent),
      builder: (context, snapshot) {
        final uris = snapshot.data ?? const <String>[];
        final hasPrimary = uris.isNotEmpty;
        if (uris.isEmpty && !canEditWorkspace) {
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            child: ListTile(
              leading: Icon(Icons.folder_open_outlined, color: colorScheme.primary),
              title: Text(zh ? '查看工作区' : 'View workspace'),
              subtitle: Text(
                zh
                    ? '在储物袋中打开该 Agent 挂载的工作目录'
                    : 'Open this agent\'s mounted working directory in Nexus Pouch',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openAgentWorkspace(),
            ),
          );
        }
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (uris.isEmpty)
                ListTile(
                  leading: Icon(Icons.folder_off_outlined, color: colorScheme.onSurfaceVariant),
                  title: Text(zh ? '暂无挂载工作区' : 'No mounted workspace'),
                  subtitle: Text(
                    zh
                        ? (canEditWorkspace
                            ? '可设置 Hub 主机上的绝对路径作为主工作区'
                            : '该 Agent 尚未挂载工作目录')
                        : (canEditWorkspace
                            ? 'Set an absolute path on the Hub host as the primary workspace'
                            : 'This agent has no mounted working directory'),
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              for (var i = 0; i < uris.length; i++) ...[
                if (i > 0) Divider(height: 1, color: colorScheme.outlineVariant),
                ListTile(
                  leading: Icon(
                    i == 0 ? Icons.folder_special_outlined : Icons.folder_open_outlined,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    i == 0
                        ? (zh ? '主工作区' : 'Primary workspace')
                        : (zh ? '附加工作区 $i' : 'Additional workspace $i'),
                  ),
                  subtitle: Text(
                    _workspaceDisplayName(uris[i]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canEditWorkspace && i > 0)
                        IconButton(
                          tooltip: zh ? '移除附加工作区' : 'Remove additional workspace',
                          icon: Icon(Icons.remove_circle_outline, color: colorScheme.error),
                          onPressed: () => _removeAdditionalWorkspace(uris[i]),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _openAgentWorkspace(preferredUri: uris[i]),
                ),
              ],
              if (canEditWorkspace) ...[
                if (uris.isNotEmpty)
                  Divider(height: 1, color: colorScheme.outlineVariant),
                if (!hasPrimary)
                  ListTile(
                    leading: Icon(Icons.create_new_folder_outlined, color: colorScheme.primary),
                    title: Text(zh ? '设置主工作区' : 'Set primary workspace'),
                    subtitle: Text(
                      zh
                          ? '浏览选择目录（默认用户主目录）；运行中实例会自动重启'
                          : 'Browse to pick a folder (defaults to home); a running instance will restart',
                      style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.add),
                    onTap: _setPrimaryWorkspace,
                  )
                else
                  ListTile(
                    leading: Icon(Icons.create_new_folder_outlined, color: colorScheme.primary),
                    title: Text(zh ? '添加附加工作区' : 'Add additional workspace'),
                    subtitle: Text(
                      zh
                          ? '浏览选择目录（默认用户主目录）；运行中实例会自动重启'
                          : 'Browse to pick a folder (defaults to home); a running instance will restart',
                      style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.add),
                    onTap: _addAdditionalWorkspace,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<List<String>> _currentAdditionalDirectories() async {
    final fromMeta = additionalDirectoriesFromMetadata(_agent.metadata);
    if (fromMeta.isNotEmpty) return fromMeta;
    final uris = await collectAgentWorkspaceUris(_agent);
    final out = <String>[];
    for (var i = 1; i < uris.length; i++) {
      final path = absolutePathFromWorkspaceUri(uris[i]);
      if (path != null) out.add(path);
    }
    return out;
  }

  Future<String?> _promptAbsoluteDirectory({
    required String titleZh,
    required String titleEn,
  }) async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final peerId = _agent.sourcePeerId;
    final useRemoteBrowse = _agent.isPeerAgent;

    Future<HostFsBrowseResult> browse(String? path) async {
      if (useRemoteBrowse) {
        if (peerId == null ||
            !PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
          throw Exception(zh ? '设备未连接' : 'Device offline');
        }
        final result = await PeerAgentClientService.instance.browseRemoteFs(
          peerId: peerId,
          path: path,
        );
        if (!result.ok) {
          final err = result.error ?? 'browse failed';
          if (result.unsupported || err == 'timeout') {
            throw Exception(
              zh
                  ? 'Hub 未响应目录浏览。请升级并重启 peer 服务后重试。'
                  : 'Hub did not answer directory browse. Upgrade and restart the peer service, then retry.',
            );
          }
          throw Exception(err);
        }
        return HostFsBrowseResult(
          path: result.path,
          parent: result.parent,
          entries: [
            for (final e in result.entries)
              HostFsBrowseEntry(name: e.name, path: e.path),
          ],
        );
      }
      return browseLocalDirectory(path);
    }

    return showHostDirectoryPicker(
      context: context,
      browse: browse,
      title: zh ? titleZh : titleEn,
    );
  }

  Future<void> _setPrimaryWorkspace() async {
    final path = await _promptAbsoluteDirectory(
      titleZh: '设置主工作区',
      titleEn: 'Set primary workspace',
    );
    if (path == null || !mounted) return;
    await _applyCwd(path);
  }

  Future<void> _addAdditionalWorkspace() async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final path = await _promptAbsoluteDirectory(
      titleZh: '添加附加工作区',
      titleEn: 'Add additional workspace',
    );
    if (path == null || !mounted) return;

    final current = await _currentAdditionalDirectories();
    if (current.contains(path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(zh ? '该目录已在附加工作区中' : 'Directory already added')),
      );
      return;
    }
    await _applyAdditionalDirectories([...current, path]);
  }

  Future<void> _removeAdditionalWorkspace(String uri) async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final path = absolutePathFromWorkspaceUri(uri);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(zh ? '无法解析该工作区路径' : 'Cannot resolve workspace path')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '移除附加工作区' : 'Remove additional workspace'),
        content: Text(zh ? '确定移除：\n$path' : 'Remove:\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(zh ? '移除' : 'Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final current = await _currentAdditionalDirectories();
    await _applyAdditionalDirectories(
      current.where((p) => p != path).toList(),
    );
  }

  Future<void> _applyCwd(String cwd) async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;

    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(zh ? '设备未连接' : 'Device offline')),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final result = await PeerAgentClientService.instance.setCwd(
      peerId: peerId,
      remoteAgentId: remoteId,
      cwd: cwd,
    );

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            zh
                ? '设置失败：${result.error ?? "unknown"}'
                : 'Update failed: ${result.error ?? "unknown"}',
          ),
        ),
      );
      return;
    }

    await PeerAgentClientService.instance.refreshAgentList(peerId);
    try {
      final latest = await getIt<RemoteAgentService>().getAgentById(_agent.id);
      if (latest != null && mounted) {
        setState(() => _agent = latest);
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(zh ? '主工作区已更新' : 'Primary workspace updated'),
      ),
    );
  }

  Future<void> _applyAdditionalDirectories(List<String> directories) async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;

    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(zh ? '设备未连接' : 'Device offline')),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final result = await PeerAgentClientService.instance.setAdditionalDirectories(
      peerId: peerId,
      remoteAgentId: remoteId,
      directories: directories,
    );

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            zh
                ? '更新失败：${result.error ?? "unknown"}'
                : 'Update failed: ${result.error ?? "unknown"}',
          ),
        ),
      );
      return;
    }

    await PeerAgentClientService.instance.refreshAgentList(peerId);
    try {
      final latest = await getIt<RemoteAgentService>().getAgentById(_agent.id);
      if (latest != null && mounted) {
        setState(() => _agent = latest);
      }
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          zh ? '附加工作区已更新' : 'Additional workspaces updated',
        ),
      ),
    );
  }

  String _workspaceDisplayName(String rawUri) {
    final uri = canonicalizeStoreWorkspaceUri(rawUri) ?? rawUri;
    try {
      final parsed = parseStoreUri(uri, allowEmptyPath: true);
      final path = parsed.path.replaceAll(RegExp(r'/+$'), '');
      if (path.isEmpty) return uri;
      return '/$path';
    } catch (_) {
      return uri;
    }
  }

  Future<void> _openAgentWorkspace({String? preferredUri}) async {
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    var agent = _agent;
    try {
      final latest = await getIt<RemoteAgentService>().getAgentById(agent.id);
      if (latest != null) agent = latest;
    } catch (_) {}

    var uris = await collectAgentWorkspaceUris(agent);
    final peerId = agent.sourcePeerId;
    if (primaryWorkspaceUri(uris) == null &&
        agent.isPeerAgent &&
        peerId != null &&
        PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      await PeerAgentClientService.instance.refreshAgentList(peerId);
      if (!mounted) return;
      try {
        final latest = await getIt<RemoteAgentService>().getAgentById(agent.id);
        if (latest != null) agent = latest;
      } catch (_) {}
      uris = await collectAgentWorkspaceUris(agent);
    }
    if (mounted && agent.id == _agent.id) {
      setState(() => _agent = agent);
    }

    final preferred = preferredUri == null
        ? null
        : (canonicalizeStoreWorkspaceUri(preferredUri) ?? preferredUri);
    String? rawUri;
    if (preferred != null) {
      final preferredKey = preferred.replaceAll(RegExp(r'/+$'), '');
      for (final u in uris) {
        final key = (canonicalizeStoreWorkspaceUri(u) ?? u).replaceAll(RegExp(r'/+$'), '');
        if (key == preferredKey) {
          rawUri = u;
          break;
        }
      }
      rawUri ??= preferred;
    }
    rawUri ??= primaryWorkspaceUri(uris);
    if (!mounted) return;
    if (rawUri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(zh ? '该 Agent 还没有挂载工作区' : 'This agent has no mounted workspace'),
        ),
      );
      return;
    }
    final uri = canonicalizeStoreWorkspaceUri(rawUri) ?? rawUri;
    try {
      final parsed = parseStoreUri(uri, allowEmptyPath: true);
      registerStorageDirectoryOpener();
      await openStorageDirectoryInBrowser(
        context,
        space: parsed.space,
        deviceId: parsed.device,
        path: parsed.path,
        peerIdHint: agent.sourcePeerId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(zh ? '无法打开工作区：$e' : 'Cannot open workspace: $e'),
        ),
      );
    }
  }

  /// Soul：独立入口，点进查看 / 修改。
  Widget _buildSoulEntry() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    final preview = _displaySoul.trim();
    final subtitle = _soulLoading
        ? (zh ? '加载中…' : 'Loading…')
        : preview.isEmpty
            ? (zh ? '定义 Agent 的身份、角色与原则' : 'Define identity, role, and principles')
            : (preview.length > 80 ? '${preview.substring(0, 80)}…' : preview);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(Icons.psychology_outlined, color: colorScheme.primary),
        title: Text(l10n.agentDetail_systemPrompt),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _soulLoading
            ? null
            : () => unawaited(_openSoulDetail(requireEditable: false)),
      ),
    );
  }

  /// 记忆：独立入口，点进查看 / 管理。
  Widget _buildMemoryEntry() {
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(Icons.auto_stories_outlined, color: colorScheme.primary),
        title: Text(zh ? '记忆' : 'Memory'),
        subtitle: Text(
          zh ? '查看与管理该 Agent 的结构化记忆' : 'Browse and manage structured memories',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => unawaited(_openMemoryDetail()),
      ),
    );
  }

  /// 产物 / 附件（runtime 文件）。
  Widget _buildRuntimeContextEntry() {
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode.startsWith('zh');
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: Icon(Icons.inventory_2_outlined, color: colorScheme.primary),
        title: Text(zh ? '产物 · 附件' : 'Artifacts · Attachments'),
        subtitle: Text(
          zh
              ? '查看该 Agent 的 runtime 产物与附件'
              : 'Browse runtime artifacts and attachments',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AgentRuntimeContextScreen(
                ownerId: _agent.id,
                displayName: _agent.name,
                agent: _agent,
              ),
            ),
          );
        },
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

  // ==================== 外部访问（查看模式） ====================

  /// 分享给配对设备卡片（详情模式，仅本地 agent，只读）。
  Widget _buildExternalAccessCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isEnabled = _agent.allowExternalAccess;
    final soulEditEnabled = _agent.peerBoundaryConfig.allowPeerSoulEdit;
    final memoryEditEnabled = _agent.peerBoundaryConfig.allowPeerMemoryEdit;

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
            if (isEnabled) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      soulEditEnabled
                          ? l10n.agent_allowPeerSoulEdit
                          : l10n.chat_soulReadOnlyPeer,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    soulEditEnabled ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: soulEditEnabled
                        ? Colors.green
                        : colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.auto_stories_outlined,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      memoryEditEnabled
                          ? l10n.agent_allowPeerMemoryEdit
                          : l10n.agent_memoryReadOnlyPeer,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    memoryEditEnabled ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: memoryEditEnabled
                        ? Colors.green
                        : colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 分享给配对设备（编辑模式） ====================

  /// 分享给配对设备 + Soul 编辑权限（仅编辑模式）。
  Widget _buildEditSharingSettingsCard(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          SwitchListTile(
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
          if (_editingAllowExternalAccess) ...[
            const Divider(height: 1),
            SwitchListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              secondary: Icon(Icons.psychology_outlined, color: colorScheme.primary),
              title: Text(
                l10n.agent_allowPeerSoulEdit,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                l10n.agent_allowPeerSoulEditDesc,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              value: _allowPeerSoulEdit,
              onChanged: (value) {
                setState(() => _allowPeerSoulEdit = value);
                _scheduleAutoSave();
              },
            ),
            const Divider(height: 1),
            SwitchListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              secondary:
                  Icon(Icons.auto_stories_outlined, color: colorScheme.primary),
              title: Text(
                l10n.agent_allowPeerMemoryEdit,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                l10n.agent_allowPeerMemoryEditDesc,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              value: _allowPeerMemoryEdit,
              onChanged: (value) {
                setState(() => _allowPeerMemoryEdit = value);
                _scheduleAutoSave();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEditSoulEntry(ColorScheme colorScheme) {
    final l10n = AppLocalizations.of(context);
    final preview = _displaySoul.trim();
    final subtitle = preview.isEmpty
        ? l10n.addAgent_systemPromptHint
        : (preview.length > 80 ? '${preview.substring(0, 80)}…' : preview);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(Icons.psychology_outlined, color: colorScheme.primary),
        title: Text(
          l10n.chat_customSystemPrompt,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _soulLoading ? '…' : subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _soulLoading ? null : _openSoulEditor,
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
        if (_canEditSoul) ...[
          const SizedBox(height: 16),
          _buildEditSoulEntry(colorScheme),
        ],
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
          _buildPeerModePicker(),
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
          _buildEditSharingSettingsCard(colorScheme),
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
