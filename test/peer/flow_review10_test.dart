import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/peer/hub_event_apply.dart'
    show liveTurnPlaceholderId, liveTurnPlaceholderPrefix;
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/storage/pouch_login.dart';

import '../storage/test_harness.dart';

/// 第十轮评审：兜底收尾不关卡 / epoch 换代 / 回合归属 / gate 通知 / 热路径。
///
/// 每条用例都用唯一的频道 / turn id，避免和其它定向用例共用 ffi SQLite 时
/// 互相污染。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    setupServiceLocator();
    await LocalDatabaseService().database;
  });

  Future<void> until(FutureOr<bool> Function() ready) async {
    for (var i = 0; i < 150; i++) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  Map<String, dynamic> chunk(
    String turnId,
    String channelId,
    String sessionId,
    String content,
  ) =>
      {
        'type': 'agent_chunk',
        'request_id': turnId,
        'turn_id': turnId,
        'channel_id': channelId,
        'session_id': sessionId,
        'session_key': sessionId,
        'agent_id': 'agent-a10',
        'run_id': 'a10run',
        'node': 'impl',
        'content': content,
      };

  Map<String, dynamic> created(
    int seq,
    String channelId,
    String sessionId,
    String id, {
    Map<String, dynamic>? metadata,
  }) =>
      {
        'type': 'hub_event',
        'event': {
          'seq': seq,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': 'agent-a10',
          'data': {
            'id': id,
            'channel_id': channelId,
            'session_id': sessionId,
            'agent_id': 'agent-a10',
            'content': id,
            'type': 'text',
            if (metadata != null) 'metadata': metadata,
            'from': {'id': 'agent-a10', 'type': 'agent', 'name': 'A10'},
          },
        },
      };

  HubEventClient clientFor(
    Stream<PeerControlEvent> events, {
    Future<bool> Function(String, Map<String, dynamic>)? send,
    Duration idle = const Duration(milliseconds: 40),
    Duration fallback = const Duration(seconds: 20),
    String fingerprint = 'fp-a10',
  }) =>
      HubEventClient(
        events: events,
        send: send ?? (_, __) async => true,
        seqStore: MemoryHubSeqStore(),
        fingerprintOf: (_) async => fingerprint,
        watchingTurn: (_) => false,
        flowIdleFinalizeDelay: idle,
        flowFallbackFinalizeDelay: fallback,
      );

  Future<String?> cardClosedReason(
    LocalDatabaseService db,
    String interactionId,
  ) async {
    final row =
        await db.getMessageById(HubEventClient.hubCardMessageId(interactionId));
    final raw = row?['metadata'];
    if (raw is! String || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final data = decoded['single_select'];
    return data is Map ? data['closed']?.toString() : null;
  }

  Future<SessionRuntimeMirror> installMirror({
    Duration retention = const Duration(milliseconds: 50),
  }) async {
    final previous = getIt.isRegistered<SessionRuntimeMirror>()
        ? getIt<SessionRuntimeMirror>()
        : null;
    if (previous != null) await getIt.unregister<SessionRuntimeMirror>();
    final mirror = SessionRuntimeMirror(flowRetention: retention);
    getIt.registerSingleton<SessionRuntimeMirror>(mirror);
    addTearDown(() async {
      await getIt.unregister<SessionRuntimeMirror>();
      mirror.dispose();
      if (previous != null) {
        getIt.registerSingleton<SessionRuntimeMirror>(previous);
      }
    });
    return mirror;
  }

  Map<String, dynamic> snap({
    required String key,
    int revision = 1,
    String state = 'running',
    String turnId = '',
    String hubId = '',
    String epoch = '',
  }) =>
      {
        'session_key': key,
        'revision': revision,
        'state': state,
        'flow': true,
        'turn_id': turnId,
        'hub_id': hubId,
        if (epoch.isNotEmpty) 'epoch': epoch,
      };

  Future<void> requestSnapshot(
    HubEventClient client,
    String peerId,
  ) async {
    await client.requestSessionSnapshot(peerId);
    // _onControl 是异步监听；等 mirror 处理完再断言。
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('A10-1: 30s 兜底收尾不关掉仍在等回答的交互卡', () async {
    const sessionId = 'flow_a101_ask';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a101-ask-a1';
    const cardId = 'ix-a101-ask';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(HubEventClient.hubCardMessageId(cardId));

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        fallback: const Duration(seconds: 30), fingerprint: 'fp-a101');
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: chunk(turnId, channelId, sessionId, '准备回答'),
    ));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnId)) != null);

    // 主机停在 ask_ui 等回答：重连续传补发的交互卡，属于同一个 turn。
    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: {
        'type': 'pouch_turn_event',
        'request_id': turnId,
        'kind': 'interaction',
        'interaction_id': cardId,
        'interaction_type': 'single_select',
        'agent_id': 'agent-a10',
        'data': {
          'prompt': '确认部署？',
          'options': ['通过', '返工'],
        },
      },
    ));
    await until(() async =>
        await db.getMessageById(HubEventClient.hubCardMessageId(cardId)) !=
        null);
    expect(client.debugFinalizeDelayFor(turnId), const Duration(seconds: 30),
        reason: '这一回合只有兜底窗口，没有权威 idle');

    // 不等 30s 墙钟：直接触发兜底计时器回调。
    client.debugFireFinalizeTimer(turnId);
    await until(() async {
      final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
      return (row?['metadata'] as String? ?? '').contains('finalized');
    });
    expect(await cardClosedReason(db, cardId), isNull,
        reason: '兜底只是停动画，交互卡必须还能点');
    expect(client.debugHasFinalizeTimer(turnId), isFalse);

    // 明确的 turn.finished 仍要把悬着的卡片收起来。
    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.finished',
          'channel_id': channelId,
          'agent_id': 'agent-a10',
          'data': {'turn_id': turnId},
        },
      },
    ));
    await until(() async => await cardClosedReason(db, cardId) == 'turn_ended');
    await incoming.close();
  });

  test('A10-3: 顶层 epoch 触发换代清理，sessions 字段缺省也对账', () async {
    final mirror = await installMirror();
    const key = 'agent:agent-a10:flow_a103_impl';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(
      incoming.stream,
      fingerprint: 'fp-a103',
      send: (peerId, frame) async {
        if (frame['type'] == 'session_snapshot_req') {
          incoming.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'session_snapshot_resp',
              'request_id': frame['request_id'],
              'hub_id': 'hub-a10',
              // H10-11：u64 直接放顶层，且本次故意不带 sessions。
              'epoch': 4,
            },
          ));
        } else if (frame['type'] == 'events_sync_req') {
          incoming.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'events_sync_resp',
              'request_id': frame['request_id'],
              'events': <dynamic>[],
              'head_seq': 0,
              'reset': false,
            },
          ));
        }
        return true;
      },
    );
    client.start();
    addTearDown(client.dispose);
    final peerId = PouchChannel.active?.session.hostPeerId ?? 'peer-a10';

    expect(
      mirror.apply(
        snap(
          key: key,
          revision: 9,
          hubId: 'hub-a10',
          turnId: 'old-turn',
          epoch: '3',
        ),
        sourcePeerId: peerId,
      ),
      isTrue,
    );
    expect(mirror.stateFor(key).isRunning, isTrue);

    await requestSnapshot(client, peerId);
    expect(mirror.stateFor(key).isRunning, isFalse,
        reason: '新 epoch 必须清掉旧进程还在 running 的 flow notifier');
    expect(mirror.stateFor(key).turnId, '', reason: '停止按钮不能继续指向死回合');
    expect(
      mirror.apply(
        snap(
          key: key,
          revision: 1,
          hubId: 'hub-a10',
          turnId: 'new-turn',
          epoch: '4',
        ),
        sourcePeerId: peerId,
      ),
      isTrue,
      reason: '换代后的 rev1 不能被旧 rev9 水位挡住',
    );
    expect(mirror.stateFor(key).turnId, 'new-turn');
    await incoming.close();
  });

  test('A10-3: sessions[].epoch 兜底；无 epoch 快照也不永久卡住', () async {
    final mirror = await installMirror(
      retention: const Duration(milliseconds: 40),
    );
    const key = 'agent:agent-a10:flow_a103_fallback';
    const noEpochKey = 'agent:agent-a10:flow_a103_noepoch';
    final incoming = StreamController<PeerControlEvent>.broadcast();
    Object? snapshotEpoch;
    var sessions = <Map<String, dynamic>>[
      {
        'session_key': 'agent:hub:main',
        'state': 'idle',
        'revision': 1,
        'epoch': 5,
        'hub_id': 'hub-a10',
      },
    ];
    final client = clientFor(
      incoming.stream,
      fingerprint: 'fp-a103b',
      send: (peerId, frame) async {
        if (frame['type'] == 'session_snapshot_req') {
          incoming.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'session_snapshot_resp',
              'request_id': frame['request_id'],
              'hub_id': 'hub-a10',
              if (snapshotEpoch != null) 'epoch': snapshotEpoch,
              'sessions': sessions,
            },
          ));
        } else if (frame['type'] == 'events_sync_req') {
          incoming.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'events_sync_resp',
              'request_id': frame['request_id'],
              'events': <dynamic>[],
              'head_seq': 0,
              'reset': false,
            },
          ));
        }
        return true;
      },
    );
    client.start();
    addTearDown(client.dispose);
    final peerId = PouchChannel.active?.session.hostPeerId ?? 'peer-a10';

    expect(
      mirror.apply(
        snap(
          key: key,
          revision: 9,
          hubId: 'hub-a10',
          turnId: 'epoch-fallback-old',
          epoch: '4',
        ),
        sourcePeerId: peerId,
      ),
      isTrue,
    );
    await requestSnapshot(client, peerId);
    expect(mirror.stateFor(key).isRunning, isFalse,
        reason: 'sessions[].epoch 也要触发换代清理');
    expect(
      mirror.apply(
        snap(
          key: key,
          revision: 1,
          hubId: 'hub-a10',
          turnId: 'epoch-fallback-new',
          epoch: '5',
        ),
        sourcePeerId: peerId,
      ),
      isTrue,
    );

    // 老主机完全不带 epoch：running 先保留（停止按钮），retention 到期收尾。
    snapshotEpoch = 6; // 让下一次快照的 epoch 变化只发生一次，随后去掉。
    await requestSnapshot(client, peerId);
    sessions = <Map<String, dynamic>>[];
    snapshotEpoch = null;
    expect(
      mirror.apply(
        snap(
          key: noEpochKey,
          revision: 2,
          hubId: 'hub-a10',
          turnId: 'no-epoch-turn',
          epoch: '6',
        ),
        sourcePeerId: peerId,
      ),
      isTrue,
    );
    await requestSnapshot(client, peerId);
    expect(mirror.stateFor(noEpochKey).isRunning, isTrue,
        reason: '无 epoch 快照先保留 running');
    await until(() => !mirror.stateFor(noEpochKey).isRunning);
    expect(mirror.stateFor(noEpochKey).turnId, '',
        reason: '30s retention 兜底：没有活动就不会永远 running');
    await incoming.close();
  });

  test('A10-3: epoch 兼容形态都能读出来', () {
    expect(HubEventClient.debugSnapshotEpoch({'epoch': 7}), '7');
    expect(HubEventClient.debugSnapshotEpoch({'hub_epoch': '8'}), '8');
    expect(
      HubEventClient.debugSnapshotEpoch({
        'sessions': [
          {'session_key': 'a'},
          {'session_key': 'b', 'epoch': 9},
        ],
      }),
      '9',
    );
    expect(
      HubEventClient.debugSnapshotEpoch({
        'snapshot': {'epoch': 10},
      }),
      '10',
    );
    expect(HubEventClient.debugSnapshotEpoch({'sessions': []}), isNull);
  });

  test('A10-4: 无归属回复不误伤另一个 live turn；H10-12 归属只收本回合', () async {
    const sessionId = 'flow_a104_multi';
    const channelId = 'psess_$sessionId';
    const t1 = 'flow-a104-one';
    const t2 = 'flow-a104-two';
    const unattributedId = 'msg-a104-unattributed';
    const attributedId = 'msg-a104-attributed';
    final db = getIt<LocalDatabaseService>();
    for (final turnId in [t1, t2]) {
      await db.deleteMessage(liveTurnPlaceholderId(turnId));
    }
    await db.deleteMessage(unattributedId);
    await db.deleteMessage(attributedId);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        fallback: const Duration(seconds: 20), fingerprint: 'fp-a104');
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
        peerId: 'peer-a10', data: chunk(t1, channelId, sessionId, '甲')));
    incoming.add(PeerControlEvent(
        peerId: 'peer-a10', data: chunk(t2, channelId, sessionId, '乙')));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(t1)) != null &&
        await db.getMessageById(liveTurnPlaceholderId(t2)) != null);

    // 老主机形状：没有顶层 turn_id，metadata.flow 里也没有 turn_id。
    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: created(1, channelId, sessionId, unattributedId, metadata: {
        'flow': {'run_id': 'a10run', 'node_key': 'impl', 'attempt': 1},
      }),
    ));
    await until(() async => await db.getMessageById(unattributedId) != null);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(await db.getMessageById(liveTurnPlaceholderId(t1)), isNotNull,
        reason: '没有归属时不能把频道里所有 live turn 一把收掉');
    expect(await db.getMessageById(liveTurnPlaceholderId(t2)), isNotNull);
    expect(client.debugHasFinalizeTimer(t1), isTrue);
    expect(client.debugHasFinalizeTimer(t2), isTrue);
    expect(client.debugLivePlaceholderScans, 0, reason: '归属判不出来时连占位扫描都该跳过');

    // H10-12：最终 agent 消息在 metadata.flow 里带 turn_id。
    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: created(2, channelId, sessionId, attributedId, metadata: {
        'flow': {
          'run_id': 'a10run',
          'node_key': 'impl',
          'attempt': 1,
          'turn_id': t1,
        },
      }),
    ));
    await until(
        () async => await db.getMessageById(liveTurnPlaceholderId(t1)) == null);
    expect(await db.getMessageById(liveTurnPlaceholderId(t2)), isNotNull,
        reason: '带归属的回复只收它自己那一回合');
    expect(client.debugHasFinalizeTimer(t2), isTrue);
    await incoming.close();
  });

  test('A10-5: gate 提示带 metadata.flow.gate 不算最终回复', () async {
    const sessionId = 'flow_a105_gate';
    const channelId = 'psess_$sessionId';
    const turnId = 'flow-a105-gate-a1';
    const gateId = 'peerhist_a105_gate';
    const finalId = 'peerhist_a105_final';
    final db = getIt<LocalDatabaseService>();
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await db.deleteMessage(gateId);
    await db.deleteMessage(finalId);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        fallback: const Duration(seconds: 20), fingerprint: 'fp-a105');
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: chunk(turnId, channelId, sessionId, '流式中'),
    ));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnId)) != null);

    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: created(1, channelId, sessionId, gateId, metadata: {
        'flow': {
          'run_id': 'a10run',
          'node_key': 'gate',
          'gate': {'kind': 'notice', 'text': '请确认'},
        },
      }),
    ));
    await until(() async => await db.getMessageById(gateId) != null);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final streaming = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(streaming, isNotNull, reason: 'gate 提示不能删掉流式占位');
    expect(streaming!['metadata'] as String? ?? '', contains('streaming'));
    expect(client.channelHasLiveTurn(channelId), isTrue);
    expect(client.debugHasFinalizeTimer(turnId), isTrue);
    expect(client.debugLivePlaceholderScans, 0, reason: '通知消息连占位扫描都不该触发');

    // 真正的最终回复（H10-12 形状）仍能收掉占位。
    incoming.add(PeerControlEvent(
      peerId: 'peer-a10',
      data: created(2, channelId, sessionId, finalId, metadata: {
        'flow': {
          'run_id': 'a10run',
          'node_key': 'impl',
          'turn_id': turnId,
        },
      }),
    ));
    await until(() async =>
        await db.getMessageById(liveTurnPlaceholderId(turnId)) == null);
    await incoming.close();
  });

  test('A10-10: flow 频道长历史重放不扫占位、不逐条等 hydration', () async {
    const sessionId = 'flow_a1010_replay';
    const channelId = 'psess_$sessionId';
    final db = getIt<LocalDatabaseService>();
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = clientFor(incoming.stream,
        fallback: const Duration(seconds: 20), fingerprint: 'fp-a1010');
    client.start();
    addTearDown(client.dispose);
    await until(() async => client.debugPlaceholderHydrationCalls > 0);
    client.debugLivePlaceholderScans = 0;
    final hydrationBefore = client.debugPlaceholderHydrationCalls;
    expect(liveTurnPlaceholderPrefix, 'hub-live-');

    for (var seq = 1; seq <= 25; seq++) {
      final id = 'msg-a1010-$seq';
      await db.deleteMessage(id);
      incoming.add(PeerControlEvent(
        peerId: 'peer-a10',
        data: created(seq, channelId, sessionId, id),
      ));
    }
    await until(() async => await db.getMessageById('msg-a1010-25') != null);
    expect(client.debugLivePlaceholderScans, 0,
        reason: 'flow 频道没有占位痕迹时，不能每条消息都扫库');
    expect(client.debugPlaceholderHydrationCalls, hydrationBefore,
        reason: '没有占位痕迹时连 hydration 都不必等');
    await incoming.close();
  });
}
