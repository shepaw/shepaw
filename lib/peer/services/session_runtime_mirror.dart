import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

/// 主机 `session.state` 快照在 App 侧的镜像。
///
/// **App 不再自己判断回合是否结束**：气泡的「正在输出」、发送闸门、排队条
/// 全部是这份状态的函数。主机是唯一 writer，App 只按 `revision` 应用快照。
/// 帧丢了也没关系：live `hub_event` 与 `events_sync_resp` / `session_snapshot_resp`
/// 都是全量快照，重放天然幂等。

class QueuedItem {
  final String requestId;
  final int position;
  final String preview;

  /// 完整正文。队列编辑面板要用它，`preview` 是截断的，拿来编辑会丢字。
  final String content;

  const QueuedItem({
    required this.requestId,
    required this.position,
    required this.preview,
    this.content = '',
  });

  factory QueuedItem.fromJson(Map<dynamic, dynamic> json) {
    final preview = (json['preview'] as String?) ?? '';
    return QueuedItem(
      requestId: (json['request_id'] as String?) ?? '',
      position: (json['position'] as num?)?.toInt() ?? 0,
      preview: preview,
      content: (json['content'] as String?) ?? preview,
    );
  }
}

class SessionTerminal {
  final String turnId;
  final String reason;
  final int atMs;
  final int revision;

  const SessionTerminal({
    required this.turnId,
    required this.reason,
    required this.atMs,
    required this.revision,
  });

  factory SessionTerminal.fromJson(Map<dynamic, dynamic> json) =>
      SessionTerminal(
        turnId: (json['turn_id'] as String?) ?? '',
        reason: (json['reason'] as String?) ?? '',
        atMs: (json['at_ms'] as num?)?.toInt() ?? 0,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );
}

class SessionState {
  final String sessionKey;
  final int revision;
  final int generation;
  final bool isRunning;
  final String turnId;
  final String peerId;
  final String phase;

  /// 「正文看起来写完了」只是 UI hint。它为真时回合**仍然在跑**。
  final bool answerSettled;
  final int startedAtMs;
  final int lastProgressAtMs;

  /// 主机生成这份快照的墙钟时间。换 hub 后 revision 会从 1 重新计数，
  /// 用时间水位挡住 events_sync 回放里的旧 session.state 复活已结束回合。
  final int atMs;

  /// 产生这份快照的主机实例 id。换 hub 后 revision 从 1 重新计数、墙钟也
  /// 可能回拨，只有身份能可靠区分两代 revision 空间。
  final String hubId;

  /// 主机进程代次（每次重启换号）。`hub_id` / 配对 peer 在主机重启时不变，
  /// 但 flow 的 per-key revision 会回到 1；epoch 把同一个身份下的两代
  /// revision 空间分开，水位不能跨代比较（A9-1）。老主机没有这个字段时为空。
  final String epoch;
  final SessionTerminal? lastTerminal;
  final List<QueuedItem> queue;

  /// 主机标的 `flow: true`。节点会话的 `revision` 是**按 key 独立**的计数器
  /// （主机重启后从 1 重新开始），不能和 hub 运行时会话共用一套「只认更大
  /// revision」的比较，否则重连 / 重启后低 revision 的 flow 帧会被永久拒绝。
  final bool isFlow;

  const SessionState({
    required this.sessionKey,
    this.revision = 0,
    this.generation = 0,
    this.isRunning = false,
    this.turnId = '',
    this.peerId = '',
    this.phase = '',
    this.answerSettled = false,
    this.startedAtMs = 0,
    this.lastProgressAtMs = 0,
    this.atMs = 0,
    this.hubId = '',
    this.epoch = '',
    this.lastTerminal,
    this.queue = const <QueuedItem>[],
    this.isFlow = false,
  });

  factory SessionState.empty(String sessionKey) =>
      SessionState(sessionKey: sessionKey);

