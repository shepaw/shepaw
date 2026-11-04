import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/group/group_session_commands.dart';
import 'package:shepaw/peer/services/hub_session_create.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  test('group create falls back to the scoped agent id (the group admin)',
      () async {
    final incoming = StreamController<PeerControlEvent>.broadcast();
    Map<String, dynamic>? sent;
    final host = HubSessionCreate(
      peerId: 'peer-1',
      events: incoming.stream,
      send: (peerId, frame) async {
        sent = Map<String, dynamic>.from(frame);
        incoming.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'session_create_resp',
            'request_id': frame['request_id'],
            'success': true,
          },
        ));
        return true;
      },
    );

    final result = await GroupSessionCreateCommand(host: host).execute({
      'channel': 'group_1',
      'reason': 'topic_shift',
      'handoff-json':
          '{"task":{"user_goal":"做完 X","status":"in_progress"}}',
    });

    expect(result['success'], isTrue);
    expect(sent, isNotNull);
    // 没传 --agent_id：身份必须来自 Zone，否则群 admin 建不了会话。
    expect(sent!['agent_id'], isNotEmpty);
    expect(sent!['kind'], 'group');
    expect(sent!['group_id'], 'group_1');
    expect(sent!['channel_id'], 'group_1');
    expect(sent!['summary'], '做完 X');
    expect((sent!['handoff'] as Map)['task']['user_goal'], '做完 X');
    await incoming.close();
  });
}
