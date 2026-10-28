import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/hub_event_apply.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 读游标按「越早发起的读越慢」返回：不串行时先到的帧反而最后写，
/// 游标会倒退到 1，串行时每帧都在上一帧落盘后才读。
class _ReversedReadHubSeqStore implements HubSeqStore {
  final values = <String, int>{};
  var _reads = 0;

  @override
  Future<int> read(String fingerprint) async {
    final elapsed = _reads.clamp(0, 19);
    _reads += 1;
    await Future<void>.delayed(Duration(milliseconds: 20 - elapsed));
    return values[fingerprint] ?? 0;
  }

  @override
  Future<void> write(String fingerprint, int seq) async {
    values[fingerprint] = seq;
  }
}

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    setupServiceLocator();
    await LocalDatabaseService().database;
  });

  test('补事件直到追上 head_seq', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        final since = frame['since_seq'] as int;
        sent.add(since);
        final events = since == 0
            ? [
                {
                  'seq': 1,
                  'kind': 'agents.changed',
                  'data': <String, dynamic>{}
                },
              ]
            : [
                {
                  'seq': 2,
                  'kind': 'agents.changed',
                  'data': <String, dynamic>{}
                },
              ];
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': events,
            'head_seq': 2,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );

    await client.catchUp('peer-1');

    expect(sent, [0, 1]);
    expect(store.values['fp'], 2);
    await incoming.close();
  });

  // 主机队列满时会回 `peer_busy`。原先这种回执既不在控制帧名单里，也没有
  // 人认领，补拉只能干等 8 秒超时——日志里只剩「超时」，看不出是主机忙。
  test('主机回 peer_busy 时补拉立刻收尾，不等满 8 秒', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'peer_busy',
            'request_id': frame['request_id'],
            'code': 'host_busy',
            'retryable': true,
            'message': '主机正忙，这条消息没有收下，请稍后重试',
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );

    final started = DateTime.now();
    await client.catchUp('peer-1');
    final elapsed = DateTime.now().difference(started);

    // 三次重试各等一次退避（1s + 2s），但一次都不该走到 8 秒单页超时。
    expect(elapsed, lessThan(const Duration(seconds: 6)));
    expect(store.values['fp'], isNull);
    await incoming.close();
  });

  // 手机端出现过 since_seq 连续几天不动：每次重连都重拉同一页 500 条。
  // 根因是整页走完才写游标，而页里一条事件应用失败就会让循环中止。
  test('补拉时某条事件应用失败不会把游标钉死', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {
                'seq': 1,
                'kind': 'turn.started',
                'channel_id': 'ch-poison',
                'agent_id': 'agent-1',
                'data': {'turn_id': 'poison'},
              },
              {
                'seq': 2,
                'kind': 'agents.changed',
                'data': <String, dynamic>{},
              },
            ],
            'head_seq': 2,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-poison',
      watchingTurn: (turnId) {
        if (turnId == 'poison') throw StateError('bad turn');
        return false;
      },
    );

    await client.catchUp('peer-1');

    // 坏事件被跳过，后面的照常应用，游标落在页尾。
    expect(sent, [0]);
    expect(store.values['fp-poison'], 2);
    await incoming.close();
  });

  // 主机那一页可能只是算得慢（debug 构建下翻二十万条要十秒），8 秒超时后
  // 回包照样会来。以前 finally 里直接把监听取消，迟到的页被无声丢掉，下一轮
  // 又让主机从头算一遍——这正是「since_seq 一直不变」那个自持循环。
  test('超时后迟到的补拉页在下一轮直接认领，不再让主机重算', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      pageTimeout: const Duration(milliseconds: 100),
      pageRetryDelay: const Duration(milliseconds: 200),
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        if (sent.length == 1) {
          // 主机算这一页算了 130ms，超过 100ms 的单页超时。
          Timer(const Duration(milliseconds: 130), () {
            incoming.add(PeerControlEvent(
              peerId: peerId,
              data: {
                'type': 'events_sync_resp',
                'request_id': frame['request_id'],
                'events': [
                  {
                    'seq': 5,
                    'kind': 'agents.changed',
                    'data': <String, dynamic>{},
                  },
                ],
                'head_seq': 5,
                'reset': false,
              },
            ));
          });
        }
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-late',
    );

    await client.catchUp('peer-1');

    // 只发了一次请求：第二轮退避结束时，迟到的页已经躺在暂存里。
    expect(sent, [0]);
    expect(store.values['fp-late'], 5);
    await incoming.close();
  });

  // 连着几轮都拿不到页时不能永远钉在同一个游标上。心跳报的 head_seq 是
  // 主机亲口说的位置，跳过去；中间丢的那段历史作废，下次打开会话重建。
  test('连续失败后游标跳到 ping 的 head_seq，历史同步进度作废', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore()..values['fp-jump'] = 10;
    final client = HubEventClient(
      events: incoming.stream,
      pageTimeout: const Duration(milliseconds: 50),
      pageRetryDelay: const Duration(milliseconds: 20),
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        return true; // 永远不回包
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-jump',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {'type': 'ping', 'timestamp': 1, 'head_seq': 100},
    ));

    for (var i = 0; i < 100 && !sent.contains(100); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(store.values['fp-jump'], 100);
    expect(sent.first, 10, reason: '先从本地游标开始补');
    expect(sent.contains(100), isTrue, reason: '跳过去之后从 head 接着补');
    await incoming.close();
  });

  // 主机只是算得慢（大日志 + 冷缓存）时，多等一会儿就能补回来。超时后
  // 加长等待而不是直接跳到 head：跳过去等于把这段历史当成丢了。
  test('单页超时后加长等待，慢页仍会补回来而不是跳到 head', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore()..values['fp-slow'] = 10;
    final client = HubEventClient(
      events: incoming.stream,
      pageTimeout: const Duration(milliseconds: 50),
      pageRetryDelay: const Duration(milliseconds: 20),
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        if (sent.length == 1) {
          // 这一页算了 300ms：第一次 50ms 超时，加长后的重试里才等到。
          Timer(const Duration(milliseconds: 300), () {
            incoming.add(PeerControlEvent(
              peerId: peerId,
              data: {
                'type': 'events_sync_resp',
                'request_id': frame['request_id'],
                'events': [
                  {
                    'seq': 11,
                    'kind': 'agents.changed',
                    'data': <String, dynamic>{},
                  },
                ],
                'head_seq': 11,
                'reset': false,
              },
            ));
          });
        }
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-slow',
    );
    client.start();
    addTearDown(client.dispose);

    // 心跳报的 head 远在前面：如果按「连续失败就跳 head」处理，游标会变 100。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {'type': 'ping', 'timestamp': 1, 'head_seq': 100},
    ));

    for (var i = 0; i < 100 && store.values['fp-slow'] == 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(store.values['fp-slow'], 11, reason: '慢页补回来了，游标没有跳到 head');
    await incoming.close();
  });

  test('补拉进行中再请求会排队，收尾后按最新游标重跑', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore();
    final firstPageReleased = Completer<void>();
    final secondPageSent = Completer<void>();
    var calls = 0;
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        final since = frame['since_seq'] as int;
        sent.add(since);
        calls += 1;
        if (calls == 1) {
          // 第一次请求挂在旧连接上：连接已换，但应答只能等单页超时。
          await firstPageReleased.future;
        }
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': calls == 1
                ? [
                    {
                      'seq': 1,
                      'kind': 'agents.changed',
                      'data': <String, dynamic>{},
                    },
                  ]
                : <Map<String, dynamic>>[],
            'head_seq': 1,
            'reset': false,
          },
        ));
        if (calls == 2 && !secondPageSent.isCompleted) {
          secondPageSent.complete();
        }
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );

    final first = client.catchUp('peer-1');
    for (var i = 0; i < 50 && sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sent, [0]);

    // 重连后上层会再发一次补拉；不能因为旧 job 还在跑就把它丢了。
    unawaited(client.catchUp('peer-1'));
    expect(sent, [0]);

    firstPageReleased.complete();
    await first;
    await secondPageSent.future.timeout(const Duration(seconds: 5));

    // 第二次用的是第一页落盘后的游标，不是旧的 0。
    expect(sent, [0, 1]);
    expect(store.values['fp'], 1);
    await incoming.close();
  });

  test('补拉期间的 live 事件暂存，收尾后按游标补应用', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore();
    final firstPageReleased = Completer<void>();
    var calls = 0;
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        calls += 1;
        if (calls == 1) await firstPageReleased.future;
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {'seq': 1, 'kind': 'agents.changed', 'data': <String, dynamic>{}},
            ],
            'head_seq': 1,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(client.dispose);

    final syncing = client.catchUp('peer-1');
    for (var i = 0; i < 50 && sent.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sent, [0]);

    // 第一页还没回来时又产生一条 live 事件。以前这里会被直接丢掉，
    // 只能等下一轮 ping 才能补上。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 2,
          'kind': 'agents.changed',
          'channel_id': '',
          'agent_id': '',
          'data': <String, dynamic>{},
        },
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    firstPageReleased.complete();
    await syncing;

    // 回放只走暂存队列，游标推进到 2，不需要再发一次补拉请求。
    for (var i = 0; i < 50 && store.values['fp'] != 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.values['fp'], 2);
    expect(sent, [0]);
    await incoming.close();
  });

  test('channel.read 事件同步清除本机与 psess_ 会话的未读角标', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final bareId = 'dm_sync_read_$suffix';
    final psessId = 'psess_$bareId';

    await db.createChannel(
      Channel.withMemberIds(
        id: bareId,
        name: 'Sync Read',
        type: 'dm',
        memberIds: ['user', 'agent-$suffix'],
      ),
      'user',
    );
    await db.createChannel(
      Channel.withMemberIds(
        id: psessId,
        name: 'Sync Read Psess',
        type: 'dm',
        memberIds: ['user', 'agent-$suffix'],
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {
                'seq': 1,
                'kind': 'message.created',
                'channel_id': bareId,
                'agent_id': 'agent-$suffix',
                'data': {
                  'id': 'm-unread-$suffix',
                  'channel_id': bareId,
                  'content': 'new reply',
                  'type': 'text',
                  'from': {'id': 'agent-$suffix', 'type': 'agent', 'name': 'A'},
                },
              },
              {
                'seq': 2,
                'kind': 'channel.read',
                'channel_id': bareId,
                'agent_id': 'agent-$suffix',
                'data': {
                  'channel_id': bareId,
                  'read_count': 1,
                },
              },
            ],
            'head_seq': 2,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-read',
    );

    await db.createMessage(
      id: 'm-psess-$suffix',
      channelId: psessId,
      senderId: 'agent-$suffix',
      senderType: 'agent',
      senderName: 'A',
      content: 'mirrored reply',
      isRead: 0,
    );
    expect(await db.getUnreadCountByChannel(psessId), 1);

    await client.catchUp('peer-1');

    expect(await db.getUnreadCountByChannel(bareId), 0);
    expect(await db.getUnreadCountByChannel(psessId), 0);
    await incoming.close();
  });

  test('channel.read 携带 all_sessions=true 时清除该 Agent 名下所有本地 DM 会话未读', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 1;
    final agentId = 'agent-all-$suffix';
    final ch1 = 'dm_user_$agentId';
    final ch2 = 'psess_sess_$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: ch1,
        name: 'Default Shell',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    await db.createChannel(
      Channel.withMemberIds(
        id: ch2,
        name: 'Remote Session 2',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    await db.createMessage(
      id: 'm1-$suffix',
      channelId: ch1,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: 'msg 1',
      isRead: 0,
    );
    await db.createMessage(
      id: 'm2-$suffix',
      channelId: ch2,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: 'msg 2',
      isRead: 0,
    );
    expect(await db.getUnreadCountForAgent(agentId), 2);

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final store = MemoryHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {
                'seq': 1,
                'kind': 'channel.read',
                'channel_id': ch2,
                'agent_id': agentId,
                'data': {
                  'channel_id': ch2,
                  'agent_id': agentId,
                  'all_sessions': true,
                },
              },
            ],
            'head_seq': 1,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp-all-$suffix',
    );

    await client.catchUp('peer-1');

    expect(await db.getUnreadCountForAgent(agentId), 0);
    expect(await db.getUnreadCountByChannel(ch1), 0);
    expect(await db.getUnreadCountByChannel(ch2), 0);
    await incoming.close();
  });

  test('channel_digests 已读水位线自动拦截晚到的旧消息，新于水位线的消息仍计未读', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 2;
    final agentId = 'agent-wm-$suffix';
    final channelId = 'psess_wm_$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Watermark Session',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    // 先记录会话已读水位为 t = 2000ms
    await db.upsertChannelReadWatermark(
      channelId,
      agentId: agentId,
      readAtMs: 2000,
    );

    // 晚到的旧消息 (t = 1500ms <= 2000ms)，即使传入 isRead: 0，落库时自动按水位线标为已读
    await db.createMessage(
      id: 'm-old-$suffix',
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: 'old message before watermark',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1500, isUtc: true),
      isRead: 0,
    );
    expect(await db.getUnreadCountByChannel(channelId), 0);

    // 水位线之后的新消息 (t = 3000ms > 2000ms)，正常计为未读
    await db.createMessage(
      id: 'm-new-$suffix',
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: 'new message after watermark',
      createdAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
      isRead: 0,
    );
    expect(await db.getUnreadCountByChannel(channelId), 1);

    // 验证 pending_ops 队列读写与删除
    await db.enqueuePendingOp(
      opId: 'test-op-$suffix',
      kind: 'mark_read',
      targetId: channelId,
      payload: {'channel_id': channelId, 'agent_id': agentId},
    );
    final ops = await db.listPendingOps(kind: 'mark_read');
    expect(ops.any((r) => r['op_id'] == 'test-op-$suffix'), isTrue);
    await db.deletePendingOps(['test-op-$suffix']);
    final opsAfter = await db.listPendingOps(kind: 'mark_read');
    expect(opsAfter.any((r) => r['op_id'] == 'test-op-$suffix'), isFalse);
  });

  test('ping 上的 head_seq 比本地游标新就补洞', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore()..values['fp'] = 3;
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {'seq': 4, 'kind': 'agents.changed', 'data': <String, dynamic>{}},
            ],
            'head_seq': 4,
            'reset': false,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(client.dispose);

    // 主机说到了 4，本地停在 3。被丢掉的若是最后一帧，后面再没有帧来，
    // seq 连续性自检永远发现不了，只有 ping 上这个数字能。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {'type': 'ping', 'timestamp': 1, 'head_seq': 4},
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(sent, [3]);
    expect(store.values['fp'], 4);
    await incoming.close();
  });

  test('ping 上的 head_seq 不比本地新就不发请求', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    final sent = <int>[];
    final store = MemoryHubSeqStore()..values['fp'] = 3;
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        sent.add(frame['since_seq'] as int);
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {'type': 'ping', 'timestamp': 1, 'head_seq': 3},
    ));
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(sent, isEmpty);
    await incoming.close();
  });

  test('续传回合的 chunk 合并落库，最后一个也不丢', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 3;
    final channelId = 'dm_live_$suffix';
    final agentId = 'agent-live-$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Live',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-live-$suffix',
      watchingTurn: (_) => false,
    );
    client.start();
    addTearDown(client.dispose);

    const turnId = 'turn-live';
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {'turn_id': turnId},
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (final piece in const ['你', '好', '呀']) {
      incoming.add(PeerControlEvent(
        peerId: 'peer-1',
        data: {
          'type': 'pouch_turn_event',
          'request_id': turnId,
          'kind': 'chunk',
          'chunk': piece,
        },
      ));
    }
    // 合并窗口（100ms）之后，累积正文应完整落在占位行上。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(row?['content'], '你好呀');

    // done 时再补一次，避免尾巴卡在窗口里。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {'type': 'pouch_turn_event', 'request_id': turnId, 'kind': 'done'},
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await incoming.close();
  });

  test('别的端发起的回合占位写到本机正在看的 psess_ 会话', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 11;
    final bareId = 'dm_she_user_$suffix';
    final psessId = 'psess_$bareId';
    const agentId = 'she-builtin-agent-001';
    await db.createChannel(
      Channel.withMemberIds(
        id: psessId,
        name: 'She',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-psess-$suffix',
      watchingTurn: (_) => false,
    );
    client.start();
    addTearDown(client.dispose);

    const turnId = 'turn-psess';
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': bareId,
          'agent_id': agentId,
          'data': {
            'turn_id': turnId,
            'channel_id': bareId,
            'agent_id': agentId,
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final row = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(row?['channel_id'], psessId);
    expect(client.channelHasLiveTurn(psessId), isTrue);
    expect(client.channelHasLiveTurn(bareId), isFalse);
    await db.deleteMessage(liveTurnPlaceholderId(turnId));
    await incoming.close();
  });

  test('live 事件突发时按顺序串行，游标落在最后一帧', () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    // 读得越晚的帧回得越快：不串行时后到的帧先写游标，先到的后写，游标会倒退。
    final store = _ReversedReadHubSeqStore();
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'events_sync_req') {
          incoming.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'events_sync_resp',
              'request_id': frame['request_id'],
              'events': const <Map<String, dynamic>>[],
              'head_seq': store.values['fp'] ?? 0,
              'reset': false,
            },
          ));
        }
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );
    client.start();
    addTearDown(client.dispose);

    for (var seq = 1; seq <= 30; seq++) {
      incoming.add(PeerControlEvent(
        peerId: 'peer-1',
        data: {
          'type': 'hub_event',
          'event': {
            'seq': seq,
            'kind': 'agents.changed',
            'data': <String, dynamic>{},
          },
        },
      ));
    }
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (store.values['fp'] == 30) break;
    }

    expect(store.values['fp'], 30);
    await incoming.close();
  });

  test('attach 丢失后清理流式占位', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 8;
    final channelId = 'dm_attach_lost_$suffix';
    final agentId = 'agent-attach-lost-$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Attach Lost',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final attachRequestIds = <String>[];
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, frame) async {
        if (frame['type'] == 'turn_attach_req') {
          attachRequestIds.add(frame['request_id'] as String);
        }
        return true;
      },
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-attach-lost-$suffix',
      watchingTurn: (_) => false,
    );
    client.start();
    addTearDown(client.dispose);

    const turnId = 'turn-attach-lost';
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {'turn_id': turnId, 'channel_id': channelId},
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (attachRequestIds.isNotEmpty) break;
    }
    expect(attachRequestIds, isNotEmpty);

    final placeholder = await db.getMessageById(liveTurnPlaceholderId(turnId));
    expect(placeholder, isNotNull);
    final liveChannelId = placeholder!['channel_id'] as String;
    expect(client.channelHasLiveTurn(liveChannelId), isTrue);

    // 主机找不到这个回合：用 attach 请求的 id 回 agent_error（end_reason=lost）。
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'agent_error',
        'request_id': attachRequestIds.single,
        'code': 'attach_lost',
        'message': 'turn is gone',
        'end_reason': 'lost',
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (await db.getMessageById(liveTurnPlaceholderId(turnId)) == null) {
        break;
      }
    }

    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNull);
    expect(client.channelHasLiveTurn(liveChannelId), isFalse);
    await incoming.close();
  });

  test('pouch_turn_event error 清理流式占位', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 9;
    final channelId = 'dm_turn_error_$suffix';
    final agentId = 'agent-turn-error-$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Turn Error',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-turn-error-$suffix',
      watchingTurn: (_) => false,
    );
    client.start();
    addTearDown(client.dispose);

    const turnId = 'turn-error';
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'turn.started',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {'turn_id': turnId, 'channel_id': channelId},
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (await db.getMessageById(liveTurnPlaceholderId(turnId)) != null) {
        break;
      }
    }
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNotNull);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'pouch_turn_event',
        'request_id': turnId,
        'kind': 'chunk',
        'chunk': '半句话',
      },
    ));
    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'pouch_turn_event',
        'request_id': turnId,
        'kind': 'error',
        'message': 'boom',
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (await db.getMessageById(liveTurnPlaceholderId(turnId)) == null) {
        break;
      }
    }

    // 错误之后没有 turn.finished 兜底，占位不删就永远停在 streaming。
    expect(await db.getMessageById(liveTurnPlaceholderId(turnId)), isNull);
    await incoming.close();
  });

  test('reset 之后作废历史同步进度', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_reset_$suffix';
    final agentId = 'agent_reset_$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Reset',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    await db.upsertPeerHistoryCursor(
      PeerHistoryCursorEntry(
        channelId: channelId,
        remoteSessionId: 'remote_$suffix',
        cursor: 'cursor-1',
        total: 5,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await PeerAgentClientService.instance
        .setLastHistorySyncAt(agentId, DateTime.now().toUtc());

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final store = MemoryHubSeqStore()..values['fp'] = 10;
    final client = HubEventClient(
      events: incoming.stream,
      send: (peerId, frame) async {
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'events_sync_resp',
            'request_id': frame['request_id'],
            'events': [
              {
                'seq': 20,
                'kind': 'agents.changed',
                'data': <String, dynamic>{}
              },
            ],
            'head_seq': 20,
            'reset': true,
          },
        ));
        return true;
      },
      seqStore: store,
      fingerprintOf: (_) async => 'fp',
    );

    await client.catchUp('peer-1');

    // 事件日志被裁掉那段补不回来，本地记的进度不再可信，交给下次打开会话
    // 时从头重建。
    expect(await db.getPeerHistoryCursor(channelId), isNull);
    expect(
      await PeerAgentClientService.instance.getLastHistorySyncAt(agentId),
      isNull,
    );
    await incoming.close();
  });

  test('主机回传的 peerhist_ 行取代本机同 id 的用户消息，不留下两条', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 4;
    final channelId = 'dm_twin_$suffix';
    final agentId = 'agent-twin-$suffix';
    final localId = 'u-twin-$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Twin',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    // 发送时本机先用这个 id 落库；主机沿用同一个 id 回传。
    await db.createMessage(
      id: localId,
      channelId: channelId,
      senderId: 'user',
      senderType: 'user',
      senderName: 'Me',
      content: '同一条提问',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-twin-$suffix',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {
            'id': 'peerhist_$localId',
            'channel_id': channelId,
            'agent_id': agentId,
            'content': '同一条提问',
            'type': 'text',
            'from': {'id': 'user', 'type': 'user', 'name': 'Me'},
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await db.getMessageById(localId), isNull);
    expect(await db.getMessageById('peerhist_$localId'), isNotNull);
    await incoming.close();
  });

  test('本机行已经是主机形态时不会重键，引用也不会悬空', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 7;
    final channelId = 'dm_sameform_$suffix';
    final agentId = 'agent-sameform-$suffix';
    final localId = 'peerhist_u-sameform-$suffix';
    final replyRowId = 'a-sameform-$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'SameForm',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    // 第三方 agent 的 DM：本机落库时就用主机回包的形态，主机回包里 id 逐字相同。
    await db.createMessage(
      id: localId,
      channelId: channelId,
      senderId: 'user',
      senderType: 'user',
      senderName: 'Me',
      content: '同一条提问',
    );
    await db.createMessage(
      id: replyRowId,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'Agent',
      content: '正在流式回复',
      metadata: const {'status': 'streaming'},
      replyToId: localId,
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-sameform-$suffix',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {
            'id': localId,
            'channel_id': channelId,
            'agent_id': agentId,
            'content': '同一条提问',
            'type': 'text',
            'from': {'id': 'user', 'type': 'user', 'name': 'Me'},
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final rows = await db.getChannelMessages(channelId);
    expect(rows.where((r) => r['id'] == localId).length, 1);
    expect(await db.getMessageById('u-sameform-$suffix'), isNull);
    final replyRow = await db.getMessageById(replyRowId);
    expect(replyRow!['reply_to_id'], localId);
    await incoming.close();
  });

  test('用户行被 peerhist_ 重键时，指向它的引用一起搬过去', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 6;
    final channelId = 'dm_requote_$suffix';
    final agentId = 'agent-requote-$suffix';
    final localId = 'u-requote-$suffix';
    final replyRowId = 'a-requote-$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'ReQuote',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    // 发送时本机先落这条裸 id 的提问，助手那条回复行引用的就是它。
    await db.createMessage(
      id: localId,
      channelId: channelId,
      senderId: 'user',
      senderType: 'user',
      senderName: 'Me',
      content: '引用了上一条的提问',
    );
    await db.createMessage(
      id: replyRowId,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'Agent',
      content: '正在流式回复',
      metadata: const {'status': 'streaming'},
      replyToId: localId,
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-requote-$suffix',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {
            'id': 'peerhist_$localId',
            'channel_id': channelId,
            'agent_id': agentId,
            'content': '引用了上一条的提问',
            'type': 'text',
            'from': {'id': 'user', 'type': 'user', 'name': 'Me'},
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // 提问行换了 id，但流式那条留下来的回复行指着新 id —— 不再是悬空引用
    // （否则整列重建时气泡上会渲染出「原消息不可用」）。
    expect(await db.getMessageById(localId), isNull);
    expect(await db.getMessageById('peerhist_$localId'), isNotNull);
    final replyRow = await db.getMessageById(replyRowId);
    expect(replyRow, isNotNull);
    expect(replyRow!['reply_to_id'], 'peerhist_$localId');
    await incoming.close();
  });

  test('惜宝形态的引用按裸 id 落库，不套 peerhist_ 前缀', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 4;
    final channelId = 'dm_she_quote_$suffix';
    final agentId = 'she-builtin-agent-001';
    final targetId = 'she-msg-$suffix';
    final quoteId = 'she-quote-$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'SheQuote',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    // 惜宝通道的行是裸 id（主机那条 emit 路径不带前缀）。
    await db.createMessage(
      id: targetId,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'She',
      content: '被引用的那条',
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-shequote-$suffix',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {
            'id': quoteId,
            'channel_id': channelId,
            'agent_id': agentId,
            'content': '引用上一句',
            'type': 'text',
            'reply_to': targetId,
            'from': {'id': 'user', 'type': 'user', 'name': 'Me'},
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final row = await db.getMessageById(quoteId);
    expect(row, isNotNull);
    // 一律套 `peerhist_` 会指向一条本机不存在的行。
    expect(row!['reply_to_id'], targetId);
    await incoming.close();
  });

  test('主机回传的助手 peerhist_ 行收掉本机 uuid 副本，并留下 thinking', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch + 5;
    final channelId = 'dm_reply_twin_$suffix';
    final agentId = 'agent-reply-$suffix';
    final requestId = 'req-$suffix';
    final localId = 'local-reply-$suffix';

    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Reply Twin',
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
    await db.createMessage(
      id: localId,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: '同一段回复',
      metadata: {
        'request_id': requestId,
        'progress_content': '先想了一下',
        'collapsible_title': 'Thinking',
      },
    );

    final incoming = StreamController<PeerControlEvent>.broadcast();
    final client = HubEventClient(
      events: incoming.stream,
      send: (_, __) async => true,
      seqStore: MemoryHubSeqStore(),
      fingerprintOf: (_) async => 'fp-reply-$suffix',
    );
    client.start();
    addTearDown(client.dispose);

    incoming.add(PeerControlEvent(
      peerId: 'peer-1',
      data: {
        'type': 'hub_event',
        'event': {
          'seq': 1,
          'kind': 'message.created',
          'channel_id': channelId,
          'agent_id': agentId,
          'data': {
            'id': 'peerhist_$requestId',
            'channel_id': channelId,
            'agent_id': agentId,
            'content': '同一段回复',
            'type': 'text',
            'from': {'id': agentId, 'type': 'agent', 'name': 'A'},
          },
        },
      },
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (await db.getMessageById('peerhist_$requestId') != null) break;
    }

    expect(await db.getMessageById(localId), isNull);
    final mirrored = await db.getMessageById('peerhist_$requestId');
    expect(mirrored, isNotNull);
    final rawMeta = mirrored!['metadata'] as String?;
    expect(rawMeta, isNotNull);
    final meta = jsonDecode(rawMeta!) as Map<String, dynamic>;
    expect(meta['progress_content'], '先想了一下');
    expect(meta['collapsible_title'], 'Thinking');
    await incoming.close();
  });
}
