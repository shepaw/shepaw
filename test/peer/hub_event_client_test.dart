import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

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
                {'seq': 1, 'kind': 'agents.changed', 'data': <String, dynamic>{}},
              ]
            : [
                {'seq': 2, 'kind': 'agents.changed', 'data': <String, dynamic>{}},
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
              {'seq': 20, 'kind': 'agents.changed', 'data': <String, dynamic>{}},
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
}
