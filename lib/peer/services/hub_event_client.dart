import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../service_locator.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/chat_service.dart';
import '../../services/cli_execution_gate.dart';
import '../../services/local_database_service.dart';
import '../../services/noise_identity.dart';
import '../../services/serial_task_queue.dart';
import '../../services/logger_service.dart';
import '../../services/session/host_session_switch_card.dart';
import '../../storage/pouch_login.dart';
import '../../storage/pouch_login_keeper.dart';
import '../../storage/pouch_session.dart';
import '../hub_event_apply.dart';
import '../pouch_turn_relay.dart';
import 'peer_agent_client_service.dart';
import 'peer_connection.dart';
import 'peer_connection_manager.dart';
import 'peer_inflight_turn.dart';
import 'peer_storage_service.dart';
import 'session_runtime_mirror.dart';
import 'warm_ready_registry.dart';

/// 跟着储物袋把主机事件补到这台客户端。
///
/// 登录之后循环 `events_sync_req` 直到追上 `head_seq`，再吃实时 `hub_event`。
/// 序号对不上就先补洞。消息按 id 去重；没在看的回合用 `turn_attach_req` 接流。
class HubEventClient {
  /// 一页没拿到时的重试次数。超过就不再原地重试：游标跳到心跳报的 head。
  ///
  /// 原地重试正是「主机每 10 秒算一页、App 每 8 秒超时丢掉、`since_seq`
  /// 一直不变」那个自持循环的燃料，必须有出口。
  static const _maxPageAttempts = 3;
  static const _defaultPageTimeout = Duration(seconds: 8);

  /// 连续超时后单页最多再等多久。主机可能只是这一页翻得慢（大日志 + 冷
  /// 缓存），多等一轮就能补回来；等到这个上限还拿不到才跳 head，别把
  /// 能补回来的历史当成丢了。
  static const _maxPageTimeout = Duration(seconds: 60);

  /// 单页超时后继续等多久认领迟到的回包。主机那一页只是算得慢，不是没收到。
  static const _latePageWindow = Duration(seconds: 45);

  /// 迟到页最多存几个。游标一旦跳走，存着的页就没用了，留够重试即可。
  static const _maxLatePages = 8;

  /// 续传回合的落库合并窗口。主机补发 chunk 可以很密，落库与整列刷新
  /// 没必要跟着每帧走。
  static const _liveFlushInterval = Duration(milliseconds: 100);

  /// 游标读改写必须串行：live 事件是并发回调，读-派发-写不在一个临界区
  /// 会让相邻两帧读到同一个游标，游标按完成顺序回退。
  static const _controlKey = 'hub-control';

  HubEventClient({
    Stream<PeerControlEvent>? events,
    this.send,
    HubSeqStore? seqStore,
    this.fingerprintOf,
    this.watchingTurn,
    this.onCaughtUp,
    this.pageTimeout = _defaultPageTimeout,
    this.pageRetryDelay = const Duration(seconds: 1),
    this.flowIdleFinalizeDelay = const Duration(seconds: 2),
    this.flowFallbackFinalizeDelay = const Duration(seconds: 30),
  })  : events = events ?? PeerConnectionManager.instance.controlEvents,
        seqStore = seqStore ?? PrefsHubSeqStore();

  final Stream<PeerControlEvent> events;
  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final HubSeqStore seqStore;
  final Future<String> Function(String peerId)? fingerprintOf;
  final bool Function(String turnId)? watchingTurn;
  final void Function(String peerId)? onCaughtUp;

  /// 单页等待上限 / 每次重试的退避基数。测试里调小，线上用默认值。
  final Duration pageTimeout;
  final Duration pageRetryDelay;

  /// idle 后等最终 `message.created` 的窗口；超过就把占位收尾成终态。
  /// 测试里调小，线上用默认值。
  final Duration flowIdleFinalizeDelay;

  /// 没收到 idle 时的兜底窗口：第一个 chunk 就装，比 idle 窗口长得多。
  /// idle 是广播-only，掉线时丢了就再也不会有收尾信号；失败 / 取消回合又
  /// 没有最终消息，没有这个计时器占位会永远停在 streaming。测试里调小。
  final Duration flowFallbackFinalizeDelay;

  /// Test seam：流式 chunk 在解析落点前可以卡在这里，用来制造
  /// 「解析期间回合已被清掉」的时序。测试注入，线上为 null。
  @visibleForTesting
  Future<void> Function()? debugBeforeFlowChunkResolve;

  /// Test seam：收尾计时器**实际分配**过几个（A9-10）。
  /// 每片 chunk 只刷新 deadline、不重建 Timer，这个数不该随 chunk 数增长。
  @visibleForTesting
  int debugFinalizeTimerAllocations = 0;

  /// Test seam：`_insertMessage` 按频道扫过几次占位行（A9-9）。
  /// 普通 DM 长历史重放应该是 0。
  @visibleForTesting
  int debugLivePlaceholderScans = 0;

  /// Test seam：`_ensurePlaceholderHydrated` 被等过几次（A10-10）。
  /// `start()` 一次之后，flow 频道无占位的历史重放不该再逐条 await 它。
  @visibleForTesting
  int debugPlaceholderHydrationCalls = 0;

  /// Test seam：这个频道在启动时的一次 hydration 里确实发现了占位行。
  @visibleForTesting
  bool debugHasPlaceholderChannel(String channelId) =>
      _channelsWithLivePlaceholders.contains(channelId);

  /// Test seam：收尾计时器被装回过几次（A7-3：每片 chunk 都必须刷新并重新
  /// 装回，不能只取消）。A9-10 之后「装回」= 刷新 deadline，不再分配 Timer。
  @visibleForTesting
  int debugFinalizeTimerArms = 0;

  @visibleForTesting
  bool debugHasFinalizeTimer(String turnId) =>
      _finalizeDeadlines.containsKey(turnId);

  @visibleForTesting
  Duration debugFinalizeDelayFor(String turnId) =>
      _idleSeenTurns.contains(turnId)
          ? flowIdleFinalizeDelay
          : flowFallbackFinalizeDelay;

  /// Test seam：不等墙钟，立刻跑一次该回合的收尾计时器回调（A7-3）。
  @visibleForTesting
  void debugFireFinalizeTimer(String turnId) {
    _finalizeDeadlines.remove(turnId);
    _ensureFinalizeTimer();
    unawaited(_finalizeIdleTurn(turnId));
  }

  final _uuid = const Uuid();
  final _log = LoggerService();
  final _notices = StreamController<HubNotice>.broadcast();
  final _controlQueue = SerialTaskQueue<String>();

  /// attach 请求 id → turn id。主机回 attach-lost 时用它认领占位。
  final _attachRequests = <String, String>{};

  final _attached = <String>{};
  final _liveBuffers = <String, String>{};
  final _liveChannels = <String, String>{};

  /// 每回合的「登记代次」。流式 chunk 解析落点是异步的；await 期间回合可能
  /// 已经被终态消息 / idle 超时收尾清掉（[_clearLiveTurn]），代次随之一并失效。
  /// 回来先比对代次，否则会把已结束的回合重新登记回去，留下永不消失的流式气泡。
  final _liveTurnTokens = <String, Object>{};

  /// 每回合的收尾截止时刻（ms）。第一片 chunk 起用兜底窗口，idle 到达改短，
  /// 之后每片 chunk 都把 deadline 顺延。**一个** Timer 盯住最早的 deadline，
  /// 回调再按剩余回合续期；chunk 再密也不重建 Timer（A9-10）。
  final _finalizeDeadlines = <String, int>{};
  Timer? _finalizeTimer;
  int? _finalizeWakeAtMs;

  /// 已经收到过 idle 的回合：这些回合的收尾窗口用较短的
  /// [flowIdleFinalizeDelay]，其余用 [flowFallbackFinalizeDelay]。
  final _idleSeenTurns = <String>{};

  /// 已收尾并保留占位行的回合（失败 / 取消回合仅有的一段回答）。
  /// 不能被之后任何一条无关的 agent `message.created` 删掉（A7-1）。
  final _finalizedRetainedTurns = <String>{};
  static const _finalizedRetainedTurnCap = 512;

  void _rememberFinalizedRetainedTurn(String turnId) {
    if (turnId.isEmpty) return;
    _finalizedRetainedTurns.remove(turnId);
    _finalizedRetainedTurns.add(turnId);
    while (_finalizedRetainedTurns.length > _finalizedRetainedTurnCap) {
      _finalizedRetainedTurns.remove(_finalizedRetainedTurns.first);
    }
  }

  /// 占位行的 sender：中途消息删掉占位后，下一片 chunk 要按它重建同一行
  /// （A7-5），否则回复会从中间截断。
  final _placeholderSenders =
      <String, ({String senderId, String senderName})>{};

  /// 中途消息删掉占位、但之后还没有新 chunk 的回合。收尾计时器不能仅凭旧
  /// 缓冲把占位重新建出来（那条消息可能就是最终回复），只有真正的新 chunk
  /// 才能解除这个抑制。
  final _suppressRebuildTurns = <String>{};

  /// 已落过流式占位行的 turn（裸流程帧专用，避免每片 chunk 都写一次库）。
  final _flowPlaceholders = <String>{};

  /// 本机登记过 live/finalized 占位行的频道（A9-9）。普通 DM 频道从不进这里，
  /// 重放几千条历史时就不必为每条 agent 消息全表扫 `hub-live-%`。
  final _channelsWithLivePlaceholders = <String>{};

  /// 启动时（或重登后）从库里重建 retain 集合，整个 client 生命周期只做一次。
  Future<void>? _placeholderHydration;

  /// turn → 最近一次见到的 attempt / generation。主机瞬态重试会重放
  /// `begin_turn` 且 turn_id 不变，靠它认出新的一代（A9-5）。
  final _liveTurnGenerations = <String, String>{};
  static const _liveTurnGenerationCap = 512;

  /// 刚被重新激活、还带旧 `finalized` 占位行的 turn（A9-5）。
  /// 下一次建占位时把那行改回 streaming，别让新答案挂上「已收尾」标记。
  final _reactivatedTurns = <String>{};

  /// 已经收尾（idle 超时 / 最终消息 / turn.finished）的回合。
  ///
  /// 主机可能发完 idle / 最终消息后还有迟到的 chunk。回合此时已从
  /// [_liveChannels] 清掉，再按「新回合」处理会重建一个永远没人清理的
  /// streaming 占位。记下这些 id，迟到的 chunk 直接丢弃。
  /// 用 Set 保序，超过上限先丢最老的，避免无限增长。
  final _settledTurns = <String>{};
  static const _settledTurnCap = 512;

  bool _isSettledFlowTurn(String turnId) => _settledTurns.contains(turnId);

  void _markSettledTurn(String turnId) {
    if (turnId.isEmpty) return;
    _settledTurns.remove(turnId);
    _settledTurns.add(turnId);
    while (_settledTurns.length > _settledTurnCap) {
      _settledTurns.remove(_settledTurns.first);
    }
  }

  /// 一次启动时把库里还留着的占位行重建进内存（A9-4）：`dispose` / 重登
  /// 之后 `_finalizedRetainedTurns` 是空的，但 DB 行上的 `finalized` 标记还在。
  /// 只查一次，不做成每条消息一次全表扫。
  Future<void> _ensurePlaceholderHydrated() {
    debugPlaceholderHydrationCalls++;
    final running = _placeholderHydration;
    if (running != null) return running;
    final future = _hydratePlaceholderState();
    _placeholderHydration = future;
    return future;
  }

