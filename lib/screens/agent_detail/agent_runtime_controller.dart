import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/remote_agent.dart';
import '../../peer/engine_session_modes.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/services/peer_connection.dart'
    show PeerConnectionEvent, PeerConnectionEventType;
import '../../peer/services/peer_connection_manager.dart';
import '../../services/remote_agent_service.dart';
import '../../services/database/peer_agent_meta_cache_dao.dart';
import '../../services/session/client_session_sync.dart';
import '../../service_locator.dart' show getIt;
import 'agent_detail_kind.dart';

/// 页面级加载失败的原因。UI 负责翻译成文案。
enum AgentRuntimeIssue { none, peerOffline, notSwitchable, unsupported, fetchFailed }

/// 一次写操作的结果。`null` = 成功，其余由 UI 提示。
enum AgentActionFailure { notSwitchable, peerOffline, failed }

/// 详情页与编辑页共用的运行时状态：模型、模式、客户端会话同步、Soul 预览。
///
/// 原来这些逻辑散在 3855 行的 `remote_agent_detail_screen.dart` 里，且只在编辑
/// 模式下才加载（详情页看不到当前模型）。这里抽出来后两个页面都能读。
///
/// 详情页和编辑页各持有一个实例；两个页面都订阅了主机的 `metaChanged`，
/// 任一处切换成功后两边都会刷新。
class AgentRuntimeController extends ChangeNotifier {
  AgentRuntimeController(RemoteAgent agent) : _agent = agent;

  RemoteAgent _agent;
  RemoteAgent get agent => _agent;

  AgentDetailKind get kind => agentDetailKindOf(_agent);

  StreamSubscription<PeerConnectionEvent>? _connSub;
  StreamSubscription<({String agentId, String kind})>? _metaSub;
  bool _subscribed = false;

  // ── 模型 ────────────────────────────────────────────────────────────
  List<PeerAgentModel> _models = const [];
  String? _currentModel;
  bool _modelsLoading = false;
  bool _modelSwitching = false;
  bool _optionSwitching = false;
  bool _modelsSwitchable = true;
  Map<String, String> _modelOptionValues = const {};
  AgentRuntimeIssue _modelsIssue = AgentRuntimeIssue.none;

  List<PeerAgentModel> get models => _models;
  String? get currentModel => _currentModel;
  bool get modelsLoading => _modelsLoading;
  bool get modelsBusy => _modelsLoading || _modelSwitching || _optionSwitching;
  bool get modelsSwitchable => _modelsSwitchable;
  Map<String, String> get modelOptionValues => _modelOptionValues;
  AgentRuntimeIssue get modelsIssue => _modelsIssue;

  /// 模型带参数（Fast / Context …）时用 Cursor 面板，否则用下拉。
  bool get modelsParameterized => _models.any((m) => m.options.isNotEmpty);

  // ── 模式 ────────────────────────────────────────────────────────────
  List<PeerAgentMode> _modes = const [];
  String? _currentMode;
  bool _modesLoading = false;
  bool _modeSwitching = false;
  AgentRuntimeIssue _modesIssue = AgentRuntimeIssue.none;

  List<PeerAgentMode> get modes => _modes;
  String? get currentMode => _currentMode;
  bool get modesBusy => _modesLoading || _modeSwitching;
  AgentRuntimeIssue get modesIssue => _modesIssue;

  // ── 客户端会话同步 ───────────────────────────────────────────────────
  bool _sessionSyncEnabled = true;
  bool _syncSwitching = false;

  bool get sessionSyncEnabled => _sessionSyncEnabled;
  bool get syncSwitching => _syncSwitching;

  // ── Soul 预览 ───────────────────────────────────────────────────────
  String _soul = '';
  bool _soulLoading = false;
  bool _soulFetchFailed = false;
  bool _soulEditable = false;

  String get soul => _soul;
  bool get soulLoading => _soulLoading;
  bool get soulFetchFailed => _soulFetchFailed;
  bool get soulEditable => _soulEditable;

  // ── 连接 ────────────────────────────────────────────────────────────
  bool get peerLinkUp {
    final peerId = _agent.sourcePeerId;
    if (peerId == null) return false;
    return PeerConnectionManager.instance.connectedPeerIds.contains(peerId);
  }

  AgentDetailStatus get status => agentDetailStatusOf(
        agent: _agent,
        hostConnected: peerLinkUp,
      );

  // ── 生命周期 ────────────────────────────────────────────────────────