  factory SessionState.fromSnapshot(Map<dynamic, dynamic> json) {
    final rawTerminal = json['last_terminal'];
    final rawQueue = json['queue'];
    return SessionState(
      sessionKey: (json['session_key'] as String?) ?? '',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      isRunning: json['state'] == 'running',
      turnId: (json['turn_id'] as String?) ?? '',
      peerId: (json['peer_id'] as String?) ?? '',
      phase: (json['phase'] as String?) ?? '',
      answerSettled: json['answer_settled'] == true,
      startedAtMs: (json['started_at_ms'] as num?)?.toInt() ?? 0,
      lastProgressAtMs: (json['last_progress_at_ms'] as num?)?.toInt() ?? 0,
      atMs: (json['at'] as num?)?.toInt() ?? 0,
      hubId: (json['hub_id'] as String?) ?? '',
      epoch: _parseEpoch(json['epoch']),
      lastTerminal:
          rawTerminal is Map ? SessionTerminal.fromJson(rawTerminal) : null,
      queue: rawQueue is List
          ? rawQueue
              .whereType<Map>()
              .map((item) => QueuedItem.fromJson(item))
              .toList(growable: false)
          : const <QueuedItem>[],
      isFlow: json['flow'] == true,
    );
  }

  /// 保留 key / revision 等身份信息，只把回合收成 idle。
  /// 重连保留的 running 条目超时收尾用；不伪造 revision。
  SessionState asIdle() => SessionState(
        sessionKey: sessionKey,
        revision: revision,
        generation: generation,
        peerId: peerId,
        atMs: atMs,
        hubId: hubId,
        epoch: epoch,
      );

  /// 气泡的「正在输出」态。只有主机说 idle 才会变成 null。
  String? get streamingMessageId =>
      isRunning && turnId.isNotEmpty ? turnId : null;

  /// 发送闸门。旧代码用本地静默秒数猜，这里只镜像主机。
  bool get isProcessing => isRunning;

  int get hostQueuedCount => queue.length;

  int? queuedPosition(String requestId) {
    for (final item in queue) {
      if (item.requestId == requestId) return item.position;
    }
    return null;
  }

  /// 一条刚发出的消息落在哪：`running` / `queued` / `unknown`。
  /// 供乐观气泡在 `session_ack` 到达前显示，绝不用来判回合终态。
  String dispositionFor(String requestId) {
    if (isRunning && turnId == requestId) return 'running';
    if (queuedPosition(requestId) != null) return 'queued';
    return 'unknown';
  }
}

/// 主机给 epoch 的形态不固定（数字 / 字符串都可能），统一成字符串比较。
String _parseEpoch(Object? raw) {
  if (raw == null) return '';
  final text = raw.toString().trim();
  return text.isEmpty ? '' : text;
}

/// 两边都是数字时才能判「旧进程」；随机 id / 启动串一律不猜大小。
bool _isOlderEpoch(String incoming, String current) {
  final a = int.tryParse(incoming);
  final b = int.tryParse(current);
  return a != null && b != null && a < b;
}

// 流帧的归属由 PeerAgentClientService 的 _pending[request_id] 判定，不在
// mirror 里判「迟到」：状态事件是异步的、主机 epoch 又不持久化（重启从 1
// 重新发号），任何基于 generation / isRunning 的绝对比较都会误丢本轮 chunk。

/// 纯 reducer：只接受更大 revision 的快照，乱序 / 重放天然幂等。
/// 返回同一个对象表示「没变化」，调用方据此决定要不要通知 UI。
SessionState reduceSessionState(SessionState current, SessionState incoming) {
  if (incoming.sessionKey != current.sessionKey) return current;
  // flow 帧的 revision 是 per-key 计数器，重连 / 主机重启后可能比本地小；
  // 直接落地（见 [SessionRuntimeMirror.apply]）。
  if (incoming.isFlow) return incoming;
  if (incoming.revision <= current.revision) return current;
  return incoming;
}

/// 每个会话一个 [ValueNotifier]，UI 直接订阅自己那段会话。
/// 这样排队条等外层控件不必依赖整页 `setState`，
/// `OuterStructuralSnapshot` 门控挡不住它。
class SessionRuntimeMirror {
  SessionRuntimeMirror({
    this.flowRetention = const Duration(seconds: 30),
  });

  /// 重连保留 / 最近一次 flow 活动之后，running flow 条目最多再撑多久。
  ///
  /// 节点会话不在 `session_snapshot_resp` 里，断线期间丢掉的 idle 帧没有
  /// 别的路径补回来。保留 running（停止按钮要靠 turnId）必须有边界：
  /// 最后一次活动之后 [flowRetention] 内没有新的 flow 活动（chunk / running
  /// 帧）就按 idle 收尾，否则会永远显示正在输出、停止按钮发无效取消。
  /// 活动只把窗口刷新回完整时长，绝不取消这个上限（A7-4）。
  final Duration flowRetention;

