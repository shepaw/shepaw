import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/group_event_adapter.dart';
import 'package:shepaw/services/group/group_event.dart';

void main() {
  test('maps GroupEvent to chat.group.* type', () {
    final event = GroupEvent.stepFailed(
      channelId: 'ch_1',
      stageIndex: 0,
      stepIndex: 1,
      agentName: 'Bob',
      error: 'timeout',
    );
    final env = GroupEventAdapter.toEnvelope(event);
    expect(env.type, 'chat.group.step.failed');
    expect(env.scope.channelId, 'ch_1');
    expect(env.payload['group_event'], isA<Map>());
    expect(env.payload['summary'], isNotEmpty);
    expect(env.correlationId, isNull);
  });
}