  /// 订阅主机上下线与 meta 推送。两个页面各自持有控制器，各自订阅。
  void subscribe() {
    if (_subscribed) return;
    _subscribed = true;
    _connSub = PeerConnectionManager.instance.events.listen((event) {
      if (event.peerId != _agent.sourcePeerId) return;
      if (event.type == PeerConnectionEventType.connected) {
        unawaited(refreshAll());
      }
      notifyListeners();
    });
    _metaSub = PeerAgentClientService.instance.metaChanged.listen((event) {
      if (event.agentId != _agent.id && event.agentId != _agent.remoteAgentId) {
        return;
      }
      switch (event.kind) {
        case PeerAgentMetaKind.models:
          if (_modelSwitching || _optionSwitching) return;
          unawaited(showCachedModels());
        case PeerAgentMetaKind.modes:
          if (_modeSwitching) return;
          unawaited(showCachedModes());
        case PeerAgentMetaKind.soul:
          unawaited(applyPushedSoul());
        case PeerAgentMetaKind.clientSessions:
          if (_syncSwitching) return;
          unawaited(refreshSessionSync());
      }
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _metaSub?.cancel();
    super.dispose();
  }

  /// 从本机库重读 agent 行（改名、改工作区、名单同步之后）。
  Future<void> refreshAgentRow() async {
    try {
      final latest = await getIt<RemoteAgentService>().getAgentById(_agent.id);
      if (latest == null) return;
      _agent = latest;
      notifyListeners();
    } catch (_) {
      // best-effort：读不到就继续用内存里那一份。
    }
  }

  Future<void> refreshAll() async {
    await Future.wait([
      refreshModels(),
      refreshModes(),
      refreshSoul(),
      refreshSessionSync(),
    ]);
  }

  // ── 模型 ────────────────────────────────────────────────────────────

  Future<void> showCachedModels() async {
    final cached =
        await PeerAgentClientService.instance.cachedModels(_agent.id);
    if (cached == null) return;
    _models = _uniqueModels(cached.models);
    _currentModel = cached.current;
    _modelsSwitchable = cached.switchable;
    _modelOptionValues = cached.optionValues;
    _modelsIssue =
        _models.isEmpty ? AgentRuntimeIssue.unsupported : AgentRuntimeIssue.none;
    _modelsLoading = false;
    notifyListeners();
  }

  /// 先上缓存，在线再拉一次。
  Future<void> refreshModels({bool force = false}) async {
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    var cached = force
        ? null
        : await PeerAgentClientService.instance.cachedModels(_agent.id);
    if (cached != null) {
      _models = _uniqueModels(cached.models);
      _currentModel = cached.current;
      _modelsSwitchable = cached.switchable;
      _modelOptionValues = cached.optionValues;
      _modelsIssue = _models.isEmpty && !peerLinkUp
          ? AgentRuntimeIssue.peerOffline
          : (_models.isEmpty ? AgentRuntimeIssue.unsupported : AgentRuntimeIssue.none);
      _modelsLoading = peerLinkUp;
      notifyListeners();
      if (!peerLinkUp) return;
    } else {
      if (!peerLinkUp) {
        _models = const [];
        _currentModel = null;
        _modelsSwitchable = true;
        _modelOptionValues = const {};
        _modelsIssue = AgentRuntimeIssue.peerOffline;
        _modelsLoading = false;
        notifyListeners();
        return;
      }
      _modelsLoading = true;
      _modelsIssue = AgentRuntimeIssue.none;
      notifyListeners();
    }

    final outcome = await PeerAgentClientService.instance.fetchModelsResult(
      peerId: peerId,
      remoteAgentId: remoteId,
    );
    // 拉取失败（超时 / 没发出）时不覆盖缓存里已有的列表。
    if (!outcome.completed) {
      _modelsLoading = false;
      notifyListeners();
      return;
    }
    _models = _uniqueModels(outcome.list.models);
    _currentModel = outcome.list.current;
    _modelsSwitchable = outcome.list.switchable;
    _modelOptionValues = outcome.list.optionValues;
    _modelsIssue =
        _models.isEmpty ? AgentRuntimeIssue.unsupported : AgentRuntimeIssue.none;
    _modelsLoading = false;
    notifyListeners();
  }

  /// 选模型。惜宝走储物袋名单，其余走 `agent_models_set_req`。
  Future<AgentActionFailure?> selectModel(String value) async {
    if (value == _currentModel || _modelSwitching) return null;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null || !peerLinkUp) {
      return AgentActionFailure.peerOffline;
    }
    final previous = _currentModel;
    _modelSwitching = true;
    _currentModel = value;
    notifyListeners();

    final bool ok;
    final String? error;
    if (kind == AgentDetailKind.she) {
      ok = await PeerAgentClientService.instance.setSheModel(
        peerId: peerId,
        catalogId: value,
      );
      error = ok ? null : 'failed';
    } else {
      final result = await PeerAgentClientService.instance.setModelResult(
        peerId: peerId,
        remoteAgentId: remoteId,
        model: value,
      );
      ok = result.ok;
      error = result.error;
    }

    _modelSwitching = false;
    if (ok) {
      if (error == 'not_switchable') _modelsSwitchable = false;
      notifyListeners();
      await refreshModels(force: true);
      return null;
    }
    _currentModel = previous;
    if (error == 'not_switchable') _modelsSwitchable = false;
    notifyListeners();
    return error == 'not_switchable'
        ? AgentActionFailure.notSwitchable
        : AgentActionFailure.failed;
  }

  /// 改模型参数（Fast 等）。
  Future<AgentActionFailure?> setModelOption(String option, String value) async {
    if (_optionSwitching || !_modelsSwitchable || !peerLinkUp) {
      return AgentActionFailure.peerOffline;
    }
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return AgentActionFailure.peerOffline;
    final current = PeerModelsList(
      models: _models,
      current: _currentModel,
      optionValues: _modelOptionValues,
    ).effectiveOption(option);
    if (value == current) return null;
    final previous = Map<String, String>.from(_modelOptionValues);
    _optionSwitching = true;
    _modelOptionValues = {..._modelOptionValues, option: value};
    notifyListeners();

    final result = await PeerAgentClientService.instance.setModelOptionResult(
      peerId: peerId,
      remoteAgentId: remoteId,
      option: option,
      value: value,
    );
    _optionSwitching = false;
    if (result.ok) {
      notifyListeners();
      return null;
    }
    _modelOptionValues = previous;
    notifyListeners();
    return result.error == 'not_switchable'
        ? AgentActionFailure.notSwitchable
        : AgentActionFailure.failed;
  }

  /// 惜宝：往储物袋名单里加一条并选中（密钥留主机）。
  Future<AgentActionFailure?> addSheModel({
    required String displayName,
    required String model,
    required String baseUrl,
    required String apiKey,
  }) async {
    final peerId = _agent.sourcePeerId;
    if (peerId == null || !peerLinkUp) return AgentActionFailure.peerOffline;
    final ok = await PeerAgentClientService.instance.putSheCatalog(
      peerId: peerId,
      displayName: displayName,
      model: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
      select: true,
    );
    if (!ok) return AgentActionFailure.failed;
    await refreshModels(force: true);
    return null;
  }

  // ── 模式 ────────────────────────────────────────────────────────────

  Future<void> showCachedModes() async {
    final cached =
        await PeerAgentClientService.instance.cachedModes(_agent.id);
    if (cached == null) return;
    _modes = _uniqueModes(cached.modes);
    _currentMode = cached.current;
    _modesIssue =
        _modes.isEmpty ? AgentRuntimeIssue.unsupported : AgentRuntimeIssue.none;
    _modesLoading = false;
    notifyListeners();
  }

  Future<void> refreshModes({bool force = false}) async {
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    final catalog = catalogModesList(_agent.metadata['engine'] as String?);
    var cached = force
        ? null
        : await PeerAgentClientService.instance.cachedModes(_agent.id);
    if (cached != null && cached.modes.isNotEmpty) {
      _modes = _uniqueModes(cached.modes);
      _currentMode = cached.current;
      _modesIssue = AgentRuntimeIssue.none;
      _modesLoading = peerLinkUp;
      notifyListeners();
      if (!peerLinkUp) return;
    } else if (!peerLinkUp) {
      _modes = _uniqueModes(catalog.modes);
      _currentMode = catalog.current;
      _modesIssue = catalog.modes.isEmpty
          ? AgentRuntimeIssue.peerOffline
          : AgentRuntimeIssue.none;
      _modesLoading = false;
      notifyListeners();
      return;
    } else {
      _modesLoading = true;
      _modesIssue = AgentRuntimeIssue.none;
      if (catalog.modes.isNotEmpty) {
        _modes = _uniqueModes(catalog.modes);
        _currentMode = catalog.current;
      }
      notifyListeners();
    }

    final outcome = await PeerAgentClientService.instance.fetchModesResult(
      peerId: peerId,
      remoteAgentId: remoteId,
    );
    if (!outcome.completed) {
      _modesLoading = false;
      notifyListeners();
      return;
    }
    final live = outcome.list.modes.isNotEmpty ? outcome.list : catalog;
    _modes = _uniqueModes(live.modes);
    _currentMode = live.current;
    _modesIssue =
        _modes.isEmpty ? AgentRuntimeIssue.unsupported : AgentRuntimeIssue.none;
    _modesLoading = false;
    notifyListeners();
  }

  Future<AgentActionFailure?> selectMode(String value) async {
    if (value == _currentMode || _modeSwitching) return null;
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null || !peerLinkUp) {
      return AgentActionFailure.peerOffline;
    }
    final previous = _currentMode;
    _modeSwitching = true;
    _currentMode = value;
    notifyListeners();
    final ok = await PeerAgentClientService.instance.setMode(
      peerId: peerId,
      remoteAgentId: remoteId,
      mode: value,
    );
    _modeSwitching = false;
    if (ok) {
      notifyListeners();
      return null;
    }
    _currentMode = previous;
    notifyListeners();
    return AgentActionFailure.failed;
  }

