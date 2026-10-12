import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../service_locator.dart';
import '../../services/chat_service.dart';
import '../../services/cli_execution_gate.dart';
import '../../services/local_database_service.dart';
import '../../services/noise_identity.dart';
import '../../services/logger_service.dart';
import '../../storage/pouch_login_keeper.dart';
import '../../storage/pouch_session.dart';
import '../hub_event_apply.dart';
import '../pouch_turn_relay.dart';
import 'peer_agent_client_service.dart';
import 'peer_connection_manager.dart';
import 'peer_storage_service.dart';

/// 跟着储物袋把主机事件补到这台客户端。
///
/// 登录之后循环 `events_sync_req` 直到追上 `head_seq`，再吃实时 `hub_event`。
/// 序号对不上就先补洞。消息按 id 去重；没在看的回合用 `turn_attach_req` 接流。
class HubEventClient {
  HubEventClient({
    Stream<PeerControlEvent>? events,
    this.send,
    HubSeqStore? seqStore,
    this.fingerprintOf,
    this.watchingTurn,
    this.onCaughtUp,
  })  : events = events ?? PeerConnectionManager.instance.controlEvents,
        seqStore = seqStore ?? PrefsHubSeqStore();

  final Stream<PeerControlEvent> events;
  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final HubSeqStore seqStore;
  final Future<String> Function(String peerId)? fingerprintOf;
  final bool Function(String turnId)? watchingTurn;
  final void Function(String peerId)? onCaughtUp;

  final _uuid = const Uuid();
  final _log = LoggerService();
  final _notices = StreamController<HubNotice>.broadcast();
  final _attached = <String>{};
  final _liveBuffers = <String, String>{};
  final _liveChannels = <String, String>{};

  StreamSubscription<PeerControlEvent>? _sub;
  StreamSubscription<void>? _reloginSub;
  Future<void>? _syncing;
  var _livePaused = false;

  Stream<HubNotice> get notices => _notices.stream;