  final Map<String, ValueNotifier<SessionState>> _notifiers = {};

  /// running flow key → 最后一次真实活动的墙钟（ms）。
  ///
  /// 以前每片 chunk / metadata 都 `_armFlowRetention` 重建一个 Timer，一个
  /// 长回合几百片就是几百个 Timer 分配。现在只记时间戳，由**一个**周期
  /// Timer 统一检查（A9-10）。
  final Map<String, int> _flowLastActivity = {};

  /// 所有 running flow key 共用的检查 Timer；没有 running 条目时不装。
  Timer? _flowSweepTimer;

  /// Test seam：实际分配过几个 retention Timer。大量 chunk 不该让它增长。
  @visibleForTesting
  int debugRetentionTimerAllocations = 0;

  /// 任何会话状态跃迁都会通知。订阅方用 [lastChangedKey] + [peek] 判断
  /// 这次变化是不是自己那段会话，不必为每个会话单独管理订阅生命周期。
  /// 用 ValueNotifier 而不是 ChangeNotifier：notifyListeners 是 protected，
  /// 不能从本类外部调用。
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// 最近一次被接受的状态跃迁属于哪个会话。
  String? lastChangedKey;

  /// 当前认定的主机实例。换 hub（id 变化）时重置本地 revision 空间并强制
  /// 接受新 hub 的任何 revision；旧 hub 的历史回放按 id 不匹配拒绝。
  /// 墙钟不可靠（换 hub / NTP 回拨），不再用它做水位。
  String? _hubId;

  /// 当前主机是哪个配对设备（全量对账回执的 peerId）。主机 `session.state`
  /// 裸帧根本不带 `hub_id`，换主机后只有连接身份能挡住旧主机的迟到回放。
  String? _hubPeerId;

  /// 当前主机进程代次（A9-1）。换代后 per-key revision 从 1 重来，旧水位
  /// 与旧回合 id 一律失效。空表示主机还没报过 epoch（老版本主机）。
  String? _epoch;

  /// 每个 flow key 的权威状态水位：该身份下见过的最高 revision、最近是否收尾、
  /// 以及收尾的是哪个回合。
  ///
  /// flow 帧的 revision 是 per-key 计数器，不能拿它和别的 key / hub 全局空间
  /// 做严格比较；但同一个 key 上「先 running(rev2)、再 idle(rev3)、又来迟到
  /// running(rev2)」必须拒绝，否则停止按钮会对已经死掉的回合发取消（A8-2）。
  /// 换 hub / 换 epoch（revision 从 1 重来）时整张表清空，身份不同的帧互不挡路；
  /// 同一身份下新 turnId 的 running-after-idle 也不算旧回合的重放（A9-1）。
  final Map<String,
          ({int revision, bool terminal, String identity, String turnId})>
      _flowWatermarks = {};

  /// 换 hub 前还在 running 的 flow turn id。旧主机重放的 running 帧既没有
  /// `hub_id`、又没有可核对的连接身份时，靠它把「已经死掉的回合」认出来。
  /// 有界，避免长会话无限增长。
  final Set<String> _retiredFlowTurns = <String>{};
  static const _retiredFlowTurnCap = 512;

  void _rememberRetiredFlowTurn(String turnId) {
    if (turnId.isEmpty) return;
    _retiredFlowTurns.remove(turnId);
    _retiredFlowTurns.add(turnId);
    while (_retiredFlowTurns.length > _retiredFlowTurnCap) {
      _retiredFlowTurns.remove(_retiredFlowTurns.first);
    }
  }

  // 主机自发回合（推送 / 后台汇报 / pouch）的「哪些回合在跑」由
  // HubEventClient 的 _attached/_liveChannels/_liveBuffers 承担——它们是
  // 本机接流视图与落库路由，不是会话状态。会话状态的唯一真相源是这里
  // 的 per-session notifier；不再另立一份只写不读的 live-turn 索引。

