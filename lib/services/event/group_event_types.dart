import 'event_delivery.dart';
import 'event_namespace_registry.dart';
import 'event_type_definition.dart';

void registerGroupEventTypes(EventNamespaceRegistry registry) {
  const pollOnly = EventDelivery.pollOnly;
  for (final id in [
    'chat.group.member.joined',
    'chat.group.member.left',
    'chat.group.workflow.stage.started',
    'chat.group.step.completed',
    'chat.group.step.failed',
    'chat.group.step.skipped',
    'chat.group.workflow.completed',
    'chat.group.workflow.failed',
    'chat.group.loop.round.completed',
    'chat.group.member.pending',
    'chat.group.member.stalled',
  ]) {
    registry.register(EventTypeDefinition(
      id: id,
      description: 'Group event projection ($id)',
      defaultDelivery: pollOnly,
      requiredScopeKeys: const ['channelId'],
    ));
  }
}
