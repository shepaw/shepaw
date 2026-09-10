import 'event_delivery.dart';
import 'event_namespace_registry.dart';
import 'event_type_definition.dart';

void registerWorkflowEventTypes(EventNamespaceRegistry registry) {
  registry.registerAll([
    const EventTypeDefinition(
      id: 'workflow.approval.pending',
      description: '1:1 workflow create awaiting user approval',
      defaultDelivery: EventDelivery.passive,
      requiredEnvelopeKeys: ['correlationId'],
      requiredScopeKeys: ['channelId'],
    ),
    const EventTypeDefinition(
      id: 'workflow.approval.resolved',
      description: 'User approved or rejected workflow plan',
      defaultDelivery: EventDelivery.passive,
      requiredEnvelopeKeys: ['correlationId'],
      requiredScopeKeys: ['channelId'],
    ),
  ]);
}

void registerStoreEventTypes(EventNamespaceRegistry registry) {
  registry.registerAll([
    const EventTypeDefinition(
      id: 'store.file.changed',
      description: 'Storage bag file created/modified/deleted',
      defaultDelivery: EventDelivery.pollOnly,
      requiredScopeKeys: ['ownerId'],
      // 同一文件同一变更类型 60s 内只记一条：目录监听在批量拷贝/保存时
      // 会产生大量重复事件。
      dedupeKeyTemplate:
          '{type}:{scope.owner_id}:{payload.uri}:{payload.change}',
    ),
    const EventTypeDefinition(
      id: 'store.backup.completed',
      description: 'Backup job completed',
      defaultDelivery: EventDelivery.pollOnly,
      requiredScopeKeys: ['ownerId'],
    ),
    const EventTypeDefinition(
      id: 'store.backup.failed',
      description: 'Backup job failed',
      defaultDelivery: EventDelivery.pollOnly,
      requiredScopeKeys: ['ownerId'],
    ),
  ]);
}

void registerChatEventTypes(EventNamespaceRegistry registry) {
  registry.register(const EventTypeDefinition(
    id: 'chat.message.mention',
    description: 'Agent was @mentioned in a channel',
    defaultDelivery: EventDelivery.active,
    requiredScopeKeys: ['channelId', 'agentId'],
  ));
  registry.register(const EventTypeDefinition(
    id: 'system.app.lifecycle',
    description: 'App foreground/background lifecycle',
    defaultDelivery: EventDelivery.pollOnly,
  ));
}
