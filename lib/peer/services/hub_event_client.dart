import 'dart:async';

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
          await catchUp(event.peerId);
        }
      case 'hub_event':
        final parsed = HubEvent.parse(event.data['event']);
        if (parsed == null) return;
        await _onLive(event.peerId, parsed);
      case 'pouch_turn_event':
        _onAttachedChunk(event.data);
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

  Future<void> _showInteraction(String peerId, HubEvent event) async {
    final data = event.data['data'];
    final body = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final kind = event.data['interaction_type'] as String? ?? '';
    final interactionId = event.data['interaction_id'] as String? ?? '';
    if (kind == 'client_cli') {
      final target = body['target_fingerprint'] as String? ?? '';
      final mine = (await NoiseIdentity.loadOrCreate()).fingerprintHex;
      if (target.isNotEmpty && mine == target) {
        final output = await CliExecutionGate.instance.execute(
          args: {
            'namespace': body['namespace'] ?? 'os',
            'subcommand': body['subcommand'] ?? '',
            'flags': body['flags'] is Map
                ? Map<String, dynamic>.from(body['flags'] as Map)
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
    if (!getIt.isRegistered<LocalDatabaseService>() || event.channelId.isEmpty) {
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
      metadata[kind] = body;
    }
    final prompt = body['prompt'] as String? ?? body['title'] as String? ?? '';
    await getIt<LocalDatabaseService>().createMessage(
      id: 'hub-ix-$interactionId',
      channelId: event.channelId,
      senderId: event.agentId.isEmpty ? 'she-builtin-agent-001' : event.agentId,
      senderType: 'agent',
      senderName: '惜宝',
      content: kind == 'client_cli' ? '在另一台设备上执行' : prompt,
      metadata: metadata,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _notify(event.channelId);
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

  void _onAttachedChunk(Map<String, dynamic> data) {
    final turnId = data['request_id'] as String? ?? '';
    if (!_attached.contains(turnId)) return;
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