  // ── 客户端会话同步 ───────────────────────────────────────────────────

  Future<void> refreshSessionSync() async {
    final enabled = await isClientSessionSyncEnabled(
      _agent.id,
      remoteAgentId: _agent.remoteAgentId,
    );
    _sessionSyncEnabled = enabled;
    notifyListeners();
  }

  Future<AgentActionFailure?> setSessionSync(bool enabled) async {
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    if (peerId == null || remoteId == null) return AgentActionFailure.failed;
    final previous = _sessionSyncEnabled;
    _sessionSyncEnabled = enabled;
    _syncSwitching = true;
    notifyListeners();
    final ok = await PeerAgentClientService.instance.setClientSessionsSync(
      peerId: peerId,
      remoteAgentId: remoteId,
      localAgentId: _agent.id,
      enabled: enabled,
    );
    _syncSwitching = false;
    if (ok) {
      notifyListeners();
      return null;
    }
    _sessionSyncEnabled = previous;
    notifyListeners();
    return AgentActionFailure.failed;
  }

  // ── Soul ────────────────────────────────────────────────────────────

  Future<void> refreshSoul() async {
    final peerId = _agent.sourcePeerId;
    final remoteId = _agent.remoteAgentId;
    final cached =
        await PeerAgentClientService.instance.cachedSoul(_agent.id);
    final connected = peerLinkUp && remoteId != null && peerId != null;
    if (cached != null) {
      _soul = cached.soul;
      _soulEditable = connected && cached.editable;
      _soulFetchFailed = false;
      _soulLoading = false;
      notifyListeners();
    } else {
      _soulLoading = true;
      _soulFetchFailed = false;
      notifyListeners();
    }
    if (!connected) {
      if (cached == null) {
        _soul = '';
        _soulEditable = false;
        _soulLoading = false;
        _soulFetchFailed = false;
        notifyListeners();
      } else {
        _soulEditable = false;
        notifyListeners();
      }
      return;
    }
    try {
      final info = await PeerAgentClientService.instance.fetchSoulInfo(
        peerId: peerId,
        remoteAgentId: remoteId,
      );
      if (info != null && info.isOk) {
        _soul = info.soul;
        _soulEditable = info.editable;
        _soulFetchFailed = false;
        _soulLoading = false;
        notifyListeners();
        return;
      }
      _soulLoading = false;
      if (cached == null) {
        _soulFetchFailed = true;
        _soulEditable = false;
      }
      notifyListeners();
    } catch (_) {
      _soulLoading = false;
      if (cached == null) _soulFetchFailed = true;
      notifyListeners();
    }
  }

  /// 其它设备改了 Soul 时由 `metaChanged` 推过来。
  Future<void> applyPushedSoul() async {
    final cached =
        await PeerAgentClientService.instance.cachedSoul(_agent.id);
    if (cached == null || !cached.isOk) return;
    _soul = cached.soul;
    _soulEditable = peerLinkUp && cached.editable;
    notifyListeners();
  }

  // ── 工具 ────────────────────────────────────────────────────────────

  /// DropdownButton 要求值唯一，同一 value 只保留第一条。
  static List<T> _uniqueBy<T>(Iterable<T> items, String Function(T) keyOf) {
    final seen = <String>{};
    final out = <T>[];
    for (final item in items) {
      final key = keyOf(item);
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(item);
    }
    return out;
  }

  static List<PeerAgentModel> _uniqueModels(Iterable<PeerAgentModel> items) =>
      _uniqueBy(items, (m) => m.value);

  static List<PeerAgentMode> _uniqueModes(Iterable<PeerAgentMode> items) =>
      _uniqueBy(items, (m) => m.value);
}
