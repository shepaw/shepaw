import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/group_event_types.dart';
import 'package:shepaw/services/group/group_agent_executor.dart';
import 'package:shepaw/services/group/group_event.dart';
import 'package:shepaw/services/group/group_event_perception.dart';
import 'package:shepaw/services/group/group_event_store.dart';
import 'package:shepaw/services/group/group_interaction_handler.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/task/task_models.dart';
import 'package:uuid/uuid.dart';

GroupEventPerceptionScheduler _buildScheduler({
  required GroupEventStore store,
}) {
  final db = LocalDatabaseService();
  final uuid = const Uuid();
  Future<List<Message>> loadMessages(String channelId, {int limit = 100}) async =>
      <Message>[];

  final executor = GroupAgentExecutor(
    db: db,
    uuid: uuid,
    activeGroupTasks: <String, Map<String, GroupActiveTask>>{},
    promptBuilder: const GroupPromptBuilder(),
    interactionHandler: GroupInteractionHandler(
      db: db,
      uuid: uuid,
      acpConnections: const <String, ACPAgentConnection>{},
      notifyChannelUpdate: (_) {},
      loadChannelMessages: loadMessages,
    ),
    notifyChannelUpdate: (_) {},
    updateTypingAgentIds: () {},
    getOrCreateACPConnection: (_) => throw UnimplementedError(),
  );

  return GroupEventPerceptionScheduler(
    db: db,
    executor: executor,
    acpConnections: const <String, ACPAgentConnection>{},
    loadChannelMessages: loadMessages,
    eventStore: store,
  );
}

GroupEvent _stepCompleted() => GroupEvent(
      id: 'ge_1',
      type: GroupEventType.stepCompleted,
      channelId: 'ch_1',
      stageIndex: 0,
      stepIndex: 1,
      agentId: 'agent_1',
      agentName: 'Ada',
      summary: '步骤完成',
    );

void main() {
  late EventBus bus;
  late GroupEventStore store;

  setUp(() {
    bus = EventBus();
    registerGroupEventTypes(bus.registry);
    EventBus.configure(bus);
    bus.addSubscription(
      agentId: 'auditor',
      patterns: [const EventPattern(typeGlob: 'chat.group.*')],
    );
    store = GroupEventStore();
  });

  tearDown(() {
    EventBus.resetForTesting();
  });

  test('schedule 投影 chat.group.* 到 EventBus 且不影响群事件旧路径', () {
    final scheduler = _buildScheduler(store: store);
    scheduler.schedule(_stepCompleted());

    final inbox = bus.inboxFor('auditor');
    expect(inbox.length, 1);
    expect(inbox.first.event.type, 'chat.group.step.completed');
    // causationId 保留 GroupEvent.id，可从 event_log 回溯源事件
    expect(inbox.first.event.causationId, 'ge_1');
    expect(inbox.first.event.payload['group_event']['id'], 'ge_1');
    expect(inbox.first.event.scope.channelId, 'ch_1');

    // 旧路径（GroupEventStore + 感知）不受影响
    expect(store.recent('ch_1').map((e) => e.id), ['ge_1']);
  });

  test('投影失败被吞掉，不影响群事件记录', () {
    // 不注册 chat.group.* → emitSystem 抛 ArgumentError
    final bareBus = EventBus();
    EventBus.configure(bareBus);
    final scheduler = _buildScheduler(store: store);

    expect(() => scheduler.schedule(_stepCompleted()), returnsNormally);
    expect(store.recent('ch_1').map((e) => e.id), ['ge_1']);
  });
}