  /// App 本地 channel id → 主机 `agent:<agentId>:<session_id>`。
  /// `psess_` 壳剥掉，本机新建的 `dm_` 原样带上（与
  /// `hostSessionIdForChannel` 一致），否则永远查不到主机那份状态。
  static String sessionKey({
    required String agentId,
    required String channelId,
  }) {
    const prefix = 'psess_';
    final bare = channelId.startsWith(prefix)
        ? channelId.substring(prefix.length)
        : channelId;
    return 'agent:$agentId:$bare';
  }

  ValueNotifier<SessionState> notifierFor(String sessionKey) =>
      _notifiers.putIfAbsent(
        sessionKey,
        () => ValueNotifier<SessionState>(SessionState.empty(sessionKey)),
      );

  /// 已存在的 notifier，不创建新条目。用于「精确 key 查不到就换兜底」。
  ValueNotifier<SessionState>? peek(String sessionKey) =>
      _notifiers[sessionKey];

  /// 只知道本地 channel id、不确定 agentId 时，按 session_id 后缀找。
  /// 主机 key 是 `agent:<agentId>:<sessionId>`，App 本地 agent id 有时是
  /// 另一套 id；按后缀匹配比硬拼 key 稳健。多个会话撞后缀时不猜，返回 null。
  ValueNotifier<SessionState>? notifierForChannel(String channelId) {
    const prefix = 'psess_';
    final bare = channelId.startsWith(prefix)
        ? channelId.substring(prefix.length)
        : channelId;
    if (bare.isEmpty) return null;
    ValueNotifier<SessionState>? found;
    for (final entry in _notifiers.entries) {
      // 主机对 pouch / 群回合用裸 channel_id 作 session_key（无冒号），
      // agent_chat 才是 `agent:<id>:<session>`。两种都要能命中。
      final matchesKey = entry.key == bare || entry.key.endsWith(':$bare');
      if (!matchesKey) {
        continue;
      }
      if (found != null) return null;
      found = entry.value;
    }
    return found;
  }

  SessionState stateFor(String sessionKey) => notifierFor(sessionKey).value;

  /// 主机队列里是否排着这条 request。session_ack 是单播直发、可能丢帧；
  /// 看门狗用 durable 的 session.state 自愈排队豁免。
  bool isRequestQueued(String requestId) {
    if (requestId.isEmpty) return false;
    for (final notifier in _notifiers.values) {
      for (final item in notifier.value.queue) {
        if (item.requestId == requestId) return true;
      }
    }
    return false;
  }

  /// 主机已把这条 request 出队并提成当前回合。
  ///
  /// 出队时主机只广播 `session.state`（不会再发一次 session_ack started），
  /// 客户端的 `queuedOnHost` 要等首个 chunk 才清。中间这段窗口里按停止，
  /// 必须认出它已经是 running，否则会把该停的回合当成「还在排队」跳过。
  bool isRequestRunning(String requestId) {
    if (requestId.isEmpty) return false;
    for (final notifier in _notifiers.values) {
      // 与「发送闸门」用的是同一条判定，别在这里另写一份
      // `isRunning && turnId == requestId`，否则两处语义会漂移。
      if (notifier.value.dispositionFor(requestId) == 'running') return true;
    }
    return false;
  }

