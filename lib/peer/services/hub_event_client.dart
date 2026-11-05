import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

  final _uuid = const Uuid();
  final _log = LoggerService();
  final _notices = StreamController<HubNotice>.broadcast();
  final _controlQueue = SerialTaskQueue<String>();

  /// attach 请求 id → turn id。主机回 attach-lost 时用它认领占位。
  final _attachRequests = <String, String>{};

  final _attached = <String>{};
  final _liveBuffers = <String, String>{};
  final _liveChannels = <String, String>{};
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
    _liveDirty.clear();
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
      case 'events_sync_resp':
        break;
      case 'session_snapshot_resp':
        // 启动 / 重连全量对账：主机没提到的会话一律收敛成 idle，
        // 上一代 hub 留下的 running 不会永远挂着。
        final sessions = event.data['sessions'];
        if (sessions is List &&
            getIt.isRegistered<SessionRuntimeMirror>()) {
          getIt<SessionRuntimeMirror>().reconcileTo(sessions);
        }
    }
  }

  /// 登录成功后立刻要一份所有活跃会话的全量状态快照。
  /// 主机正在跑、但启动那一刻没有状态跃迁的回合，只有这次对账能让 App
  /// 看到；`session.state` 是跃迁事件，不会为「早就开始了」的回合补发。
  Future<void> requestSessionSnapshot(String peerId) async {
    await _send(peerId, <String, dynamic>{
      'type': 'session_snapshot_req',
      'request_id': _uuid.v4(),
    });
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
          getIt<SessionRuntimeMirror>().apply(event.data);
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
    final source = (event.data['source_session_id']?.toString() ?? '').isNotEmpty
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

  Future<void> _insertMessage(String peerId, HubEvent event) async {
    final data = event.data;
    final id = data['id'] as String? ?? '';
    final rawChannelId = (data['channel_id'] as String?)?.trim().isNotEmpty == true
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
    if (senderType != 'user') {
      final turnId = _liveChannels.entries
          .where((entry) => entry.value == channelId)
          .map((entry) => entry.key)
          .toList();
      for (final id in turnId) {
        await db.deleteMessage(liveTurnPlaceholderId(id));
        _liveBuffers.remove(id);
        _liveChannels.remove(id);
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
    final rawChannelId = (event.data['channel_id'] as String?)?.trim().isNotEmpty ==
            true
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
    _attached.add(turnId);
    _liveChannels[turnId] = channelId;
    _liveBuffers[turnId] = '';
    if (getIt.isRegistered<LocalDatabaseService>()) {
      await getIt<LocalDatabaseService>().createMessage(
        id: liveTurnPlaceholderId(turnId),
        channelId: channelId,
        senderId: target.senderId.isEmpty
            ? (event.agentId.isEmpty ? 'she' : event.agentId)
            : target.senderId,
        senderType: 'agent',
        senderName: target.senderName,
        content: '',
        metadata: const {'status': 'streaming'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
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
  Future<String?> _clearLiveTurn(String turnId) async {
    _attached.remove(turnId);
    _attachRequests.removeWhere((_, id) => id == turnId);
    _liveBuffers.remove(turnId);
    _liveDirty.remove(turnId);
    final channelId = _liveChannels.remove(turnId);
    if (turnId.isNotEmpty && getIt.isRegistered<LocalDatabaseService>()) {
      await getIt<LocalDatabaseService>()
          .deleteMessage(liveTurnPlaceholderId(turnId));
    }
    await _closeTurnCards(turnId);
    return channelId;
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
    if (data['kind'] == 'interaction') {
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
      await getIt<LocalDatabaseService>().updateMessage(
        messageId: liveTurnPlaceholderId(turnId),
        content: content,
      );
      _notify(channelId);
    } catch (e) {
      _log.warning('live turn flush failed: $e', tag: 'HubEvent');
    }
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
    if (active != null &&
        active.hostPeerId == id &&
        active.isLoggedIn(nowMs)) {
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
