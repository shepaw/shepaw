import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/pouch_turn_relay.dart';

void main() {
  test('a group turn frame carries pouch_id, group_id and session_id', () {
    final frame = PouchTurnRelay.groupTurnFrame(
      channelId: 'group_g1',
      content: '开工',
      userId: 'user',
      userName: '我',
      deviceInfo: const {'device_name': 'iPhone', 'device_id': 'dev-1'},
      pouchId: 'pouch-a',
      groupId: 'group_g1',
      sessionId: 's_1',
      userMessageId: 'peerhist_abc',
    );
    expect(frame['type'], 'pouch_group_turn');
    expect(frame['pouch_id'], 'pouch-a');
    expect(frame['group_id'], 'group_g1');
    expect(frame['session_id'], 's_1');
    expect(frame['channel_id'], 'group_g1');
    expect(frame['user_message_id'], 'abc');
    expect(frame['device_name'], 'iPhone');
  });

  test('without a chosen session the frame leaves session_id out', () {
    final frame = PouchTurnRelay.groupTurnFrame(
      channelId: 'group_g1',
      content: '继续',
      userId: 'user',
      userName: '我',
      deviceInfo: const {},
      pouchId: 'pouch-a',
      groupId: 'group_g1',
    );
    expect(frame.containsKey('session_id'), isFalse);
    expect(frame.containsKey('pouch_id'), isTrue);
  });

  test('a dm channel is not a group id', () {
    final frame = PouchTurnRelay.groupTurnFrame(
      channelId: 'dm_1',
      content: '嗨',
      userId: 'user',
      userName: '我',
      deviceInfo: const {},
    );
    expect(frame.containsKey('group_id'), isFalse);
    expect(frame.containsKey('pouch_id'), isFalse);
  });
}