  void start() {
    _sub ??= events.listen(_onControl);
    _reloginSub ??= PouchLoginKeeper.instance.relogged.listen((_) {
      unawaited(_syncActiveHost());
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _reloginSub?.cancel();
    _sub = null;
    _reloginSub = null;
  }

  Future<void> _onControl(PeerControlEvent event) async {
    switch (event.type) {
      case 'pouch_login_resp':
        if (event.data['accepted'] == true) {
          // 调用方要等这一帧返回后才装上登录通道。立刻补洞会以明文发出去。
          final peerId = event.peerId;
          unawaited(Future<void>(() => catchUp(peerId)));
        }
      case 'hub_event':
        final parsed = HubEvent.parse(event.data['event']);
        if (parsed == null) return;
        await _onLive(event.peerId, parsed);
      case 'pouch_turn_event':
        await _onAttachedChunk(event.peerId, event.data);
      case 'events_sync_resp':
        break;
    }
  }

  Future<void> catchUp(String peerId) {
    final running = _syncing;
    if (running != null) return running;
    final job = _catchUp(peerId);
    _syncing = job;
    return job.whenComplete(() => _syncing = null);
  }

  Future<void> _catchUp(String peerId) async {
    _livePaused = true;
    try {
      final key = await _key(peerId);
      var cursor = await seqStore.read(key);
      while (true) {
        final page = await _requestPage(peerId, cursor);
        if (page == null) return;
        final base = page.reset ? 0 : cursor;
        if (page.reset && !_notices.isClosed) {
          _notices.add(HubNotice.reset(peerId));
        }
        var walking = base;
        for (final event in page.events) {
          final step = cursorStep(walking, event.seq);
          if (!page.reset && step != HubCursorStep.apply) continue;
          await _dispatch(peerId, event);
          walking = event.seq;
        }
        cursor = cursorAfterPage(base, page);
        await seqStore.write(key, cursor);
        if (syncCaughtUp(cursor, page.headSeq) || page.events.isEmpty) {
          onCaughtUp?.call(peerId);
          return;
        }
      }
    } finally {
      _livePaused = false;
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
        await catchUp(peerId);
        return;
      case HubCursorStep.apply:
        await _dispatch(peerId, event);
        await seqStore.write(key, event.seq);
    }
  }

  Future<HubSyncPage?> _requestPage(String peerId, int since) async {
    final requestId = _uuid.v4();
    final done = Completer<HubSyncPage?>();
    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId || event.type != 'events_sync_resp') return;
      if (event.data['request_id'] != requestId) return;
      done.complete(HubSyncPage.parse(event.data));
    });
    try {
      final sent = await _send(peerId, {
        'type': 'events_sync_req',
        'request_id': requestId,
        'since_seq': since,
        'limit': 500,
      });
      if (!sent) return null;
      return await done.future.timeout(const Duration(seconds: 8));
    } catch (error) {
      _log.warning('events sync failed: $error', tag: 'HubEvent');
      return null;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _dispatch(String peerId, HubEvent event) async {
    switch (event.kind) {
      case 'message.created':
        await _insertMessage(event);
      case 'message.updated':
        await _updateMessage(event);
      case 'turn.started':
        await _onTurnStarted(peerId, event);
      case 'turn.finished':
        await _onTurnFinished(event);
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
      case 'agents.changed':
      case 'groups.changed':
        if (!_notices.isClosed) {
          _notices.add(HubNotice(peerId: peerId, event: event));
        }
    }
  }

  Future<void> _showInteraction(String peerId, HubEvent event) =>
      _renderInteraction(
        peerId: peerId,
        channelId: event.channelId,
        agentId: event.agentId,
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
    if (data['selected_action_id'] != null ||
        data['submitted_values'] != null) {
      return;
    }
    if (data['closed'] != null) return;
    metadata[kind] = Map<String, dynamic>.from(data)..['closed'] = reason;
    await db.updateMessageMetadata(messageId, metadata);
    final channelId = row['channel_id'] as String? ?? '';
    if (channelId.isNotEmpty) _notify(channelId);
  }

  Future<void> _insertMessage(HubEvent event) async {
    final data = event.data;
    final id = data['id'] as String? ?? '';
    final channelId = (data['channel_id'] as String?)?.trim().isNotEmpty == true
        ? data['channel_id'] as String
        : event.channelId;
    if (id.isEmpty || channelId.isEmpty) return;
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final db = getIt<LocalDatabaseService>();
    final from = data['from'];
    final sender = from is Map ? Map<String, dynamic>.from(from) : const {};
    final metadata = data['metadata'];
    try {
      await db.createMessage(
        id: id,
        channelId: channelId,
        senderId: sender['id'] as String? ?? event.agentId,
        senderType: sender['type'] as String? ?? 'agent',
        senderName: sender['name'] as String? ?? '',
        content: data['content'] as String? ?? '',
        messageType: data['type'] as String? ?? 'text',
        metadata: metadata is Map ? Map<String, dynamic>.from(metadata) : null,
        replyToId: data['reply_to'] as String?,
        createdAt: data['timestamp'] is int && data['timestamp'] != 0
            ? DateTime.fromMillisecondsSinceEpoch(
                data['timestamp'] as int,
                isUtc: true,
              )
            : null,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (error) {
      _log.warning('message.created skipped: $error', tag: 'HubEvent');
      return;
    }
    final turnId = _liveChannels.entries
        .where((entry) => entry.value == channelId)
        .map((entry) => entry.key)
        .toList();
    for (final id in turnId) {
      await db.deleteMessage(liveTurnPlaceholderId(id));
      _liveBuffers.remove(id);
      _liveChannels.remove(id);
    }
    _notify(channelId);
  }

  Future<void> _updateMessage(HubEvent event) async {
    final id = event.data['id'] as String? ?? '';
    if (id.isEmpty || !getIt.isRegistered<LocalDatabaseService>()) return;
    final content = event.data['content'];
    final metadata = event.data['metadata'];
    if (content is! String) return;
    await getIt<LocalDatabaseService>().updateMessage(
      messageId: id,
      content: content,
      metadata: metadata is Map ? Map<String, dynamic>.from(metadata) : null,
    );
    if (event.channelId.isNotEmpty) _notify(event.channelId);
  }

  Future<void> _onTurnStarted(String peerId, HubEvent event) async {
    final turnId = event.data['turn_id'] as String? ?? '';
    final channelId = event.data['channel_id'] as String? ?? event.channelId;
    if (turnId.isEmpty || channelId.isEmpty) return;
    if (getIt.isRegistered<ChatService>()) {
      getIt<ChatService>().dropQueuedMessage(turnId);
    }
    final watching = watchingTurn?.call(turnId) ??
        PouchTurnRelay.instance.isWatching(turnId);
    if (watching) return;
    _attached.add(turnId);
    _liveChannels[turnId] = channelId;
    _liveBuffers[turnId] = '';
    if (getIt.isRegistered<LocalDatabaseService>()) {
      await getIt<LocalDatabaseService>().createMessage(
        id: liveTurnPlaceholderId(turnId),
        channelId: channelId,
        senderId: event.agentId.isEmpty ? 'she' : event.agentId,
        senderType: 'agent',
        senderName: '',
        content: '',
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      _notify(channelId);
    }
    await _send(peerId, {
      'type': 'turn_attach_req',
      'request_id': _uuid.v4(),
      'turn_id': turnId,
      'known_content_length': 0,
    });
  }

  Future<void> _onTurnFinished(HubEvent event) async {
    final turnId = event.data['turn_id'] as String? ?? '';
    _attached.remove(turnId);
    final channelId = _liveChannels[turnId];
    if (channelId != null) _notify(channelId);
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
        interactionId: data['interaction_id'] as String? ?? '',
        kind: data['interaction_type'] as String? ?? '',
        body: data['data'],
      );
      return;
    }
    if (data['kind'] == 'chunk') {
      final chunk = data['chunk'] as String? ?? '';
      final next = (_liveBuffers[turnId] ?? '') + chunk;
      _liveBuffers[turnId] = next;
      final channelId = _liveChannels[turnId];
      if (channelId == null || !getIt.isRegistered<LocalDatabaseService>()) {
        return;
      }
      unawaited(
        getIt<LocalDatabaseService>()
            .updateMessage(
              messageId: liveTurnPlaceholderId(turnId),
              content: next,
            )
            .then((_) => _notify(channelId)),
      );
    }
    if (data['kind'] == 'done' || data['kind'] == 'error') {
      _attached.remove(turnId);
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

  Future<void> _syncActiveHost() async {
    final session = await PouchSessionStore.readActive();
    if (session == null) return;
    await catchUp(session.hostPeerId);
  }

  Future<bool> _send(String peerId, Map<String, dynamic> frame) {
    final send = this.send;
    if (send != null) return send(peerId, frame);
    return PeerConnectionManager.instance.sendControl(peerId, frame);
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
