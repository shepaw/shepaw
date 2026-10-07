import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/hub_event_client.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
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
}