  Future<void> _hydratePlaceholderState() async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    try {
      final rows =
          await getIt<LocalDatabaseService>().listLiveTurnPlaceholderRows();
      for (final row in rows) {
        final id = row['id'] as String? ?? '';
        if (!id.startsWith(liveTurnPlaceholderPrefix)) continue;
        final channelId = row['channel_id'] as String? ?? '';
        if (channelId.isNotEmpty) {
          _channelsWithLivePlaceholders.add(channelId);
        }
        if (_placeholderIsFinalized(row['metadata'])) {
          _rememberFinalizedRetainedTurn(
            id.substring(liveTurnPlaceholderPrefix.length),
          );
        }
      }
    } catch (_) {
      // 库还没就绪不该挡住事件处理；删除路径还会逐行查 finalized 标记兜底。
    }
  }

  void _markPlaceholderChannel(String channelId) {
    if (channelId.isNotEmpty) _channelsWithLivePlaceholders.add(channelId);
  }

  /// 任何删占位之前都查一次 DB 的 `finalized` 标记（A9-4）：内存集合可能因
  /// 重登 / dispose 丢过，DB 才是持久的保护依据。
  Future<bool> _isRetainedPlaceholder(String turnId) async {
    if (turnId.isEmpty) return false;
    if (_finalizedRetainedTurns.contains(turnId)) return true;
    if (!getIt.isRegistered<LocalDatabaseService>()) return false;
    final row = await getIt<LocalDatabaseService>()
        .getMessageById(liveTurnPlaceholderId(turnId));
    if (row == null) return false;
    final channelId = row['channel_id'] as String? ?? '';
    _markPlaceholderChannel(channelId);
    if (!_placeholderIsFinalized(row['metadata'])) return false;
    _rememberFinalizedRetainedTurn(turnId);
    return true;
  }

  /// 主机瞬态重试复用 turn_id：新的 `begin_turn` / attempt / generation，或
  /// `turn.started` / running `session.state` 帧，都要把这个回合从 settled 里
  /// 重新激活，否则重试的 chunk 会被整批丢掉（A9-5）。
  void _reactivateSettledTurn(String turnId) {
    if (!_settledTurns.remove(turnId)) return;
    _finalizedRetainedTurns.remove(turnId);
    _idleSeenTurns.remove(turnId);
    _finalizeDeadlines.remove(turnId);
    _ensureFinalizeTimer();
    _flowPlaceholders.remove(turnId);
    _suppressRebuildTurns.remove(turnId);
    _liveBuffers.remove(turnId);
    _liveDirty.remove(turnId);
    _liveTurnTokens.remove(turnId);
    _attached.remove(turnId);
    _liveChannels.remove(turnId);
    _placeholderSenders.remove(turnId);
    _attachRequests.removeWhere((_, id) => id == turnId);
    _forgetFlowTargets(turnId);
    _reactivatedTurns.remove(turnId);
    _reactivatedTurns.add(turnId);
    while (_reactivatedTurns.length > _settledTurnCap) {
      _reactivatedTurns.remove(_reactivatedTurns.first);
    }
  }

  /// 带新 attempt/generation 的 chunk/metadata 自己就能证明这是重试的一代。
  /// 帧里没有 attempt 时靠 [_reactivateSettledTurn] 的调用方（turn.started /
  /// running 帧）激活。
  bool _reactivateOnNewAttempt(String turnId, Map<String, dynamic> data) {
    final attempt =
        (data['attempt'] ?? data['generation'] ?? '').toString().trim();
    final begin = data['type'] == 'begin_turn' ||
        data['kind'] == 'begin_turn' ||
        data['event'] == 'begin_turn';
    if (_isSettledFlowTurn(turnId) &&
        (begin ||
            (attempt.isNotEmpty && attempt != _liveTurnGenerations[turnId]))) {
      _reactivateSettledTurn(turnId);
    }
    if (attempt.isEmpty) return false;
    _liveTurnGenerations.remove(turnId);
    _liveTurnGenerations[turnId] = attempt;
    while (_liveTurnGenerations.length > _liveTurnGenerationCap) {
      _liveTurnGenerations.remove(_liveTurnGenerations.keys.first);
    }
    return true;
  }

  /// 这条消息属于哪个回合。主机 H10-12 之后在最终 flow agent 消息的
  /// `metadata.flow.turn_id` 里带上它；老主机 / 中继可能放在顶层、
  /// `metadata` 或 `request_id`。带得出来就只处理那一回合的占位，
  /// 带不出来则由调用方走保守路径（A9-2 / A10-4）。
  static String? _messageTurnId(Map<String, dynamic> data) {
    String? value(Object? raw) {
      final text = raw?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    final direct = value(data['turn_id']);
    if (direct != null) return direct;
    final meta = data['metadata'];
    if (meta is Map) {
      final fromMeta = value(meta['turn_id']) ?? value(meta['request_id']);
      if (fromMeta != null) return fromMeta;
      final flow = meta['flow'];
      if (flow is Map) {
        final fromFlow = value(flow['turn_id']) ?? value(flow['request_id']);
        if (fromFlow != null) return fromFlow;
      }
    }
    return value(data['request_id']);
  }

  /// 本回合还有真实活动（chunk / metadata）：刷新 mirror 里重连保留条目的
  /// 活动时间戳。以前这里把 3 个候选 key 逐个丢给 mirror，每个 key 一次后缀
  /// 全表扫 + 一次 Timer 重建（A9-10）；现在直接给出已解析好的权威 key。
  void _noteFlowActivity(Map<String, dynamic> data, String rawChannelId) {
    if (!getIt.isRegistered<SessionRuntimeMirror>()) return;
    String text(String key) => data[key]?.toString().trim() ?? '';
    final explicitKey = text('session_key');
    final channel = rawChannelId.trim();
    final bare = explicitKey.isNotEmpty
        ? (explicitKey.contains(':')
            ? explicitKey.substring(explicitKey.lastIndexOf(':') + 1)
            : explicitKey)
        : (remoteSessionIdFromChannelId(channel) ?? channel);
    final agentId = text('agent_id');
    String? notifierKey;
    if (explicitKey.isNotEmpty && explicitKey.contains(':')) {
      notifierKey = explicitKey;
    } else if (bare.isNotEmpty && agentId.isNotEmpty) {
      notifierKey = 'agent:$agentId:$bare';
    }
    final key = notifierKey ?? (explicitKey.isNotEmpty ? explicitKey : bare);
    if (key.isEmpty) return;
    getIt<SessionRuntimeMirror>()
        .noteFlowActivity(key, notifierKey: notifierKey);
  }

  /// 流式 chunk 的落点解析缓存，key = `peerId\u0000turnId`。
  ///
  /// 每个 chunk 都去查库 / 建壳太贵，而且解析是异步的：同一回合的两片几乎
  /// 同时到达，缓存结果还不够，必须缓存 **Future** 才能只解析一次。
  /// 回合结束（idle / 占位清理）时删掉，跨设备也不会串（key 带 peerId）。
  final _flowTargets = <String,
      Future<({String channelId, String senderId, String senderName})>>{};

  /// Test seam：本机实际做了几次落点解析，验证同一回合的 chunk 复用缓存。
  @visibleForTesting
  int debugFlowControlTargetResolves = 0;

  String _flowTargetKey(String peerId, String turnId) => '$peerId\u0000$turnId';

  void _forgetFlowTargets(String turnId) {
    if (turnId.isEmpty) return;
    _flowTargets.removeWhere((key, _) => key.endsWith('\u0000$turnId'));
  }

  /// 回合 → 这个回合问过的问题。回合结束时按它兜底收起还没答的卡片。
  final _turnCards = <String, Set<String>>{};

  StreamSubscription<PeerControlEvent>? _sub;
  StreamSubscription<void>? _reloginSub;
  StreamSubscription<PouchSession>? _channelInstalledSub;
  StreamSubscription<PeerConnectionEvent>? _connSub;
  StreamSubscription<Duration>? _resumeSub;
  Future<void>? _syncing;

  /// 补拉进行中又收到的请求（多半来自重连）。当前 job 收尾后按 peer 重跑。
  final _catchUpQueued = <String>{};

  /// 补拉期间暂存的 live 事件。
  ///
  /// 补拉正在读改写游标，live 事件不能并发应用；先按 peer 暂存，收尾后
  /// 按序回放。页里已经覆盖的事件会被游标判成 duplicate 跳过，只有落在
  /// 页尾之后的才真正应用 —— 不能像以前那样直接丢弃等 30s 的 ping。
  final _liveDeferred = <String, List<HubEvent>>{};

  /// 暂存溢出的 peer（补拉拖得太久 / 事件太多）。不再逐条囤，收尾后整轮补拉。
  final _deferredOverflow = <String>{};

  /// 单个 peer 最多暂存多少条 live 事件。
  static const _maxDeferredLivePerPeer = 512;

  /// 补拉一页时每应用多少条事件落一次游标。
  ///
  /// 游标只在整页走完后才写的旧做法，遇到一条应用失败的事件（或进程在
  /// 页中途被杀）就永远停在原序号：每次重连都重拉同一页，永远追不上。
  static const _cursorPersistBatch = 50;

  var _livePaused = false;

  /// 超时之后才回来的补拉页，按 `peer/request_id` 存着。
  ///
  /// 游标没动时下一轮用的是同一个 request_id，先来这里取，不用让主机把
  /// 同一段历史再算一遍。
  final _latePages = <String, HubSyncPage>{};

  /// 心跳报的 head_seq。页面连续失败时用它把游标一把推到主机所在的位置。
  final _pingHead = <String, int>{};

  final _random = Random();

  Stream<HubNotice> get notices => _notices.stream;

  /// 这台设备正在看的本地频道上，是否还有别的端发起、尚未结束的回合。
  bool channelHasLiveTurn(String channelId) {
    if (channelId.isEmpty) return false;
    for (final id in _liveChannels.values) {
      if (id == channelId) return true;
    }
    return false;
  }

  void start() {
    // A9-4：dispose / 重登之后内存里的 retain 集合没了，但库里带 finalized
    // 标记的行还在。启动时一次性重建，之后任何删除都会再查一次 DB 兜底。
    unawaited(_ensurePlaceholderHydrated());
    _sub ??= events.listen(_onControl);
    _reloginSub ??= PouchLoginKeeper.instance.relogged.listen((_) {
      unawaited(_syncActiveHost());
    });
    _channelInstalledSub ??= PouchChannel.installed.listen((session) {
      unawaited(_catchUpIfConnected(session.hostPeerId));
      // 凭据复用、没有新的 pouch_login_resp 时也要对账一次。
      unawaited(requestSessionSnapshot(session.hostPeerId));
    });
    _connSub ??= PeerConnectionManager.instance.events.listen((event) {
      if (event.type == PeerConnectionEventType.connected) {
        unawaited(_catchUpIfActiveHost(event.peerId));
        // 每次连接建立都对账一次：冷启动复用凭据时不会有 pouch_login_resp。
        unawaited(requestSessionSnapshot(event.peerId));
      }
    });
    _resumeSub ??= AppLifecycleService().onResume.listen((_) {
      unawaited(_syncActiveHost());
    });
    final active = PouchChannel.active?.session;
    if (active != null) {
      unawaited(_catchUpIfConnected(active.hostPeerId));
      // installed 是广播且不回放，恢复登录时它早于 start() 触发；冷启动必须
      // 在这里补一次全量对账，否则 mirror 一直是空的。
      unawaited(requestSessionSnapshot(active.hostPeerId));
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _reloginSub?.cancel();
    await _channelInstalledSub?.cancel();
    await _connSub?.cancel();
    await _resumeSub?.cancel();
    _sub = null;
    _reloginSub = null;
    _channelInstalledSub = null;
    _connSub = null;
    _resumeSub = null;
    _liveFlushTimer?.cancel();
    _liveFlushTimer = null;
    _finalizeTimer?.cancel();
    _finalizeTimer = null;
    _finalizeWakeAtMs = null;
    _finalizeDeadlines.clear();
    _idleSeenTurns.clear();
    _finalizedRetainedTurns.clear();
    _placeholderSenders.clear();
    _suppressRebuildTurns.clear();
    _flowPlaceholders.clear();
    _channelsWithLivePlaceholders.clear();
    _reactivatedTurns.clear();
    _liveTurnGenerations.clear();
    _placeholderHydration = null;
    _liveDirty.clear();
    _flowTargets.clear();
    _liveTurnTokens.clear();
    _settledTurns.clear();
    _attachRequests.clear();
    _catchUpQueued.clear();
    _liveDeferred.clear();
    _deferredOverflow.clear();
    _latePages.clear();
    _pingHead.clear();
  }

  Future<void> _onControl(PeerControlEvent event) async {
    switch (event.type) {
      case 'pouch_login_resp':
        if (event.data['accepted'] == true) {
          // 调用方要等这一帧返回后才装上登录通道。立刻补洞会以明文发出去。
          final peerId = event.peerId;
          unawaited(Future<void>(() => catchUp(peerId)));
          // 与 catchUp 一样延迟到本帧返回、登录通道装好之后再发；同步发出
          // 会让未密封的业务帧被主机拒绝（回 pouch_login_required）。
          unawaited(Future<void>(() => requestSessionSnapshot(peerId)));
        }
      case 'hub_event':
        final parsed = HubEvent.parse(event.data['event']);
        if (parsed == null) return;
        if (_livePaused) {
          if (_deferredOverflow.contains(event.peerId)) return;
          final deferred =
              _liveDeferred.putIfAbsent(event.peerId, () => <HubEvent>[]);
          if (deferred.length >= _maxDeferredLivePerPeer) {
            // 补拉拖得太久、事件太多：丢掉已攒的，收尾后整轮补拉兜底。
            _liveDeferred.remove(event.peerId);
            _deferredOverflow.add(event.peerId);
            return;
          }
          deferred.add(parsed);
          return;
        }
        await _controlQueue.run(
          _controlKey,
          () => _onLive(event.peerId, parsed),
        );
      case 'ping':
        // head 只是个数，先记下来。补拉正卡着时对账任务要排在它后面，
        // 但「主机说它已经到哪了」不该跟着一起等：连续失败要跳到 head
        // 时，这一轮就得知道。
        final head = event.data['head_seq'];
        if (head is int) _pingHead[event.peerId] = head;
        await _controlQueue.run(
          _controlKey,
          () => _onPingHeadSeq(event.peerId),
        );
      case 'agent_error':
        await _controlQueue.run(
          _controlKey,
          () => _onAttachLost(event.data),
        );
      case 'pouch_turn_event':
        await _onAttachedChunk(event.peerId, event.data);
      // 工作流节点回合是主机直接 publish 的裸控制帧，不是 hub_event（不进
      // 事件日志、重连也不回放）。它没有 App 本地 _pending，所以
      // PeerAgentClientService._onChunk / _onMetadata 会丢；这里按 channel_id
      // 认领并接流。普通 DM 帧不带 flow 标记，原路径完全不变。
      case 'agent_chunk':
        await _onFlowControlChunk(event.peerId, event.data);
      case 'agent_metadata':
        await _onFlowControlMetadata(event.peerId, event.data);
      case 'session.state':
        await _onRawSessionState(event.peerId, event.data);
      case 'events_sync_resp':
        break;
      case 'session_snapshot_resp':
        // 启动 / 重连全量对账：只认最新请求的回执，且必须是当前主机，
        // 否则旧连接 / 非主机 peer 的快照会把 mirror 强制回退。
        final requestId = event.data['request_id'] as String? ?? '';
        final seq = _snapshotRequests.remove(requestId);
        if (seq == null || seq < _snapshotAppliedSeq) {
          return;
        }
        _snapshotAppliedSeq = seq;
        final activeHost = PouchChannel.active?.session.hostPeerId;
        if (activeHost != null &&
            activeHost.isNotEmpty &&
            event.peerId != activeHost) {
          return;
        }
        // A10-3：H10-11 在顶层放 `epoch`（u64）。整个响应（包括 sessions 为空
        // 或缺字段的快照）都要参与对账，否则换 hub / 主机重启时这条唯一的
        // 权威信号会被丢掉。
        if (getIt.isRegistered<SessionRuntimeMirror>()) {
          final sessions = event.data['sessions'];
          getIt<SessionRuntimeMirror>().reconcileTo(
            sessions is List ? sessions : const <dynamic>[],
            hubId: event.data['hub_id'] as String?,
            epoch: _snapshotEpoch(event.data),
            sourcePeerId: event.peerId,
          );
        }
    }
  }

  /// 从 `session_snapshot_resp` 里取主机进程代次（A10-3）。
  ///
  /// 顶层 `epoch` 是 H10-11 的正式位置；兼容老主机 / 中继把它放在
  /// `hub_epoch`、`sessions[].epoch`（[SessionRuntimeMirror.reconcileTo] 也会逐条
  /// 兜底）或 `snapshot.epoch` 的形态。数字 / 字符串统一成可比较的文本。
  static String? _snapshotEpoch(Map<String, dynamic> data) {
    String? normalized(Object? raw) {
      if (raw == null) return null;
      final text = raw.toString().trim();
      return text.isEmpty || text == 'null' ? null : text;
    }

    final top = normalized(data['epoch']) ?? normalized(data['hub_epoch']);
    if (top != null) return top;
    final sessions = data['sessions'];
    if (sessions is List) {
      for (final session in sessions) {
        if (session is! Map) continue;
        final epoch =
            normalized(session['epoch']) ?? normalized(session['hub_epoch']);
        if (epoch != null) return epoch;
      }
    }
    final snapshot = data['snapshot'];
    if (snapshot is Map) {
      return normalized(snapshot['epoch']) ?? normalized(snapshot['hub_epoch']);
    }
    return null;
  }

  /// Test seam：核对快照 epoch 的几种兼容位置（A10-3）。
  @visibleForTesting
  static String? debugSnapshotEpoch(Map<String, dynamic> data) =>
      _snapshotEpoch(data);

  /// 登录成功后立刻要一份所有活跃会话的全量状态快照。
  /// 主机正在跑、但启动那一刻没有状态跃迁的回合，只有这次对账能让 App
  /// 看到；`session.state` 是跃迁事件，不会为「早就开始了」的回合补发。
  int _snapshotSeq = 0;
  int _snapshotAppliedSeq = -1;

  /// request_id → 发出序号。并发请求的回执按序号只应用最新的一份，
  /// 但任意一次成功发出的请求都能拿到回执（不会因为最后一次发送失败而全丢）。
  final Map<String, int> _snapshotRequests = {};

  Future<void> requestSessionSnapshot(String peerId) async {
    final activeHost = PouchChannel.active?.session.hostPeerId;
    if (activeHost != null && activeHost.isNotEmpty && peerId != activeHost) {
      return;
    }
    final seq = ++_snapshotSeq;
    final id = _uuid.v4();
    _snapshotRequests[id] = seq;
    final sent = await _send(peerId, <String, dynamic>{
      'type': 'session_snapshot_req',
      'request_id': id,
    });
    if (!sent) _snapshotRequests.remove(id);
  }

  Future<void> catchUp(String peerId) {
    final running = _syncing;
    if (running != null) {
      // 连接可能已经换了一条，而当前 job 还卡在旧连接的超时里。
      // 记下来，等它收尾后立刻再补一次。
      _catchUpQueued.add(peerId);
      return running;
    }
    final job = _controlQueue.run(_controlKey, () => _catchUpNow(peerId));
    _syncing = job;
    return job.whenComplete(() {
      if (identical(_syncing, job)) _syncing = null;
      if (_catchUpQueued.isEmpty) return;
      final queued = _catchUpQueued.toList();
      _catchUpQueued.clear();
      for (final peer in queued) {
        scheduleMicrotask(() => unawaited(catchUp(peer)));
      }
    });
  }

  /// 已经在 [_controlQueue] 里的调用方（live 事件、ping 对账）必须直接调它，
  /// 再调 [catchUp] 会在同一个键上重入，永远等不到。
  Future<void> _catchUpNow(String peerId) async {
    _livePaused = true;
    try {
      final key = await _key(peerId);
      var cursor = await seqStore.read(key);
      var attempts = 0;
      // 同一段游标的重试用同一个 request_id：上一轮超时后主机算完的那页
      // 还能认领回来，不必重算。
      var requestId = _uuid.v4();
      while (true) {
        // 越往后等得越久：主机可能只是这一页算得慢。连续超时才逐步加长，
        // 等到上限还没回包才判死。
        final page = await _requestPage(
          peerId,
          cursor,
          requestId,
          timeout: _pageTimeoutFor(attempts),
        );
        if (page == null) {
          // 没拿到页（超时或发送失败）：游标不动，退避重试几次。
          attempts += 1;
          if (attempts >= _maxPageAttempts) {
            // 连着几轮都拿不到页，就别再钉在同一个 seq 上了。心跳报的
            // head 是主机亲口说的位置：跳过去，中间那段按丢掉处理，历史
            // 同步进度作废，下次打开会话时从头重建。
            final head = _pingHead[peerId] ?? 0;
            if (head > cursor) {
              _log.warning(
                '事件补拉连续 $attempts 次失败，游标从 $cursor 跳到 head_seq=$head',
                tag: 'HubEvent',
              );
              final stale = cursor;
              cursor = head;
              await seqStore.write(key, cursor);
              // 中途这段事件确实丢了：本地记的历史同步进度不再可信。
              // 游标原本就是 0（首次同步）时没有进度可作废。
              if (stale > 0) await _invalidateHistoryAfterReset();
              attempts = 0;
              requestId = _uuid.v4();
              continue;
            }
            // 主机没报过 head（还没收到过 ping），或者本地就是最新的：
            // 放弃这一轮，等下一次 ping / 重连再给机会。
            _log.warning(
              '事件补拉连续 $attempts 次失败（since_seq=$cursor），本轮放弃，'
              '等下次心跳或重连再试',
              tag: 'HubEvent',
            );
            return;
          }
          await Future<void>.delayed(_backoff(attempts));
          continue;
        }
        attempts = 0;
        requestId = _uuid.v4();
        final base = page.reset ? 0 : cursor;
        if (page.reset) {
          if (!_notices.isClosed) _notices.add(HubNotice.reset(peerId));
          // 游标还是 0 说明是首次同步，本来就要从头拉，没有进度可作废。
          if (cursor > 0) await _invalidateHistoryAfterReset();
        }
        var walking = base;
        var persisted = base;
        var pendingPersist = 0;
        for (final event in page.events) {
          final step = cursorStep(walking, event.seq);
          if (!page.reset && step != HubCursorStep.apply) continue;
          try {
            await _dispatch(peerId, event);
          } catch (_) {
            // 偶发的 SQLite 忙 / 锁值得再试一次；仍然失败就跳过，不能让
            // 一条坏事件把游标永久钉在这一页上。
            try {
              await _dispatch(peerId, event);
            } catch (error) {
              _log.warning(
                'skip undispatchable event seq=${event.seq} '
                'kind=${event.kind}: $error',
                tag: 'HubEvent',
              );
            }
          }
          walking = event.seq;
          pendingPersist++;
          if (pendingPersist >= _cursorPersistBatch) {
            await seqStore.write(key, walking);
            persisted = walking;
            pendingPersist = 0;
          }
        }
        cursor = cursorAfterPage(base, page);
        if (cursor != persisted) {
          await seqStore.write(key, cursor);
        }
        if (syncCaughtUp(cursor, page.headSeq) || page.events.isEmpty) {
          onCaughtUp?.call(peerId);
          unawaited(PouchTurnRelay.instance.flushPendingReads(peerId));
          return;
        }
      }
    } finally {
      _livePaused = false;
      _drainDeferredLive();
    }
  }

  /// 补拉结束，回放期间暂存的 live 事件。
  ///
  /// 当前仍在 [_controlQueue] 的任务里，所以不直接应用，而是入队一批任务
  /// 排到补拉之后，保证游标按顺序推进。
  void _drainDeferredLive() {
    if (_liveDeferred.isEmpty && _deferredOverflow.isEmpty) return;
    final deferred = <String, List<HubEvent>>{
      for (final entry in _liveDeferred.entries)
        entry.key: List<HubEvent>.of(entry.value),
    };
    _liveDeferred.clear();
    final overflowed = _deferredOverflow.toList();
    _deferredOverflow.clear();
    scheduleMicrotask(() {
      for (final entry in deferred.entries) {
        if (overflowed.contains(entry.key)) continue;
        unawaited(_controlQueue.run(
          _controlKey,
          () => _applyDeferredLive(entry.key, entry.value),
        ));
      }
      for (final peerId in overflowed) {
        unawaited(catchUp(peerId));
      }
    });
  }

  /// 按游标回放一批暂存的 live 事件。
  ///
  /// 补拉已经追到当时的 head，大部分事件会被判成 duplicate；只有页尾之后
  /// 的新事件会应用。遇到缺口说明 live 投递中间丢过帧，排一轮补拉把缺口
  /// 填上即可，不要为后面每条事件各跑一轮。
  Future<void> _applyDeferredLive(String peerId, List<HubEvent> events) async {
    final key = await _key(peerId);
    var cursor = await seqStore.read(key);
    try {
      for (final event in events) {
        switch (cursorStep(cursor, event.seq)) {
          case HubCursorStep.duplicate:
            continue;
          case HubCursorStep.gap:
            unawaited(catchUp(peerId));
            return;
          case HubCursorStep.apply:
            await _dispatch(peerId, event);
            await seqStore.write(key, event.seq);
            cursor = event.seq;
        }
      }
    } catch (error) {
      _log.warning(
        'apply deferred live events failed: $error',
        tag: 'HubEvent',
      );
      unawaited(catchUp(peerId));
    }
  }

  Future<void> _onLive(String peerId, HubEvent event) async {
    if (_livePaused) return;
    final key = await _key(peerId);
    final cursor = await seqStore.read(key);
    switch (cursorStep(cursor, event.seq)) {
      case HubCursorStep.duplicate:
        return;
      case HubCursorStep.gap:
        await _catchUpNow(peerId);
        return;
      case HubCursorStep.apply:
        try {
          await _dispatch(peerId, event);
        } catch (error) {
          // 游标停在上一帧，交给补拉再试；补拉遇到同一条仍然失败时会
          // 跳过它继续前进，不会永久卡在同一序号。
          _log.warning(
            'live dispatch failed seq=${event.seq} kind=${event.kind}: $error',
            tag: 'HubEvent',
          );
          unawaited(catchUp(peerId));
          return;
        }
        await seqStore.write(key, event.seq);
    }
  }

  /// 主机说它的事件日志已经裁掉一截：这一段事件永远补不回来了，本地记的
  /// 历史同步进度也就不再可信，作废后交给下次打开会话时从头重建。
  Future<void> _invalidateHistoryAfterReset() async {
    try {
      await PeerAgentClientService.instance.invalidateHistorySync();
    } catch (error) {
      _log.warning('history invalidation after reset failed: $error',
          tag: 'HubEvent');
    }
  }

  /// 心跳带来的对账机会：主机说到的序号比本地游标新，就去补。
  ///
  /// `cursorStep` 的缺口判定要靠收到「下一帧」才成立 —— 丢的若是最后一帧，
  /// 后面再没有帧来，本地就永远察觉不到自己落后。ping 每 30 秒来一次，是唯一
  /// 能兜住这种情况的信号（实时帧在主机侧可能因为发送队列满被丢掉）。
  Future<void> _onPingHeadSeq(String peerId) async {
    final rawHead = _pingHead[peerId];
    if (rawHead == null) return;
    final key = await _key(peerId);
    final cursor = await seqStore.read(key);
    if (rawHead <= cursor) return;
    await _catchUpNow(peerId);
  }

  Future<HubSyncPage?> _requestPage(
    String peerId,
    int since,
    String requestId, {
    Duration? timeout,
  }) async {
    final key = _latePageKey(peerId, requestId);
    // 上一轮超时之后主机照样把这页算了回来。游标没动、request_id 也没变，
    // 直接拿走，不用让它再算一遍。
    final late = _latePages.remove(key);
    if (late != null) return late;

    final done = Completer<HubSyncPage?>();
    final sub = events.listen((event) {
      if (done.isCompleted || event.peerId != peerId) return;
      if (event.data['request_id'] != requestId) return;
      if (event.type == 'events_sync_resp') {
        done.complete(HubSyncPage.parse(event.data));
        return;
      }
      // 主机上行队列满时回 `peer_busy`，这一页根本没被收下。等满 8 秒再退避
      // 既慢又只留下「超时」一句，认出来就立刻收尾，把原因写清楚。
      if (event.type == 'peer_busy') {
        _log.warning(
          '主机正忙，补拉被拒：${event.data['message'] ?? ''}',
          tag: 'HubEvent',
        );
        done.complete(null);
      }
    });
    try {
      final sent = await _send(peerId, {
        'type': 'events_sync_req',
        'request_id': requestId,
        'since_seq': since,
        'limit': 500,
      });
      if (!sent) {
        await sub.cancel();
        return null;
      }
      return await done.future.timeout(timeout ?? pageTimeout);
    } on TimeoutException catch (error) {
      // 单次超时不值得每 8 秒写一条告警：连着失败会在本轮收尾时汇总一条。
      _log.debug('events sync failed: $error', tag: 'HubEvent');
      // 超时不等于没收到：主机只是算得慢，回包还会来。别把监听一起取消
      // 扔掉，留到下一轮按同一个 request_id 认领。
      _claimLatePage(key, done, sub);
      return null;
    } catch (error) {
      _log.warning('events sync failed: $error', tag: 'HubEvent');
      await sub.cancel();
      return null;
    }
  }

  static String _latePageKey(String peerId, String requestId) =>
      '$peerId/$requestId';

  /// 超时之后继续等这条 request_id 的回包。
  ///
  /// 等到了就按 key 存进 [_latePages]（重试时取走）；[_latePageWindow] 到期
  /// 或回包落定后取消监听。以前这里在 `finally` 里直接 `sub.cancel()`，
  /// 迟到的那页被无声丢掉，下一轮又从同一个游标重算整段历史。
  void _claimLatePage(
    String key,
    Completer<HubSyncPage?> done,
    StreamSubscription<PeerControlEvent> sub,
  ) {
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      unawaited(sub.cancel());
    }

    final timer = Timer(_latePageWindow, close);
    unawaited(done.future.then((page) {
      timer.cancel();
      if (page != null) {
        _latePages[key] = page;
        while (_latePages.length > _maxLatePages) {
          _latePages.remove(_latePages.keys.first);
        }
      }
      close();
    }));
  }

  /// 重试退避带抖动：多台设备常常从同一个游标一起超时，全都在同一毫秒
  /// 冲上来只会把主机的队列再堆高一次。
  Duration _backoff(int attempt) {
    final base = pageRetryDelay.inMilliseconds * attempt;
    final jitter = base <= 1 ? 0 : _random.nextInt(base ~/ 2 + 1);
    return Duration(milliseconds: base + jitter);
  }

  /// 第 `failed` 次超时之后，这一页再多等多久。
  ///
  /// 主机那一页可能只是算得慢（大日志、冷缓存、机器忙），8 秒判死会
  /// 白白丢掉能补回来的历史。每失败一次翻一倍，封顶 [_maxPageTimeout]。
  Duration _pageTimeoutFor(int failed) {
    if (failed <= 0) return pageTimeout;
    final shift = failed > 3 ? 3 : failed;
    final grown = pageTimeout * (1 << shift);
    return grown > _maxPageTimeout ? _maxPageTimeout : grown;
  }

  Future<void> _dispatch(String peerId, HubEvent event) async {
    switch (event.kind) {
      case 'agent.warm_ready':
        final agentId = (event.data['agent_id'] as String?)?.trim() ?? '';
        final sessionId = (event.data['session_id'] as String?)?.trim() ?? '';
        WarmReadyRegistry.instance.record(
          agentId,
          sessionId,
          event.data['ok'] == true,
        );
      case 'message.created':
        await _insertMessage(peerId, event);
      case 'message.updated':
        await _updateMessage(event);
      case 'channel.read':
        await _onChannelRead(event);
      case 'turn.started':
        await _onTurnStarted(peerId, event);
      case 'turn.finished':
        await _onTurnFinished(event);
      case 'session.state':
        // 主机是唯一 writer：这里只按 revision 应用全量快照，绝不自己
        // 凭静默秒数判回合结束。live 丢了就靠 events_sync 补拉，天然幂等。
        if (getIt.isRegistered<SessionRuntimeMirror>()) {
          getIt<SessionRuntimeMirror>().apply(event.data, sourcePeerId: peerId);
        }
        // 队列是 durable 的：session_ack 单播丢帧时用它自愈 relay 的排队豁免。
        final queue = event.data['queue'];
        if (queue is List) {
          PouchTurnRelay.instance.noteHostQueue(queue);
        }
      case 'interaction.pending':
        await _showInteraction(peerId, event);
        if (!_notices.isClosed) {
          _notices.add(HubNotice(peerId: peerId, event: event));
        }
      case 'interaction.resolved':
        await _onInteractionResolved(event);
        if (!_notices.isClosed) {
          _notices.add(HubNotice(peerId: peerId, event: event));
        }
      case 'agent_meta.changed':
        _applyMeta(peerId, event);
      case 'session.switch':
        await _onSessionSwitch(event);
      case 'group.session.changed':
        await _onGroupSessionChanged(peerId, event);
      case 'agents.changed':
      case 'groups.changed':
        if (!_notices.isClosed) {
          _notices.add(HubNotice(peerId: peerId, event: event));
        }
    }
  }

  /// 主机建好私聊会话：在来源会话挂一张切换卡片。
  /// 会话名单同步由 `agent_meta.changed kind=sessions` 负责，不在这里做。
  Future<void> _onSessionSwitch(HubEvent event) async {
    final action = event.data['session_action'];
    if (action is! Map) return;
    final source =
        (event.data['source_session_id']?.toString() ?? '').isNotEmpty
            ? event.data['source_session_id'].toString()
            : event.channelId;
    if (source.isEmpty) return;
    await attachHostSessionSwitchCard(
      channelId: source,
      sessionAction: Map<String, dynamic>.from(action),
    );
  }

  /// 主机建好群会话：在来源群频道挂切换卡片，并把交接摘要显示出来。
  /// 正文的权威副本由主机写进新会话日志；App 按群 current_session 拉历史时
  /// 新会话未必是 current，所以这里在来源频道补一条本地摘要，保证用户能看到。
  Future<void> _onGroupSessionChanged(String peerId, HubEvent event) async {
    final data = event.data;
    final action = data['session_action'];
    var source = '';
    if (action is Map) {
      final enriched = <String, dynamic>{
        ...Map<String, dynamic>.from(action),
        'kind': 'group',
        'group_id': (data['group_id']?.toString() ?? '').isNotEmpty
            ? data['group_id'].toString()
            : event.channelId,
      };
      source = enriched['source_session_id']?.toString() ?? '';
      if (source.isNotEmpty) {
        await attachHostSessionSwitchCard(
          channelId: source,
          sessionAction: enriched,
        );
      }
    }
    final handoff = data['handoff_text']?.toString().trim() ?? '';
    final createdAt = data['created_at_ms'];
    final fresh = createdAt is! int ||
        DateTime.now().millisecondsSinceEpoch - createdAt <= 600000;
    if (handoff.isNotEmpty && source.isNotEmpty && fresh) {
      final db = getIt.isRegistered<LocalDatabaseService>()
          ? getIt<LocalDatabaseService>()
          : LocalDatabaseService();
      final local = await localChannelIdForHostSession(db, source);
      await _insertGroupHandoffMessage(
        local,
        data['session_id']?.toString() ?? '',
        handoff,
      );
    }
    if (!_notices.isClosed) {
      _notices.add(HubNotice(peerId: peerId, event: event));
    }
  }

  /// 群会话不是独立本地频道，交接摘要落在来源群频道，按会话 id 去重。
  Future<void> _insertGroupHandoffMessage(
    String channelId,
    String sessionId,
    String text,
  ) async {
    if (channelId.isEmpty) return;
    final db = getIt.isRegistered<LocalDatabaseService>()
        ? getIt<LocalDatabaseService>()
        : LocalDatabaseService();
    final id =
        'group_handoff_${channelId.hashCode.abs()}_${sessionId.hashCode.abs()}';
    try {
      if (await db.getMessageById(id) != null) return;
      await db.createMessage(
        id: id,
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'system',
        content: text,
        messageType: 'text',
      );
      await db.markMessageAsRead(id);
      _notify(channelId);
    } catch (e) {
      LoggerService().warning(
        'Failed to insert group handoff message: $e',
        tag: 'HubEvent',
      );
    }
  }

  Future<void> _onChannelRead(HubEvent event) async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final db = getIt<LocalDatabaseService>();
    final rawAgentId = (event.data['agent_id'] as String?)?.trim() ?? '';
    final agentId = rawAgentId.isNotEmpty ? rawAgentId : event.agentId.trim();
    final allSessions = event.data['all_sessions'] == true;
    final rawReadAt = event.data['read_at'];
    final readAt = (rawReadAt is int && rawReadAt > 0)
        ? DateTime.fromMillisecondsSinceEpoch(rawReadAt, isUtc: true)
        : null;

    if (allSessions && agentId.isNotEmpty) {
      await db.markAllAgentChannelsAsRead(
        agentId,
        beforeOrAt: readAt,
        syncToHost: false,
      );
    }

    final raw = (event.data['channel_id'] as String?)?.trim() ?? '';
    final primaryId = raw.isNotEmpty ? raw : event.channelId.trim();
    final ids = <String>{
      if (primaryId.isNotEmpty) primaryId,
      for (final item in (event.data['channel_ids'] as List?) ?? const [])
        if (item is String && item.trim().isNotEmpty) item.trim(),
    };
    for (final channelId in ids) {
      final bare = remoteSessionIdFromChannelId(channelId) ?? channelId;
      final psess = syncedPeerChannelId(bare);
      await db.markChannelMessagesAsRead(bare, syncToHost: false);
      if (psess != bare) {
        await db.markChannelMessagesAsRead(psess, syncToHost: false);
      }
      _notify(bare);
      if (psess != bare) _notify(psess);
    }
  }

  Future<void> _showInteraction(String peerId, HubEvent event) =>
      _renderInteraction(
        peerId: peerId,
        channelId: event.channelId,
        agentId: event.agentId,
        turnId: event.data['turn_id'] as String? ?? '',
        interactionId: event.data['interaction_id'] as String? ?? '',
        kind: event.data['interaction_type'] as String? ?? '',
        body: event.data['data'],
      );

  /// 把一张交互卡渲染成消息。两个入口共用：hub 的 `interaction.pending`
  /// 事件，和重连续传时补发回来的卡片（`pouch_turn_event kind=interaction`）。
  /// 后者载荷里的 `data` / `interaction_type` / `interaction_id` 与前者同形，
  /// 所以「答」的路径（`hub_interaction` 元数据 → `pouch_interaction_resp`）
  /// 不用区分来源。
  Future<void> _renderInteraction({
    required String peerId,
    required String channelId,
    required String agentId,
    required String interactionId,
    required String kind,
    required Object? body,
    String turnId = '',
  }) async {
    final data = body;
    final payload =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    if (kind == 'client_cli') {
      final target = payload['target_fingerprint'] as String? ?? '';
      final mine = (await NoiseIdentity.loadOrCreate()).fingerprintHex;
      if (target.isNotEmpty && mine == target) {
        final output = await CliExecutionGate.instance.execute(
          args: {
            'namespace': payload['namespace'] ?? 'os',
            'subcommand': payload['subcommand'] ?? '',
            'flags': payload['flags'] is Map
                ? Map<String, dynamic>.from(payload['flags'] as Map)
                : <String, dynamic>{},
          },
          agentId: 'she-builtin-agent-001',
          // 归属会话：卡要落在这条 peer 会话里，不能落到用户正在看的会话。
          channelId: channelId,
        );
        await _send(peerId, {
          'type': 'pouch_interaction_resp',
          'interaction_id': interactionId,
          'result': {'output': output},
        });
        return;
      }
    }
    if (!getIt.isRegistered<LocalDatabaseService>() || channelId.isEmpty) {
      return;
    }
    final metadata = <String, dynamic>{
      'hub_interaction': {
        'host_peer_id': peerId,
        'interaction_id': interactionId,
        'interaction_type': kind,
        if (turnId.isNotEmpty) 'turn_id': turnId,
      },
    };
    if (kind == 'action_confirmation' ||
        kind == 'single_select' ||
        kind == 'multi_select' ||
        kind == 'form') {
      metadata[kind] = payload;
    }
    final prompt =
        payload['prompt'] as String? ?? payload['title'] as String? ?? '';
    await getIt<LocalDatabaseService>().createMessage(
      id: hubCardMessageId(interactionId),
      channelId: channelId,
      senderId: agentId.isEmpty ? 'she-builtin-agent-001' : agentId,
      senderType: 'agent',
      senderName: '惜宝',
      content: kind == 'client_cli' ? '在另一台设备上执行' : prompt,
      metadata: metadata,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (turnId.isNotEmpty) {
      (_turnCards[turnId] ??= <String>{}).add(interactionId);
    }
    _notify(channelId);
  }

  /// 交互卡在本地的那条消息 id。渲染和作废都按它找，免得两处各写一份走样。
  static String hubCardMessageId(String interactionId) =>
      'hub-ix-$interactionId';

  /// 主机宣布这个交互结束了：别处作答、等不到回答（30 分钟）、回合取消、
  /// 或主机重启时还悬着。
  ///
  /// 以前这条只当成一条通知丢掉，卡片就一直可点。可点是骗人的：记录已从
  /// `PhoneState` 摘掉，再点 `pouch_interaction_resp` 到了主机直接被扔
  /// （`complete_interaction` 返回 false），而本地照样把用户的选择记成已生效。
  /// 所以把卡片按作废态收起来 —— 和直连路径的 `agent_interaction_closed` 同理。
  Future<void> _onInteractionResolved(HubEvent event) async {
    final interactionId = event.data['interaction_id'] as String? ?? '';
    if (interactionId.isEmpty) return;
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final by = event.data['by'] as String? ?? '';
    await _closeHubCard(interactionId, _hubClosedReason(by));
  }

  /// `by` 是主机给的理由，或者是作答那台设备的 peer id。
  ///
  /// 超时那条复用直连路径的文案；主机重启意味着这个回合没了，按「回合已结束」
  /// 说。剩下的（一个 peer id）就是有设备答了 —— 可能是另一台。
  static String _hubClosedReason(String by) {
    switch (by) {
      case 'timeout':
        return 'timeout';
      case 'cancelled':
        return 'cancelled';
      case 'hub_restart':
        return 'turn_ended';
      default:
        return 'answered_elsewhere';
    }
  }

  Future<void> _closeHubCard(String interactionId, String reason) async {
    final db = getIt<LocalDatabaseService>();
    final messageId = hubCardMessageId(interactionId);
    final row = await db.getMessageById(messageId);
    if (row == null) return;
    final raw = row['metadata'];
    if (raw is! String || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final metadata = Map<String, dynamic>.from(decoded);
    final hub = metadata['hub_interaction'];
    final kind = hub is Map ? hub['interaction_type']?.toString() ?? '' : '';
    final data = metadata[kind];
    if (kind.isEmpty || data is! Map) return;
    // 本地已经有裁决就不动它。自己那一下点击主机也会广播一条
    // `interaction.resolved` 回来，别把自己刚答的卡盖成「作废」。
    // 四种卡的裁决键各不相同，都得认（见各自的气泡 widget）。
    if (data['selected_action_id'] != null ||
        data['selected_option_id'] != null ||
        data['selected_option_ids'] != null ||
        data['submitted_values'] != null) {
      return;
    }
    if (data['closed'] != null) return;
    metadata[kind] = Map<String, dynamic>.from(data)..['closed'] = reason;
    await db.updateMessageMetadata(messageId, metadata);
    final channelId = row['channel_id'] as String? ?? '';
    if (channelId.isNotEmpty) _notify(channelId);
  }

  /// 主机 `open_direct_gate` 往 run 级惜宝会话写的 gate / 通知消息也带
  /// `metadata.flow`（H10-12 只给最终 agent 回复带 `turn_id`），但它不代表
  /// 回合结束（A10-5）。消息里任何明确的 gate / notice 标记都按通知处理：
  /// 不删占位、不收尾 live turn。
  static bool _isFlowNoticeMessage(Map<String, dynamic> data) {
    final meta = data['metadata'];
    if (meta is! Map) return false;
    final flow = meta['flow'];
    if (flow is Map) {
      for (final key in const [
        'gate',
        'notice',
        'notification',
        'is_gate',
        'is_notice',
        'kind',
        'type',
        'message_type',
      ]) {
        final value = flow[key];
        if (value == null || value == false) continue;
        if (key == 'gate' || key == 'notice' || key == 'notification') {
          return true;
        }
        if (key == 'is_gate' || key == 'is_notice') {
          if (value == true || value == 1) return true;
          continue;
        }
        final text = value.toString().toLowerCase();
        if (text.contains('gate') || text.contains('notice')) return true;
      }
    }
    for (final key in const ['gate', 'notice', 'notification']) {
      final value = meta[key];
      if (value != null && value != false) return true;
    }
    final kind = meta['kind']?.toString().toLowerCase() ?? '';
    return kind == 'gate' ||
        kind == 'notice' ||
        kind == 'notification' ||
        kind.contains('gate') ||
        kind.contains('notice');
  }

  /// 主机在回合中途 append 的工具结果 / 进度消息：带 progress_* / tool_*
  /// metadata，或者干脆不是 text 类型。它不代表回合结束（A7-5）。
  static bool _isIntermediateAgentMessage(Map<String, dynamic> data) {
    final meta = data['metadata'];
    if (meta is Map) {
      final flow = meta['flow'];
      final notice = _isFlowNoticeMessage(data);
      // A8-4：流程节点回合的最终回复也带 metadata.flow，哪怕同时带进度块，
      // 也不能被当成回合中途的消息。但 gate / notice 不是最终回复，必须继续
      // 判成中途通知（A10-5）。
      if (flow is Map && !notice) return false;
      for (final key in const [
        'progress_content',
        'progress_steps',
        'progress_title',
        'tool_status',
        'tool_result',
        'tool_call',
      ]) {
        if (meta[key] != null) return true;
      }
      final kind = meta['kind']?.toString() ?? '';
      if (kind == 'progress' || kind == 'tool_result' || kind == 'thinking') {
        return true;
      }
      if (meta['status'] == 'progress') return true;
      if (notice) return true;
    }
    final type = (data['type'] as String? ?? '').toLowerCase();
    return type.isNotEmpty && type != 'text';
  }

  /// 这一回合的最终回复：主机 append 时带 `metadata.flow`，id 是
  /// `peerhist_*` 形态。只有它能把「已收尾保留的半成品占位」换成完整答案。
  ///
  /// 来源 / 类型先于 progress 字段判定：工具回合的最终消息也会带
  /// `progress_content` / `progress_steps`，按中途消息处理会让保留占位和完整
  /// 答案并存成两条气泡（A8-4）。没有这两种最终标记的进度消息仍由
  /// [_isIntermediateAgentMessage] 判成中途消息。gate / 通知消息一律不算
  /// 最终回复（A10-5）。
  static bool _isFinalAnswerMessage(Map<String, dynamic> data) {
    if (_isFlowNoticeMessage(data)) return false;
    final meta = data['metadata'];
    if (meta is Map && meta['flow'] is Map) return true;
    final id = data['id'] as String? ?? '';
    if (!id.startsWith('peerhist_')) return false;
    // 非 text 的 peerhist_ 行（工具结果等）仍是回合中途的消息。
    final type = (data['type'] as String? ?? '').toLowerCase();
    return type.isEmpty || type == 'text';
  }

  /// 占位行是不是「idle 超时收尾后保留下来的正文」（A7-1）。
  static bool _placeholderIsFinalized(Object? metadata) {
    if (metadata is! String || metadata.isEmpty) return false;
    try {
      final decoded = jsonDecode(metadata);
      return decoded is Map && decoded['finalized'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _insertMessage(String peerId, HubEvent event) async {
    final data = event.data;
    final id = data['id'] as String? ?? '';
    final rawChannelId =
        (data['channel_id'] as String?)?.trim().isNotEmpty == true
            ? data['channel_id'] as String
            : event.channelId;
    if (id.isEmpty || rawChannelId.isEmpty) return;
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final db = getIt<LocalDatabaseService>();
    final from = data['from'];
    final sender = from is Map ? Map<String, dynamic>.from(from) : const {};
    final senderType = sender['type'] as String? ?? 'agent';
    final metadata = data['metadata'];
    final target = await _resolveHubTarget(
      peerId,
      event,
      senderType: senderType,
      fallbackSenderId: sender['id'] as String?,
      fallbackSenderName: sender['name'] as String? ?? '',
    );
    final channelId = target.channelId;
    // 用户消息的本机 id 就是 peerhist_ 后面那段。助手回复的本机副本是另一个
    // uuid，只在 metadata.request_id 上和这次回放是同一轮，也要一起收掉，
    // 否则终态落库和 message.created 会各留一条气泡。
    final eventMetadata =
        metadata is Map ? Map<String, dynamic>.from(metadata) : null;
    // 这条事件自己的 id 形态就是本通道的落库形态：agent 会话是 `peerhist_*`，
    // 惜宝单聊与群聊是裸 id。引用要按同一形态存，否则指向一条不存在的行。
    final hostWrapsIds = id.startsWith('peerhist_');
    final localRows = hostWrapsIds
        ? await db.listNonPeerhistMessages(channelId)
        : const <Map<String, dynamic>>[];
    final collapse = collapseLocalPeerTurnOnPeerhistInsert(
      peerhistId: id,
      eventMetadata: eventMetadata,
      localRows: [
        for (final row in localRows)
          (
            id: row['id'] as String? ?? '',
            metadataJson: row['metadata'] as String?,
          ),
      ],
    );
    final existing = await db.getMessageById(id);
    if (existing != null) {
      await _keepProgressOnExistingPeerhist(
        db,
        existing,
        collapse.metadata,
      );
    }
    await db.deleteMessagesByIds(collapse.deleteIds);
    // 删掉的那条裸 id 行就是 `peerhist_<id>` 的本机形态，指向它的引用要跟着
    // 搬过去，否则助手气泡上的引用头会变成「原消息不可用」。
    for (final rewrite in collapse.replyToRewrites) {
      await db.rewriteReplyToIds(channelId, rewrite.from, rewrite.to);
    }
    if (existing == null) {
      final isRead = (data['is_read'] == true ||
              data['is_read'] == 1 ||
              senderType != 'agent' ||
              AppLifecycleService().shouldSuppressNotification(channelId))
          ? 1
          : 0;
      try {
        await db.createMessage(
          id: id,
          channelId: channelId,
          senderId: target.senderId,
          senderType: senderType,
          senderName: target.senderName,
          content: data['content'] as String? ?? '',
          messageType: data['type'] as String? ?? 'text',
          metadata: collapse.metadata,
          replyToId: replyToIdInLocalForm(
            data['reply_to'] as String?,
            hostWrapsIds: hostWrapsIds,
          ),
          createdAt: data['timestamp'] is int && data['timestamp'] != 0
              ? DateTime.fromMillisecondsSinceEpoch(
                  data['timestamp'] as int,
                  isUtc: true,
                )
              : null,
          isRead: isRead,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } catch (error) {
        _log.warning('message.created skipped: $error', tag: 'HubEvent');
        return;
      }
    }
    final rawTs = data['timestamp'];
    if (rawTs is int && rawTs > 0) {
      await db.setChannelUpdatedAt(
        channelId,
        DateTime.fromMillisecondsSinceEpoch(rawTs, isUtc: true),
      );
    }
    // gate / notice 消息带 metadata.flow 但不是回合回复：不动占位 / live turn，
    // 也不触发占位扫描（A10-5）。
    if (senderType != 'user' && !_isFlowNoticeMessage(data)) {
      final liveTurns = _liveChannels.entries
          .where((entry) => entry.value == channelId)
          .map((entry) => entry.key)
          .toList();
      // A8-4：最终 agent 回复即便带 progress 元数据也不能按中途消息处理，
      // 否则已收尾保留的占位不会被删，出现「半段 + 完整」两条答案。
      final finalAnswer = _isFinalAnswerMessage(data);
      final intermediate = !finalAnswer && _isIntermediateAgentMessage(data);
      // A9-2 / A10-4：消息明确带回合归属时，只收那一个回合的 live turn / 占位。
      final attributedTurn = _messageTurnId(data);
      // 老主机帧没有 turn_id / metadata.flow.turn_id。频道里有多个 live turn
      // 时这条回复归谁根本判不出来：整批收尾会误伤另一个还在跑的回合，
      // 连占位扫描也一起跳过，由它自己的最终帧 / idle / turn.finished 收尾。
      final ambiguousLiveTurns = attributedTurn == null && liveTurns.length > 1;
      final targets = ambiguousLiveTurns
          ? const <String>[]
          : liveTurns
              .where((turnId) =>
                  attributedTurn == null || turnId == attributedTurn)
              .toList();
      var clearedLiveTurn = false;
      for (final turnId in targets) {
        if (intermediate) {
          // A7-5：工具结果 / 进度消息只删占位行，绝不结束回合。删掉
          // _attached / 标记 settled 会让后续 pouch_turn_event / agent_chunk
          // 全被丢掉，回复从中间截断。
          await _clearIntermediatePlaceholder(turnId);
          continue;
        }
        // 最终回复才做完整清理：占位行、缓冲、落点缓存一起收掉。
        // 和 idle / turn.finished 走同一条路径，只删占位的话
        // _flowPlaceholders 会永远留着这个 turnId，后续同回合 chunk
        // 建不出占位、集合也无限增长。
        clearedLiveTurn = true;
        await _clearLiveTurn(turnId, closeCards: false);
      }
      // A9-9 / A10-10：flow 频道也不再无条件扫库。只在确实见过占位前缀、
      // 刚清掉一个 live 回合、或该频道已登记过 live/finalized 占位时才扫；
      // 其余长历史重放连 hydration 都不必等（start() 已重建过一次）。
      final knownPlaceholderPrefix =
          id.startsWith(liveTurnPlaceholderPrefix) || liveTurns.isNotEmpty;
      final shouldScan = !ambiguousLiveTurns &&
          (clearedLiveTurn ||
              knownPlaceholderPrefix ||
              _channelsWithLivePlaceholders.contains(channelId));
      if (shouldScan) {
        // A9-4：重登 / dispose 之后 retain 集合是空的，先从库里重建一次（只一次）。
        await _ensurePlaceholderHydrated();
        debugLivePlaceholderScans++;
        final placeholderIds = await db.listLiveTurnPlaceholderIds(channelId);
        final livePlaceholders = {
          for (final id in _liveChannels.keys) liveTurnPlaceholderId(id),
        };
        var remaining = 0;
        for (final placeholderId in placeholderIds) {
          if (livePlaceholders.contains(placeholderId)) {
            remaining++;
            continue;
          }
          final idTurn = placeholderId.startsWith(liveTurnPlaceholderPrefix)
              ? placeholderId.substring(liveTurnPlaceholderPrefix.length)
              : '';
          if (attributedTurn != null &&
              idTurn.isNotEmpty &&
              idTurn != attributedTurn) {
            remaining++;
            continue;
          }
          // A9-4：任何删除之前都查 DB 的 finalized 标记，不只 intermediate 分支。
          final row = await db.getMessageById(placeholderId);
          final retained =
              (idTurn.isNotEmpty && _finalizedRetainedTurns.contains(idTurn)) ||
                  _placeholderIsFinalized(row?['metadata']);
          if (retained) {
            // A9-2：retained 的半段回答只能由「它自己那一回合」的最终回复
            // 换掉。带不出归属时只在这条频道里仅剩它一个占位、且没有别的
            // live 回合被收掉时才认为属于本回合；否则一律保留。
            final ownFinalAnswer = finalAnswer &&
                (attributedTurn != null ||
                    (!clearedLiveTurn &&
                        liveTurns.isEmpty &&
                        placeholderIds.length == 1));
            if (!ownFinalAnswer) {
              remaining++;
              continue;
            }
          }
          await db.deleteMessage(placeholderId);
          if (idTurn.isNotEmpty) {
            _finalizedRetainedTurns.remove(idTurn);
            // A6-6：占位行是 `hub-live-<turnId>`。重启后内存里的回合索引已经
            // 没了，光删行不够——同一 turn 的迟到 chunk 会把它当新回合再建一个
            // 永久 streaming 占位。把从 id 反解出来的 turnId 记成 settled（同样
            // 有界），迟到帧才会在 [_onFlowControlChunk] 入口被丢掉。
            _markSettledTurn(idTurn);
          }
        }
        if (remaining == 0) _channelsWithLivePlaceholders.remove(channelId);
      }
    }
    _notify(channelId);
  }

  Future<void> _keepProgressOnExistingPeerhist(
    LocalDatabaseService db,
    Map<String, dynamic> existing,
    Map<String, dynamic>? incoming,
  ) async {
    Map<String, dynamic>? existingMeta;
    final raw = existing['metadata'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          existingMeta = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    final merged = peerProgressMetadataToMerge(
      existing: existingMeta,
      incoming: incoming,
    );
    final messageId = existing['id'] as String?;
    if (merged == null || messageId == null || messageId.isEmpty) return;
    await db.updateMessageMetadata(messageId, merged);
  }

  Future<void> _updateMessage(HubEvent event) async {
    final id = event.data['id'] as String? ?? '';
    if (id.isEmpty || !getIt.isRegistered<LocalDatabaseService>()) return;
    final content = event.data['content'];
    final metadata = event.data['metadata'];
    if (content is! String) return;
    final db = getIt<LocalDatabaseService>();
    var next = metadata is Map ? Map<String, dynamic>.from(metadata) : null;
    if (next != null) {
      final existing = await db.getMessageById(id);
      next = metadataPreservingProgress(
        incoming: next,
        existingMetadataJson: existing?['metadata'] as String?,
      );
    }
    await db.updateMessage(
      messageId: id,
      content: content,
      metadata: next,
    );
    if (event.channelId.isNotEmpty) _notify(event.channelId);
  }

  Future<void> _onTurnStarted(String peerId, HubEvent event) async {
    final turnId = event.data['turn_id'] as String? ?? '';
    final rawChannelId =
        (event.data['channel_id'] as String?)?.trim().isNotEmpty == true
            ? event.data['channel_id'] as String
            : event.channelId;
    if (turnId.isEmpty || rawChannelId.isEmpty) return;
    final watching = watchingTurn?.call(turnId) ??
        PouchTurnRelay.instance.isWatching(turnId);
    if (watching) return;
    // 落库消息走 prepareLocalTarget，会把主机频道折到本机正在看的
    // psess_ 壳上。占位若仍写主机原频道，打开的聊天页只有用户消息，
    // 回复要等整段落盘才出现。
    final target = await _resolveHubTarget(peerId, event);
    final channelId =
        target.channelId.isEmpty ? rawChannelId : target.channelId;
    // A9-5：主机瞬态重试会重放 turn.started 且 turn_id 不变；上一代已经
    // settled，必须把这一回合重新激活，否则重试的 chunk 全被丢掉。
    _reactivateSettledTurn(turnId);
    _reactivateOnNewAttempt(turnId, event.data);
    _attached.add(turnId);
    _liveChannels[turnId] = channelId;
    _liveBuffers[turnId] = '';
    _liveTurnTokens[turnId] = Object();
    // A7-3：turn.started 起的占位同样要有兜底收尾计时器（done / idle 丢了
    // 也不能永远 streaming）。
    _scheduleFinalize(turnId);
    if (getIt.isRegistered<LocalDatabaseService>()) {
      final senderId = target.senderId.isEmpty
          ? (event.agentId.isEmpty ? 'she' : event.agentId)
          : target.senderId;
      await getIt<LocalDatabaseService>().createMessage(
        id: liveTurnPlaceholderId(turnId),
        channelId: channelId,
        senderId: senderId,
        senderType: 'agent',
        senderName: target.senderName,
        content: '',
        metadata: const {'status': 'streaming'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      _markPlaceholderChannel(channelId);
      _placeholderSenders[turnId] =
          (senderId: senderId, senderName: target.senderName);
      _notify(channelId);
    }
    final attachRequestId = _uuid.v4();
    _attachRequests.removeWhere((_, id) => id == turnId);
    _attachRequests[attachRequestId] = turnId;
    final sent = await _send(peerId, {
      'type': 'turn_attach_req',
      'request_id': attachRequestId,
      'turn_id': turnId,
      'known_content_length': 0,
    });
    if (!sent) _attachRequests.remove(attachRequestId);
  }

  /// 清掉一个回合在本机留下的所有临时状态。占位行和卡片都要收掉，
  /// 否则回合早没了却还挂着一个 streaming 气泡。
  ///
  /// [deletePlaceholder] 为 false 时保留占位行本身（idle 超时收尾用：正文
  /// 已经显示了，不能因为主机没发最终消息就把它删掉）。
  ///
  /// [closeCards] 为 false 时只清占位 / 缓冲，不动这个回合问过的交互卡。
  /// `message.created` 的清理走这条：一条 agent 消息不代表回合结束，主机
  /// 可能还停在 `ask_ui` 等用户作答，提前关掉卡片会让用户答不了。
  Future<String?> _clearLiveTurn(
    String turnId, {
    bool deletePlaceholder = true,
    bool closeCards = true,
  }) async {
    // 先登记「已收尾」：任何在 await 期间 / 之后到达的迟到 chunk 都不能再
    // 把这个回合当成新回合重建占位。
    _markSettledTurn(turnId);
    _finalizeDeadlines.remove(turnId);
    _ensureFinalizeTimer();
    _idleSeenTurns.remove(turnId);
    _attached.remove(turnId);
    _flowPlaceholders.remove(turnId);
    _liveTurnTokens.remove(turnId);
    _attachRequests.removeWhere((_, id) => id == turnId);
    _liveBuffers.remove(turnId);
    _liveDirty.remove(turnId);
    _forgetFlowTargets(turnId);
    _placeholderSenders.remove(turnId);
    _suppressRebuildTurns.remove(turnId);
    final channelId = _liveChannels.remove(turnId);
    // A7-1 / A9-4：idle 超时收尾保留的半成品回答不能被迟到的 turn.finished /
    // attach-lost / 重登后的无关消息删掉。内存集合可能丢过，DB 的 finalized
    // 标记才是持久依据；只有最终回复（见 [_insertMessage]）才收它。
    if (deletePlaceholder &&
        turnId.isNotEmpty &&
        getIt.isRegistered<LocalDatabaseService>() &&
        !await _isRetainedPlaceholder(turnId)) {
      await getIt<LocalDatabaseService>()
          .deleteMessage(liveTurnPlaceholderId(turnId));
    }
    if (closeCards) await _closeTurnCards(turnId);
    return channelId;
  }

  /// 中途的进度 / 工具结果消息只删占位行：回合还在跑，_attached /
  /// _liveChannels / 已拼正文 / 落点缓存 / 收尾计时器一律保留，后续 chunk
  /// 才能接着拼进同一个回复（A7-5）。删掉的行由 [_flushLiveTurn] 或下一片
  /// chunk 按 [_placeholderSenders] 重建。
  Future<void> _clearIntermediatePlaceholder(String turnId) async {
    if (await _isRetainedPlaceholder(turnId)) return;
    _flowPlaceholders.remove(turnId);
    _liveDirty.remove(turnId);
    _suppressRebuildTurns.add(turnId);
    if (turnId.isNotEmpty && getIt.isRegistered<LocalDatabaseService>()) {
      await getIt<LocalDatabaseService>()
          .deleteMessage(liveTurnPlaceholderId(turnId));
    }
  }

  Future<void> _onTurnFinished(HubEvent event) async {
    final turnId = event.data['turn_id'] as String? ?? '';
    final channelId = await _clearLiveTurn(turnId);
    if (channelId != null) _notify(channelId);
  }

  /// 主机回过 `agent_error`（`end_reason: "lost"`）：回合已经不在，attach 白等了。
  /// `request_id` 是当初 `turn_attach_req` 的 id，用 [_attachRequests] 认领。
  Future<void> _onAttachLost(Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final turnId = _attachRequests[requestId];
    if (turnId == null) return;
    final channelId = await _clearLiveTurn(turnId);
    if (channelId != null) _notify(channelId);
  }

  /// 回合结束了，这个回合问过的、还没答的卡片一律收起可点态。
  ///
  /// 正常顺序下主机先发 `interaction.resolved`、再结束回合（`ask_ui` 是阻塞的），
  /// 所以这一步平时是空转 —— 它兜的是那帧没到手的情况（事件日志被裁、游标丢了、
  /// 或补发/作废的先后被打乱）。不兜的话卡片会一直可点，而回合早没了。
  Future<void> _closeTurnCards(String turnId) async {
    final cards = _turnCards.remove(turnId);
    if (cards == null || cards.isEmpty) return;
    for (final interactionId in cards) {
      await _closeHubCard(interactionId, 'turn_ended');
    }
  }

  Future<void> _onAttachedChunk(
      String peerId, Map<String, dynamic> data) async {
    final turnId = data['request_id'] as String? ?? '';
    if (!_attached.contains(turnId)) return;
    final kind = data['kind'];
    // A9-6：attached DM 回合的 40s 工具调用可能只有 metadata / interaction
    // 帧，没有 chunk。A8-1 只给 flow metadata 刷了计时器，30s 兜底一到就把
    // 回合收尾并移除 _attached，后续 chunk 全丢。任何「回合还活着」的帧都
    // 刷新兜底窗口（done / error 是终态，不用再刷）。
    if (kind != 'done' && kind != 'error') {
      _scheduleFinalize(turnId);
    }
    if (kind == 'interaction') {
      // 主机在我们断线时问的问题：重连续传时补发回来（宿主侧
      // PhoneState::pending_interaction_for_turn → LiveTurns::attach）。
      // 不渲染的话只能等主机自己放弃（30 分钟），用户连「被问过」都不知道。
      final channelId = _liveChannels[turnId];
      if (channelId == null) return;
      await _renderInteraction(
        peerId: peerId,
        channelId: channelId,
        agentId: data['agent_id'] as String? ?? '',
        turnId: turnId,
        interactionId: data['interaction_id'] as String? ?? '',
        kind: data['interaction_type'] as String? ?? '',
        body: data['data'],
      );
      return;
    }
    if (data['kind'] == 'chunk') {
      final chunk = data['chunk'] as String? ?? '';
      // A7-3 / A9-6：还在出字就把兜底 / idle 收尾窗口刷新回完整时长
      // （上面的统一刷新已经做过，这里不再重复装）。
      _suppressRebuildTurns.remove(turnId);
      _liveBuffers[turnId] = (_liveBuffers[turnId] ?? '') + chunk;
      if (_liveChannels[turnId] == null ||
          !getIt.isRegistered<LocalDatabaseService>()) {
        return;
      }
      // 逐 chunk 落库会把「已累积全文」重写一遍（O(n²)），还要每帧通知
      // 整列重拉。只记脏，按 [_liveFlushInterval] 合并写出。
      _scheduleLiveFlush(turnId);
    }
    if (data['kind'] == 'done' || data['kind'] == 'error') {
      _attached.remove(turnId);
      // 收尾前把还没落库的尾巴补上，别把最后几个 chunk 丢了。
      await _flushLiveTurn(turnId);
      // 续传的回合就这样结束了 —— 补发回来的卡片同样不能留着可点。
      await _closeTurnCards(turnId);
      if (data['kind'] == 'error') {
        // 错误没有后续 turn.finished 兜底时，占位会永远停在 streaming。
        final channelId = await _clearLiveTurn(turnId);
        if (channelId != null) _notify(channelId);
      } else {
        _attachRequests.removeWhere((_, id) => id == turnId);
      }
    }
  }

  /// 续传回合的待落库 turnId。落库在 [_flushLiveTurn] 时才读 buffer，
  /// 因此中途被 _onTurnFinished / _cleanupLiveTurns 清掉的回合自然跳过。
  final _liveDirty = <String>{};
  Timer? _liveFlushTimer;

  void _scheduleLiveFlush(String turnId) {
    _liveDirty.add(turnId);
    _liveFlushTimer ??= Timer(_liveFlushInterval, () {
      _liveFlushTimer = null;
      unawaited(_flushLiveDirty());
    });
  }

  Future<void> _flushLiveDirty() async {
    final turnIds = _liveDirty.toList();
    _liveDirty.clear();
    for (final turnId in turnIds) {
      await _flushLiveTurn(turnId);
    }
  }

  Future<void> _flushLiveTurn(String turnId) async {
    _liveDirty.remove(turnId);
    final content = _liveBuffers[turnId];
    final channelId = _liveChannels[turnId];
    if (content == null || channelId == null) return;
    try {
      final db = getIt<LocalDatabaseService>();
      final messageId = liveTurnPlaceholderId(turnId);
      final existing = await db.getMessageById(messageId);
      if (existing == null) {
        // 中途进度消息删过占位、但之后没有新 chunk：那条消息可能就是最终回复，
        // 不能凭旧缓冲把占位重新建出来。
        if (_suppressRebuildTurns.contains(turnId)) return;
        // 中途进度消息删过占位行：下一片 chunk 要按原来的 sender 把它建回来，
        // 并把之前累积的正文一起写进去（A7-5）。回合已完整收尾时 sender 记录
        // 不在，迟到 chunk 不该重建出永久 streaming 占位。
        final sender = _placeholderSenders[turnId];
        if (sender == null) return;
        await db.createMessage(
          id: messageId,
          channelId: channelId,
          senderId: sender.senderId,
          senderType: 'agent',
          senderName: sender.senderName,
          content: content,
          metadata: const {'status': 'streaming'},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        _markPlaceholderChannel(channelId);
      } else {
        await db.updateMessage(messageId: messageId, content: content);
      }
      _notify(channelId);
    } catch (e) {
      _log.warning('live turn flush failed: $e', tag: 'HubEvent');
    }
  }

  /// 是不是 P4 工作流节点回合的裸控制帧。
  ///
  /// 主机给这些帧带了 `run_id` / `node`，turn id 是 `flow-` 前缀，频道是
  /// `psess_<flow_...>`。四个标记认一个就够，避免误接普通 DM / 群回合的
  /// `agent_chunk`（那些由 PeerAgentClientService 按 _pending 处理）。
  bool _isFlowRuntimeFrame(Map<String, dynamic> data) {
    String text(String key) => data[key]?.toString() ?? '';
    if (text('turn_id').startsWith('flow-') ||
        text('request_id').startsWith('flow-')) {
      return true;
    }
    if (text('run_id').isNotEmpty) return true;
    if (text('channel_id').startsWith('${kSyncedPeerSessionPrefix}flow_')) {
      return true;
    }
    final sessionKey = text('session_key');
    return sessionKey.startsWith('flow_') || sessionKey.contains(':flow_');
  }

  /// 和 `message.created` 用同一套映射折到本地频道：顺手建好还没同步下来的
  /// `psess_` 壳和 agent 行，流式占位才不会落到一个空频道上。
  Future<({String channelId, String senderId, String senderName})>
      _resolveFlowControlTarget(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    final rawChannelId = (data['channel_id'] as String? ?? '').trim();
    if (rawChannelId.isEmpty) {
      return (channelId: '', senderId: '', senderName: '');
    }
    debugFlowControlTargetResolves++;
    final rawSessionId = (data['session_id'] as String? ?? '').trim();
    final sessionId = rawSessionId.isNotEmpty
        ? rawSessionId
        : (remoteSessionIdFromChannelId(rawChannelId) ?? rawChannelId);
    final agentId = (data['agent_id'] as String? ?? '').trim();
    return PeerAgentClientService.instance.prepareLocalTargetForHubMessage(
      peerId: peerId,
      remoteAgentId: agentId,
      sessionId: sessionId,
      rawChannelId: rawChannelId,
      senderType: 'agent',
      fallbackSenderId: agentId,
      fallbackSenderName: '',
      sessionTitle: data['session_title'] as String?,
    );
  }

  /// 取（必要时解析并缓存）一个回合的落点。
  ///
  /// 只有 `channelId` 和 `senderId` 都解析出来才写缓存：缺 `agent_id` 的帧
  /// 会落到「裸 channel + 空 sender」的兜底结果，缓存它会让同回合后续真正
  /// 带 `agent_id` 的 chunk 全部复用兜底值 —— 占位写到裸 `flow_…`、没有
  /// sender、本地壳也建不出来。兜底结果用完即弃，下一帧重新解析。
  Future<({String channelId, String senderId, String senderName})>
      _flowTargetFor(
    String peerId,
    String turnId,
    Map<String, dynamic> data,
  ) async {
    final key = _flowTargetKey(peerId, turnId);
    final cached = _flowTargets[key];
    if (cached != null) {
      final target = await cached;
      if (_isCompleteFlowTarget(target)) return target;
      // 之前缓存的是兜底结果：别再复用，重新解析这一帧。
      if (identical(_flowTargets[key], cached)) _flowTargets.remove(key);
    }
    final future = _resolveFlowControlTarget(peerId, data);
    _flowTargets[key] = future;
    final target = await future;
    if (!_isCompleteFlowTarget(target) &&
        identical(_flowTargets[key], future)) {
      _flowTargets.remove(key);
    }
    return target;
  }

  bool _isCompleteFlowTarget(
    ({String channelId, String senderId, String senderName}) target,
  ) =>
      target.channelId.isNotEmpty && target.senderId.isNotEmpty;

  /// 节点回合的 `agent_chunk`：按 channel_id 起一条本机流式占位，逐帧拼正文。
  /// 主机结束时会 append 一条 `agent` 消息，`_insertMessage` 会把占位收掉，
  /// 所以这里只管「运行中能实时看到字」。
  Future<void> _onFlowControlChunk(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    if (!_isFlowRuntimeFrame(data)) return;
    final turnId = (data['turn_id'] ?? data['request_id'] ?? '').toString();
    final rawChannelId = (data['channel_id'] as String? ?? '').trim();
    if (turnId.isEmpty || rawChannelId.isEmpty) return;
    // A9-5：主机瞬态重试会重放 begin_turn 且 turn_id 不变。带新 attempt /
    // generation（或明确的 begin_turn）的帧要先把这个回合从 settled 里激活；
    // 帧里没有 attempt 时靠 turn.started / running session.state 帧激活。
    _reactivateOnNewAttempt(turnId, data);
    // 收尾过的回合再来迟到 chunk：不能把它当成新回合重新建占位。
    if (_isSettledFlowTurn(turnId)) return;
    _noteFlowActivity(data, rawChannelId);
    // `content` 是新字段，`text` / `chunk` 是主机旧帧里的别名。
    final content =
        (data['content'] ?? data['text'] ?? data['chunk'] ?? '').toString();
    // 先在没有 await 的同步段里按顺序拼正文：解析本地频道壳是异步的，
    // 完成的先后不保证，放到 await 之后会把分片拼反。
    final isNewTurn = !_liveChannels.containsKey(turnId);
    if (isNewTurn) {
      _attached.add(turnId);
      _liveChannels[turnId] = rawChannelId;
      _liveBuffers[turnId] = '';
    }
    // 回合登记代次：await 回来时用它判断这一轮是否已经被终态 / 超时收尾清掉。
    _liveTurnTokens.putIfAbsent(turnId, () => Object());
    final token = _liveTurnTokens[turnId];
    // A7-3：第一个 chunk 建立占位时就装兜底计时器（idle 是广播-only，丢了
    // 就再也不会有收尾信号）；之后每片 chunk 都刷新它，并且**必须重新装回**。
    // idle 到达后窗口改短，继续出字只是顺延，不会让计时器消失。
    _scheduleFinalize(turnId);
    _suppressRebuildTurns.remove(turnId);
    if (content.isNotEmpty) {
      _liveBuffers[turnId] = (_liveBuffers[turnId] ?? '') + content;
    }
    final gate = debugBeforeFlowChunkResolve;
    if (gate != null) await gate();
    // 同一回合的后续 chunk 复用落点解析：查库 / 建壳只做一次。
    final target = await _flowTargetFor(peerId, turnId, data);
    // 解析期间回合可能已经被终态消息 / 超时收尾清掉。这时不能再把
    // _liveChannels / 占位重新登记回去 —— 否则气泡永远停在 streaming。
    if (token == null || _liveTurnTokens[turnId] != token) return;
    final resolved = _isCompleteFlowTarget(target);
    final channelId = resolved ? target.channelId : rawChannelId;
    _liveChannels[turnId] = channelId;
    // 落点没解析全（缺 agent_id）时先不建占位：兜底 sender 是空的，建出来
    // 之后同 id 的占位没法再补 sender / 频道。等下一帧带 agent_id 再建。
    if (resolved &&
        !_flowPlaceholders.contains(turnId) &&
        getIt.isRegistered<LocalDatabaseService>()) {
      final db = getIt<LocalDatabaseService>();
      final messageId = liveTurnPlaceholderId(turnId);
      // A9-5：重试复用的 turnId 上可能还挂着上一代 `finalized` 的半段回答。
      // 只在重新激活后的第一次建占位时把它改回 streaming，避免新答案带着
      // 「已收尾」标记、之后又被无关消息当成别回合的保留行。
      if (_reactivatedTurns.remove(turnId)) {
        await db.updateMessageMetadata(
          messageId,
          const {'status': 'streaming'},
        );
      }
      await db.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: target.senderId,
        senderType: 'agent',
        senderName: target.senderName,
        content: '',
        metadata: const {'status': 'streaming'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      _flowPlaceholders.add(turnId);
      _markPlaceholderChannel(channelId);
      _placeholderSenders[turnId] =
          (senderId: target.senderId, senderName: target.senderName);
    }
    if (content.isNotEmpty) _scheduleLiveFlush(turnId);
    _notify(channelId);
  }

  /// `agent_metadata` 同样没有 _pending。进度 / thinking 元数据 v1 不画独立
  /// 气泡；带 `agent_id` 时顺便把本地壳建好、把落点解析缓存给同回合的 chunk
  /// 复用（查库 / 建壳很贵，且 metadata 常常先于第一片 chunk 到达）。
  /// 不带 `agent_id` 的帧不解析、不缓存，交给 chunk 处理。
  ///
  /// A8-1：不管带不带 agent_id，它都是回合仍活着的证据 —— 长工具回合可能
  /// 几十秒只发 metadata，兜底收尾计时器必须和 chunk 一样被刷新（重新装回），
  /// 否则 30s 时占位被收尾、后续 chunk 因 settled 被丢，答案截断。
  Future<void> _onFlowControlMetadata(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    if (!_isFlowRuntimeFrame(data)) return;
    final rawChannelId = (data['channel_id'] as String? ?? '').trim();
    final turnId = (data['turn_id'] ?? data['request_id'] ?? '').toString();
    final agentId = (data['agent_id'] as String? ?? '').trim();
    _noteFlowActivity(data, rawChannelId);
    // metadata 帧经常不带 `agent_id`（relay / 主机原生帧只有 request_id +
    // metadata）。拿空 agent_id 解析会把「空 sender、未建壳」的目标缓存进
    // [_flowTargets]，同回合稍后带 agent_id 的 chunk 复用它，占位就没归属了。
    // 这里干脆不解析也不缓存：频道壳等带 agent_id 的 chunk 到了再建。
    if (turnId.isEmpty) {
      if (agentId.isEmpty) return;
      final target = await _resolveFlowControlTarget(peerId, data);
      if (target.channelId.isNotEmpty) _notify(target.channelId);
      return;
    }
    // A9-5：带新 attempt 的 metadata 也是重试的一代，settled 要重新激活。
    _reactivateOnNewAttempt(turnId, data);
    if (_isSettledFlowTurn(turnId)) return;
    _scheduleFinalize(turnId);
    if (agentId.isEmpty) return;
    final target = await _flowTargetFor(peerId, turnId, data);
    if (target.channelId.isNotEmpty) _notify(target.channelId);
  }

  /// 裸 `session.state` 快照：所有字段都在顶层，直接喂给 mirror。
  ///
  /// 绝不伪造 `hub_event` 的 seq —— 那会把事件游标顶到不存在的序号上。
  /// 广播-only（主机标了 TODO），重连靠 `session_snapshot_resp` 对账。
  Future<void> _onRawSessionState(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    if (!_isFlowRuntimeFrame(data)) return;
    final snapshot = Map<String, dynamic>.from(data);
    // 主机两种写法都发：`state` / `status`；mirror 只认 `state`。
    if (snapshot['state'] == null && snapshot['status'] != null) {
      snapshot['state'] = snapshot['status'];
    }
    if ((snapshot['session_key'] as String? ?? '').isEmpty) {
      final channelId = (data['channel_id'] as String? ?? '').trim();
      snapshot['session_key'] =
          remoteSessionIdFromChannelId(channelId) ?? channelId;
    }
    if (getIt.isRegistered<SessionRuntimeMirror>()) {
      // 裸帧不带 hub_id：把连接对端交给 mirror 做换主机回放的身份校验（A7-2）。
      getIt<SessionRuntimeMirror>().apply(snapshot, sourcePeerId: peerId);
    }
    // 队列是 durable 的：和 hub_event 的 session.state 一样补给 relay 做
    // 排队豁免（运行中用户插话要等这一轮跑完）。
    final queue = snapshot['queue'];
    if (queue is List) {
      PouchTurnRelay.instance.noteHostQueue(queue);
    }
    // 翻成 idle：先把已拼到的正文 flush 出去，但**不要立刻删占位**。
    // 主机的顺序不保证（旧版先发 idle 再落最终消息；失败 / 取消的回合甚至
    // 没有最终消息），立刻删会让答案闪一下消失、失败回合的流式正文全丢。
    // 保留到该回合的最终 `message.created` 到达（[_insertMessage] 会收掉），
    // 或等过 [_flowIdleFinalizeDelay] 把占位收尾成终态（见 [_finalizeIdleTurn]）。
    if (snapshot['state'] != 'running') {
      // A6-7：旧主机只发 `request_id`，chunk 用 `turn_id ?? request_id`
      // 登记 [_liveChannels]；idle 必须按同一套提取，否则永远找不到这一
      // 回合，占位一直挂在 streaming。
      final turnId =
          (snapshot['turn_id'] ?? snapshot['request_id'] ?? '').toString();
      if (turnId.isNotEmpty && _liveChannels.containsKey(turnId)) {
        await _flushLiveTurn(turnId);
        if (_liveChannels.containsKey(turnId)) _scheduleIdleFinalize(turnId);
      }
    } else {
      // A9-5：running 帧就是「这个回合又活了」的权威信号。主机瞬态重试
      // 复用 turn_id 时，上一代可能已经被收进 settled；不重新激活的话重试
      // 的 running 之后所有 chunk 都会被丢掉。
      final turnId =
          (snapshot['turn_id'] ?? snapshot['request_id'] ?? '').toString();
      if (turnId.isNotEmpty) {
        _reactivateOnNewAttempt(turnId, data);
        _reactivateSettledTurn(turnId);
      }
    }
  }

  /// idle 之后给「最终消息」留一个有限窗口：把兜底窗口改短，超时就地收尾，
  /// 不删占位。
  void _scheduleIdleFinalize(String turnId) {
    _idleSeenTurns.add(turnId);
    _scheduleFinalize(turnId);
  }

  /// 顺延一个回合的收尾窗口（A7-3 / A9-10）。
  ///
  /// 第一片 chunk / turn.started 起用兜底窗口，idle 之后用短窗口；任何活动
  /// 都把 deadline 顺延回去，绝不只取消。这里**不分配 Timer**：整台 client
  /// 只用一个 Timer 盯住最早的 deadline，回调再按剩余回合续期，所以几百片
  /// chunk 也不会变成几百个 Timer 分配。
  void _scheduleFinalize(String turnId) {
    final delay = _idleSeenTurns.contains(turnId)
        ? flowIdleFinalizeDelay
        : flowFallbackFinalizeDelay;
    debugFinalizeTimerArms++;
    _finalizeDeadlines[turnId] =
        DateTime.now().millisecondsSinceEpoch + delay.inMilliseconds;
    _ensureFinalizeTimer();
  }

  /// 只在「最早 deadline 比当前唤醒点更晚」时才需要新建 Timer；已有 Timer
  /// 到点会重新检查所有 deadline 并自行续期。
  void _ensureFinalizeTimer() {
    if (_finalizeDeadlines.isEmpty) {
      _finalizeTimer?.cancel();
      _finalizeTimer = null;
      _finalizeWakeAtMs = null;
      return;
    }
    var earliest = 0;
    var first = true;
    for (final deadline in _finalizeDeadlines.values) {
      if (first || deadline < earliest) {
        earliest = deadline;
        first = false;
      }
    }
    final wakeAt = _finalizeWakeAtMs;
    if (_finalizeTimer != null && wakeAt != null && wakeAt <= earliest) {
      return;
    }
    _finalizeTimer?.cancel();
    _finalizeWakeAtMs = earliest;
    final now = DateTime.now().millisecondsSinceEpoch;
    final waitMs = earliest - now;
    debugFinalizeTimerAllocations++;
    _finalizeTimer = Timer(
      Duration(milliseconds: waitMs > 0 ? waitMs : 0),
      _onFinalizeTick,
    );
  }

  void _onFinalizeTick() {
    _finalizeTimer = null;
    _finalizeWakeAtMs = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = <String>[];
    for (final entry in _finalizeDeadlines.entries) {
      if (entry.value <= now) due.add(entry.key);
    }
    for (final turnId in due) {
      _finalizeDeadlines.remove(turnId);
      unawaited(_finalizeIdleTurn(turnId));
    }
    _ensureFinalizeTimer();
  }

  /// 等不到最终消息：把占位从「流式」收成终态，正文保留。
  ///
  /// 空正文（只有 metadata、还没来得及出字）没有保留价值，直接删掉；
  /// 有正文就只去掉 `status: streaming`。占位行本身保留到最终消息到达，
  /// 届时 [_insertMessage] 会按确定性的 `hub-live-<turnId>` id 在库里找到并
  /// 删除 —— 不依赖内存，App 重启后重放最终消息也能收干净。
  ///
  /// A10-1：30s 兜底只是给流式占位停动画、清 attached/live 状态，**不是**
  /// 权威终态。主机可能停在 `ask_ui` 等用户回答（最长 30 分钟），这期间没有
  /// 帧到达；兜底计时器不能把还在等的交互卡标成 `turn_ended`。只有明确的
  /// idle（[_scheduleIdleFinalize]）/ `turn.finished` 才允许关卡。
  Future<void> _finalizeIdleTurn(String turnId) async {
    if (!_liveChannels.containsKey(turnId)) return;
    // _idleSeenTurns 会在 _clearLiveTurn 里被清掉，先在这里记下这次收尾
    // 是「权威 idle 超时」还是「没收到 idle 的兜底」。
    final sawAuthoritativeIdle = _idleSeenTurns.contains(turnId);
    await _flushLiveTurn(turnId);
    // flush 期间最终消息可能已经先到了。
    if (!_liveChannels.containsKey(turnId)) return;
    final channelId = _liveChannels[turnId]!;
    final content = _liveBuffers[turnId] ?? '';
    if (content.isEmpty) {
      final cleared = await _clearLiveTurn(
        turnId,
        closeCards: sawAuthoritativeIdle,
      );
      if (cleared != null) _notify(cleared);
      return;
    }
    if (getIt.isRegistered<LocalDatabaseService>()) {
      try {
        final db = getIt<LocalDatabaseService>();
        // A7-1：给保留下来的占位打标记。之后同频道的无关 agent 消息扫描占位
        // 时要跳过它；只有这个回合自己的最终回复才把它换成完整答案。
        await db.updateMessageMetadata(
          liveTurnPlaceholderId(turnId),
          const {'finalized': true},
        );
        if (await db.getMessageById(liveTurnPlaceholderId(turnId)) != null) {
          _rememberFinalizedRetainedTurn(turnId);
        }
      } catch (e) {
        _log.warning('idle finalize failed: $e', tag: 'HubEvent');
      }
    }
    _notify(channelId);
    await _clearLiveTurn(
      turnId,
      deletePlaceholder: false,
      closeCards: sawAuthoritativeIdle,
    );
  }

  void _applyMeta(String peerId, HubEvent event) {
    final kind = event.data['kind'] as String? ?? '';
    final body = event.data['data'];
    if (kind.isEmpty || body is! Map) return;
    PeerAgentClientService.instance.applyHubAgentMeta(
      peerId: peerId,
      agentId: event.agentId,
      kind: kind,
      data: Map<String, dynamic>.from(body),
    );
  }

  void _notify(String channelId) {
    if (!getIt.isRegistered<ChatService>()) return;
    getIt<ChatService>().notifyChannelUpdate(channelId);
  }

  /// 主机频道折到本机正在看的会话。和 [message.created] 用同一套映射，
  /// 否则流式占位和最终消息会落在两个频道上。
  Future<({String channelId, String senderId, String senderName})>
      _resolveHubTarget(
    String peerId,
    HubEvent event, {
    String senderType = 'agent',
    String? fallbackSenderId,
    String fallbackSenderName = '',
  }) async {
    final rawChannelId =
        (event.data['channel_id'] as String?)?.trim().isNotEmpty == true
            ? event.data['channel_id'] as String
            : event.channelId;
    if (rawChannelId.isEmpty) {
      return (channelId: '', senderId: '', senderName: '');
    }
    final isGroup = rawChannelId.startsWith('group_');
    final rawSessionId = (event.data['session_id'] as String?)?.trim() ?? '';
    final sessionId = rawSessionId.isNotEmpty
        ? rawSessionId
        : (!isGroup
            ? (remoteSessionIdFromChannelId(rawChannelId) ?? rawChannelId)
            : '');
    final rawAgentId = (event.data['agent_id'] as String?)?.trim() ?? '';
    final effectiveRemoteAgentId = rawAgentId.isNotEmpty
        ? rawAgentId
        : (event.agentId.isNotEmpty && event.agentId != 'user'
            ? event.agentId
            : (!isGroup ? 'she-builtin-agent-001' : ''));
    final fallback = (fallbackSenderId == null || fallbackSenderId.isEmpty)
        ? effectiveRemoteAgentId
        : fallbackSenderId;
    return PeerAgentClientService.instance.prepareLocalTargetForHubMessage(
      peerId: peerId,
      remoteAgentId: effectiveRemoteAgentId,
      sessionId: sessionId,
      rawChannelId: rawChannelId,
      senderType: senderType,
      fallbackSenderId: fallback,
      fallbackSenderName: fallbackSenderName,
      sessionTitle: event.data['session_title'] as String?,
    );
  }

  Future<void> _syncActiveHost() async {
    final session = await PouchSessionStore.readActive();
    if (session == null) return;
    await _catchUpIfConnected(session.hostPeerId);
  }

  Future<void> _catchUpIfConnected(String peerId) async {
    final id = peerId.trim();
    if (id.isEmpty) return;
    if (send == null &&
        !PeerConnectionManager.instance.connectedPeerIds.contains(id)) {
      return;
    }
    await catchUp(id);
  }

  Future<void> _catchUpIfActiveHost(String peerId) async {
    final id = peerId.trim();
    if (id.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final active = PouchChannel.active?.session;
    if (active != null && active.hostPeerId == id && active.isLoggedIn(nowMs)) {
      await catchUp(id);
      return;
    }
    final session = await PouchSessionStore.readActive();
    if (session != null &&
        session.hostPeerId == id &&
        session.isLoggedIn(nowMs)) {
      PouchChannel.install(session);
      await catchUp(id);
    }
  }

  Future<bool> _send(String peerId, Map<String, dynamic> frame) {
    final send = this.send;
    if (send != null) return send(peerId, frame);
    // events_sync / turn_attach / interaction_resp 都是发出去要等回应的帧。
    // 半开连接上写 socket 会静默成功，但应答永远不来；先探活，失败就丢掉
    // 旧连接并在 5s 内等重连后重发，别让它白等单页超时再重试三轮。
    return PeerConnectionManager.instance.sendControl(
      peerId,
      frame,
      waitForReconnect: const Duration(seconds: 5),
    );
  }

  Future<String> _key(String peerId) async {
    final lookup = fingerprintOf;
    if (lookup != null) return lookup(peerId);
    final peer = await PeerStorageService().getPeerById(peerId);
    final fingerprint = peer?.fingerprint.trim() ?? '';
    return fingerprint.isEmpty ? peerId : fingerprint;
  }
}

class HubNotice {
  const HubNotice({required this.peerId, required this.event});

  final String peerId;
  final HubEvent event;

  bool get isReset => event.kind == 'reset';

  factory HubNotice.reset(String peerId) {
    return HubNotice(
      peerId: peerId,
      event: const HubEvent(
        seq: 0,
        kind: 'reset',
        channelId: '',
        agentId: '',
        origin: 'hub',
        data: {},
      ),
    );
  }
}

abstract class HubSeqStore {
  Future<int> read(String fingerprint);
  Future<void> write(String fingerprint, int seq);
}

class PrefsHubSeqStore implements HubSeqStore {
  @override
  Future<int> read(String fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('hub_event_seq_$fingerprint') ?? 0;
  }

  @override
  Future<void> write(String fingerprint, int seq) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hub_event_seq_$fingerprint', seq);
  }
}

class MemoryHubSeqStore implements HubSeqStore {
  final values = <String, int>{};

  @override
  Future<int> read(String fingerprint) async => values[fingerprint] ?? 0;

  @override
  Future<void> write(String fingerprint, int seq) async {
    values[fingerprint] = seq;
  }
}