  /// 应用一份主机快照。返回是否真的前移了状态。
  /// [force] 只给全量对账用：换 hub 后主机 revision 会从 1 重新计数，
  /// 低 revision 的权威快照也必须直接落地。
  /// [sourcePeerId] 是送来这帧的连接对端。裸 `session.state` 不带 `hub_id`
  /// （A7-2），换主机后只有连接身份能区分新旧两代 revision 空间。
  bool apply(
    Map<dynamic, dynamic> snapshot, {
    bool force = false,
    String? sourcePeerId,
  }) {
    final incoming = SessionState.fromSnapshot(snapshot);
    if (incoming.sessionKey.isEmpty) return false;
    final isFlow = incoming.isFlow;
    final fromPeer = sourcePeerId?.trim() ?? '';
    // A6-3/A7-2：flow 帧可以跳过 revision 比较（per-key 计数器重启会回退），
    // 但**不能**跳过 hub 身份检查。身份有三种：帧里的 hub_id、连接对端的
    // peerId（裸帧）、以及换 hub 时记下的旧 turn id。
    // 身份只由全量对账（reconcileTo）确立；还没有身份时两类帧都先接受。
    if (!force) {
      final hub = incoming.hubId;
      if (hub.isNotEmpty && _hubId != null && hub != _hubId) {
        return false;
      }
      if (fromPeer.isNotEmpty && _hubPeerId != null && fromPeer != _hubPeerId) {
        return false;
      }
      // A9-1：epoch 是单调计数时，旧进程的迟到帧一律丢；字符串形态（无法
      // 排序）就交给下面的水位身份比较，只保证新进程不被旧水位挡住。
      if (incoming.epoch.isNotEmpty &&
          _epoch != null &&
          _isOlderEpoch(incoming.epoch, _epoch!)) {
        return false;
      }
      if (_isStaleFlowReplay(incoming, fromPeer)) return false;
      if (_isStaleRunningFlowFrame(incoming, fromPeer)) return false;
    }
    final notifier = notifierFor(incoming.sessionKey);
    final current = notifier.value;
    final next =
        (force || isFlow) ? incoming : reduceSessionState(current, incoming);
    if (identical(next, current)) return false;
    notifier.value = next;
    if (isFlow) _rememberFlowFrame(next, fromPeer);
    lastChangedKey = incoming.sessionKey;
    changes.value++;
    // A7-2：任何被接受的 running flow 帧都必须带 retention 计时器，否则丢了
    // idle 就永远 running。A7-4：只有权威的 idle/终态帧才真正取消计时器。
    if (isFlow && next.isRunning) {
      _armFlowRetention(incoming.sessionKey);
    } else {
      _cancelFlowRetention(incoming.sessionKey);
    }
    return true;
  }

  /// 「没有身份、revision 明显落后」的 running flow 帧只在当前 key 没有更权威
  /// 状态时才接受。主机裸帧不带 hub_id，旧主机回放的 running 会把已经收尾的
  /// 回合复活成 running；带 hub_id / 连接身份的帧在上面已经校验过。
  bool _isStaleFlowReplay(SessionState incoming, String fromPeer) {
    if (!incoming.isFlow || !incoming.isRunning) return false;
    // A9-1：换代后的新进程不能被上一代留下的黑名单误拒。
    if (incoming.epoch.isNotEmpty &&
        _epoch != null &&
        incoming.epoch != _epoch) {
      return false;
    }
    // A10-6：已退休的 turnId 无条件拒绝，peer / hub 身份只能用来判断
    // 「新 turnId」的帧。raw 帧一律带 sourcePeerId，身份检查放在这里之前会
    // 让整张黑名单永远不可达：同一主机重启（peerId 不变）时旧进程的 running
    // 重放会把死回合复活。
    final turnId = incoming.turnId;
    if (turnId.isNotEmpty && _retiredFlowTurns.contains(turnId)) return true;
    if (incoming.hubId.isNotEmpty) return false;
    if (fromPeer.isNotEmpty && _hubPeerId != null) return false;
    final current = _notifiers[incoming.sessionKey]?.value;
    if (current == null || current.sessionKey.isEmpty) return false;
    // 当前 key 已有同 hub、revision 更大的收尾状态：这一帧只可能是重放。
    // 严格大于，别把「同 hub 但低 revision」的真实 flow 帧误拒。
    if (current.hubId.isNotEmpty &&
        current.hubId == _hubId &&
        !current.isRunning &&
        current.revision > incoming.revision) {
      return true;
    }
    return false;
  }

  /// flow 帧的身份：优先帧里的 hub_id，其次连接对端，都没有就是「无身份」；
  /// 再带上主机进程代次 epoch。只有同一身份 + 同一代次下的水位才有可比性
  /// （换 hub / 换 peer / 主机重启后 revision 都从 1 重来，A9-1）。
  String _flowFrameIdentity(SessionState state, String fromPeer) {
    final base = state.hubId.isNotEmpty
        ? 'hub:${state.hubId}'
        : (fromPeer.isNotEmpty ? 'peer:$fromPeer' : '');
    if (state.epoch.isEmpty) return base;
    return '$base|epoch:${state.epoch}';
  }

