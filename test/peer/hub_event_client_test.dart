import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
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
}
