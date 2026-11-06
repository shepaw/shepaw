import 'dart:async';

import 'package:flutter/foundation.dart';

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

  /// 重连时保留下来的 running flow 条目最多再撑多久。
  ///
  /// 节点会话不在 `session_snapshot_resp` 里，断线期间丢掉的 idle 帧没有
  /// 别的路径补回来。保留 running（停止按钮要靠 turnId）必须有边界：
  /// 在保留期内没有新的 flow 活动（chunk）就按 idle 收尾，否则会永远显示
  /// 正在输出、停止按钮发无效取消。
  final Duration flowRetention;

  final Map<String, ValueNotifier<SessionState>> _notifiers = {};

  /// 重连保留的 running flow key → 到期计时器。
  final Map<String, Timer> _flowRetentionTimers = {};

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
  bool apply(Map<dynamic, dynamic> snapshot, {bool force = false}) {
    final incoming = SessionState.fromSnapshot(snapshot);
    if (incoming.sessionKey.isEmpty) return false;
    final isFlow = incoming.isFlow;
    // A6-3：flow 帧可以跳过 revision 比较（per-key 计数器重启会回退），
    // 但**不能**跳过 hub 身份检查：切主机后旧 hub 迟到的 flow 帧同样会把
    // 旧回合复活成 running。只有「同 hub 但低 revision」才绕过 reducer。
    // 身份只由全量对账（reconcileTo）确立；还没有身份时两类帧都先接受。
    if (!force) {
      final hub = incoming.hubId;
      if (hub.isNotEmpty && _hubId != null && hub != _hubId) {
        return false;
      }
    }
    // 任一权威帧都证明这个 key 还活着：取消重连保留的 idle 收尾计时器。
    _cancelFlowRetention(incoming.sessionKey);
    final notifier = notifierFor(incoming.sessionKey);
    final next = (force || isFlow)
        ? incoming
        : reduceSessionState(notifier.value, incoming);
    if (identical(next, notifier.value)) return false;
    notifier.value = next;
    lastChangedKey = incoming.sessionKey;
    changes.value++;
    return true;
  }

  /// 该 flow 会话还有真实活动（流式 chunk）：证明它确实在跑，取消保留计时。
  ///
  /// 主机不保证在 running 回合中途再发 `session.state`；如果只按时间收尾，
  /// 重连后仍在出字的长回合会被误判成 idle。chunk 到达就把保留转成确认。
  void noteFlowActivity(String sessionKey) {
    _cancelFlowRetention(sessionKey);
  }

  void _cancelFlowRetention(String sessionKey) {
    _flowRetentionTimers.remove(sessionKey)?.cancel();
  }

  /// 重连保留：先留着 running（停止按钮要靠 turnId），但设一个上限。
  void _retainRunningFlow(String sessionKey) {
    if (_flowRetentionTimers.containsKey(sessionKey)) return;
    _flowRetentionTimers[sessionKey] = Timer(flowRetention, () {
      _flowRetentionTimers.remove(sessionKey);
      final notifier = _notifiers[sessionKey];
      if (notifier == null) return;
      if (!notifier.value.isRunning) return;
      // 到期仍没有任何 flow 活动：按 idle 收尾，回落到 revision 基线重来。
      notifier.value = notifier.value.asIdle();
      lastChangedKey = sessionKey;
      changes.value++;
    });
  }

  /// `session_snapshot_resp` / `events_sync_resp` 的批量对账。
  /// 顺序无所谓：reducer 只认 revision。
  int applyAll(Iterable<dynamic> snapshots) {
    var applied = 0;
    for (final snapshot in snapshots) {
      if (snapshot is Map && apply(snapshot)) applied++;
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
  /// 时也要靠它识别换 hub。
  void reconcileTo(Iterable<dynamic> snapshots, {String? hubId}) {
    final seen = <String>{};
    final parsed = <Map<dynamic, dynamic>>[];
    String? effectiveHub = (hubId == null || hubId.isEmpty) ? null : hubId;
    for (final snapshot in snapshots) {
      if (snapshot is! Map) continue;
      final state = SessionState.fromSnapshot(snapshot);
      if (state.sessionKey.isEmpty) continue;
      if (effectiveHub == null && state.hubId.isNotEmpty) {
        effectiveHub = state.hubId;
      }
      seen.add(state.sessionKey);
      parsed.add(snapshot);
    }
    if (effectiveHub != null &&
        effectiveHub.isNotEmpty &&
        effectiveHub != _hubId) {
      // 换 hub：清空本地 revision 空间，让新 hub 的任何 revision 都能落地。
      // 之后旧 hub 的历史回放按 hub_id 不匹配被 apply 拒绝。
      for (final timer in _flowRetentionTimers.values) {
        timer.cancel();
      }
      _flowRetentionTimers.clear();
      for (final entry in _notifiers.entries) {
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
    for (final timer in _flowRetentionTimers.values) {
      timer.cancel();
    }
    _flowRetentionTimers.clear();
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    changes.dispose();
  }
}