  /// 记下一份已接受的 flow 快照作为该 key 的权威水位。
  /// 只对同身份取最大 revision；idle / 终态把水位标成「已收尾」。
  /// 终态帧常常不带 turn_id，要沿用上一个 running 帧的 turnId，否则「旧回合
  /// 的迟到 running」会被误认成新回合（A8-2 / A9-1）。
  void _rememberFlowFrame(SessionState accepted, String fromPeer) {
    final key = accepted.sessionKey;
    final identity = _flowFrameIdentity(accepted, fromPeer);
    final previous = _flowWatermarks[key];
    final sameIdentity = previous != null && previous.identity == identity;
    final revision = sameIdentity && previous.revision > accepted.revision
        ? previous.revision
        : accepted.revision;
    final turnId = accepted.turnId.isNotEmpty
        ? accepted.turnId
        : (sameIdentity ? previous.turnId : '');
    _flowWatermarks[key] = (
      revision: revision,
      terminal: !accepted.isRunning,
      identity: identity,
      turnId: turnId,
    );
  }

  /// A8-2：flow 帧跳过 hub 全局 revision / 严格比较，但同一 key、同一身份下，
  /// 比权威水位更旧的 running 帧不能被接受 —— 主机临时重试先发 running 再发
  /// idle，迟到的 running 会把已收尾的回合复活成「正在输出」。
  /// A9-1：身份里带 epoch，主机重启后 rev1 属于全新的一代，不能被旧 rev10
  /// 的水位拒绝；老主机没有 epoch 时，收尾之后**换了 turnId** 的 running 帧
  /// 是另一个回合，同样不是同回合的陈旧重放。未收尾时的低 revision 重放仍拒。
  bool _isStaleRunningFlowFrame(SessionState incoming, String fromPeer) {
    if (!incoming.isFlow || !incoming.isRunning) return false;
    final mark = _flowWatermarks[incoming.sessionKey];
    if (mark == null) return false;
    if (_flowFrameIdentity(incoming, fromPeer) != mark.identity) return false;
    // 收尾之后来了新回合：只有同 turnId 的低 revision running 才是重放。
    if (mark.terminal &&
        incoming.turnId.isNotEmpty &&
        mark.turnId.isNotEmpty &&
        incoming.turnId != mark.turnId) {
      return false;
    }
    if (incoming.revision > mark.revision) return false;
    // 终态之后（含同 revision）的 running 都只可能是重放；未收尾时只挡更旧的。
    return mark.terminal || incoming.revision < mark.revision;
  }

  /// 该 flow 会话还有真实活动（流式 chunk / metadata）：把保留窗口**刷新**回
  /// 完整的 [flowRetention]，不是取消。
  ///
  /// [notifierKey] 是调用方已经算好的权威 key（`agent:<id>:flow_...`）。带它
  /// 进来就不必每片 chunk 全表扫一遍 notifier 后缀（A9-10）。
  void noteFlowActivity(String sessionKey, {String? notifierKey}) {
    var matched = false;
    for (final key in <String>{
      if (notifierKey != null && notifierKey.isNotEmpty) notifierKey,
      if (sessionKey.isNotEmpty) sessionKey,
    }) {
      final notifier = _notifiers[key];
      if (notifier != null && notifier.value.isRunning) {
        _armFlowRetention(key);
        matched = true;
      }
    }
    if (matched) return;
    // 裸 `flow_<tag>_<node>` 帧（metadata 常常不带 agent 前缀）也要能刷新
    // `agent:<id>:flow_<tag>_<node>` 那份权威状态（A8-5）。命中不唯一时不猜。
    if (sessionKey.isEmpty) return;
    final matchedBySuffix = notifierForChannel(sessionKey);
    if (matchedBySuffix == null || !matchedBySuffix.value.isRunning) return;
    _armFlowRetention(matchedBySuffix.value.sessionKey);
  }

  /// 真实活动 / 新 running 帧都走这里重置窗口；只有权威的 idle/终态帧才走
  /// [_cancelFlowRetention] 真正取消。这里只写时间戳，不分配 Timer。
  void _armFlowRetention(String sessionKey) {
    _flowLastActivity[sessionKey] = DateTime.now().millisecondsSinceEpoch;
    _ensureFlowSweep();
  }

  void _cancelFlowRetention(String sessionKey) {
    _flowLastActivity.remove(sessionKey);
    if (_flowLastActivity.isEmpty) _cancelFlowSweep();
  }

  void _cancelFlowSweep() {
    _flowSweepTimer?.cancel();
    _flowSweepTimer = null;
  }

  /// 所有 running flow 条目共用一个周期 Timer：chunk 再密也只是多写一次
  /// 时间戳，不再反复分配 Timer（A9-10）。
  void _ensureFlowSweep() {
    if (_flowSweepTimer != null) return;
    final tickMs = flowRetention.inMilliseconds ~/ 4;
    final interval = Duration(
      milliseconds: tickMs < 5 ? 5 : (tickMs > 1000 ? 1000 : tickMs),
    );
    debugRetentionTimerAllocations++;
    _flowSweepTimer = Timer.periodic(interval, (_) => _onFlowSweep());
  }

  void _onFlowSweep() {
    if (_flowLastActivity.isEmpty) {
      _cancelFlowSweep();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final retentionMs = flowRetention.inMilliseconds;
    for (final entry in _flowLastActivity.entries.toList()) {
      if (now - entry.value < retentionMs) continue;
      final sessionKey = entry.key;
      _flowLastActivity.remove(sessionKey);
      final notifier = _notifiers[sessionKey];
      if (notifier == null || !notifier.value.isRunning) continue;
      // 到期仍没有任何 flow 活动：按 idle 收尾，回落到 revision 基线重来。
      notifier.value = notifier.value.asIdle();
      // 这是 App 自己的兜底收尾，不是主机宣告的权威终态：清掉水位，别拿它
      // 挡住主机重启后从 1 重新计数的新回合（A4-1 / A8-2）。
      _flowWatermarks.remove(sessionKey);
      lastChangedKey = sessionKey;
      changes.value++;
    }
    if (_flowLastActivity.isEmpty) _cancelFlowSweep();
  }

  /// 重连保留：先留着 running（停止按钮要靠 turnId），但设一个上限。
  void _retainRunningFlow(String sessionKey) {
    if (_flowLastActivity.containsKey(sessionKey)) return;
    _armFlowRetention(sessionKey);
  }

  /// `session_snapshot_resp` / `events_sync_resp` 的批量对账。
  /// 顺序无所谓：reducer 只认 revision。
  int applyAll(Iterable<dynamic> snapshots, {String? sourcePeerId}) {
    var applied = 0;
    for (final snapshot in snapshots) {
      if (snapshot is Map && apply(snapshot, sourcePeerId: sourcePeerId)) {
        applied++;
      }
    }
    return applied;
  }

  /// 这个 key 是不是节点会话（裸 `flow_...` 或 `agent:<id>:flow_...`）。
  ///
  /// `session_snapshot_resp` 只含 hub 运行时自己的会话，节点会话的裸
  /// `flow_` key 不在里面 —— 不能因为「快照没提」就把正在跑的回合清掉。
  static bool _isFlowSessionKey(String sessionKey) {
    final bare = sessionKey.startsWith('agent:')
        ? sessionKey.substring(sessionKey.lastIndexOf(':') + 1)
        : sessionKey;
    return bare.startsWith('flow_');
  }

  /// 启动 / 重连全量对账：快照里的会话强制落地（新 hub 的 revision 可能比
  /// 本地低），没提到的会话重置为空。[hubId] 是响应顶层的主机身份，空快照
  /// 时也要靠它识别换 hub；[epoch] 是主机进程代次，重启后它变化但 hub_id
  /// 不变，必须据此清掉 per-key 水位（A9-1）；[sourcePeerId] 是回执来自哪个
  /// 连接，裸 `session.state` 帧不带 hub_id，之后的身份校验要靠它。
  void reconcileTo(
    Iterable<dynamic> snapshots, {
    String? hubId,
    String? sourcePeerId,
    String? epoch,
  }) {
    final seen = <String>{};
    final parsed = <Map<dynamic, dynamic>>[];
    String? effectiveHub = (hubId == null || hubId.isEmpty) ? null : hubId;
    String? effectiveEpoch =
        _parseEpoch(epoch).isEmpty ? null : _parseEpoch(epoch);
    for (final snapshot in snapshots) {
      if (snapshot is! Map) continue;
      final state = SessionState.fromSnapshot(snapshot);
      if (state.sessionKey.isEmpty) continue;
      if (effectiveHub == null && state.hubId.isNotEmpty) {
        effectiveHub = state.hubId;
      }
      if (effectiveEpoch == null && state.epoch.isNotEmpty) {
        effectiveEpoch = state.epoch;
      }
      seen.add(state.sessionKey);
      parsed.add(snapshot);
    }
    // A9-1：主机进程重启，hub_id / peer 都没变，但 per-key revision 回到 1。
    // 换代时旧水位、旧回合黑名单、保留窗口全部失效，否则新回合的低 revision
    // running 帧会被旧 rev10 的终态水位永久拒掉。
    if (effectiveEpoch != null &&
        effectiveEpoch.isNotEmpty &&
        effectiveEpoch != _epoch) {
      _flowWatermarks.clear();
      _retiredFlowTurns.clear();
      _flowLastActivity.clear();
      _cancelFlowSweep();
      // 旧进程还在跑的 flow 回合已经死了：把 notifier 复位，否则停止按钮会
      // 一直指向一个永远不会有 idle 帧的 turnId。快照里提到的 key 随后会被
      // force 落地，不在这里丢新状态。
      for (final entry in _notifiers.entries) {
        if (!_isFlowSessionKey(entry.key)) continue;
        final before = entry.value.value;
        if (!before.isRunning && before.queue.isEmpty) continue;
        entry.value.value = SessionState.empty(entry.key);
        lastChangedKey = entry.key;
        changes.value++;
      }
      _epoch = effectiveEpoch;
    }
    if (effectiveHub != null &&
        effectiveHub.isNotEmpty &&
        effectiveHub != _hubId) {
      // 换 hub：清空本地 revision 空间，让新 hub 的任何 revision 都能落地。
      // 之后旧 hub 的历史回放按 hub_id 不匹配被 apply 拒绝。
      _flowLastActivity.clear();
      _cancelFlowSweep();
      // 新 hub 的 per-key revision 从 1 重来，旧水位一律失效。
      _flowWatermarks.clear();
      for (final entry in _notifiers.entries) {
        // 旧 hub 这些回合已经死了：记下 turn id，之后无身份的旧 running 回放
        // 一律拒绝，不能让它们复活成 running（A7-2）。
        final before = entry.value.value;
        if (before.isRunning &&
            _isFlowSessionKey(entry.key) &&
            before.turnId.isNotEmpty) {
          _rememberRetiredFlowTurn(before.turnId);
        }
        entry.value.value = SessionState.empty(entry.key);
        // 复位本身也是一次状态跃迁：必须通知监听者，否则 ChatController 的
        // running→idle 清理与整页 _notify() 不会执行，气泡会一直挂着。
        lastChangedKey = entry.key;
        changes.value++;
      }
      _hubId = effectiveHub;
    } else if (effectiveHub != null && effectiveHub.isNotEmpty) {
      _hubId = effectiveHub;
    }
    final peer = sourcePeerId?.trim() ?? '';
    if (peer.isNotEmpty) _hubPeerId = peer;
    for (final snapshot in parsed) {
      apply(snapshot, force: true);
    }
    for (final entry in _notifiers.entries) {
      if (seen.contains(entry.key)) continue;
      final current = entry.value.value;
      if (!current.isRunning && current.queue.isEmpty) continue;
      // 节点会话不归 hub 运行时会话表管，重连快照里天然缺席。正在跑的
      // flow_ 条目先保留原状态（尤其是 turnId，停止按钮要靠它），但保留
      // 必须有边界：断线期间丢掉的 idle 帧不会再有别的路径补回来。给一个
      // flowRetention 的窗口；期间有 chunk 活动就取消，否则到期按 idle 收尾。
      if (current.isRunning && _isFlowSessionKey(entry.key)) {
        _retainRunningFlow(entry.key);
        continue;
      }
      // 重置到 revision 0：既不伪造递增，也让新 hub 的任何真实快照收敛。
      _cancelFlowRetention(entry.key);
      entry.value.value = SessionState.empty(entry.key);
      lastChangedKey = entry.key;
      changes.value++;
    }
  }

  void dispose() {
    _flowLastActivity.clear();
    _cancelFlowSweep();
    _flowWatermarks.clear();
    _retiredFlowTurns.clear();
    _epoch = null;
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    changes.dispose();
  }
}
