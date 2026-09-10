import 'event_delivery.dart';
import 'event_type_definition.dart';

/// Registry of built-in and plugin event types (mirrors [CliNamespaceRegistry]).
class EventNamespaceRegistry {
  /// 公共构造：`EventBus(registry: ...)` 才有意义（否则只能注入全局单例，
  /// 测试与多实例场景无法隔离类型表）。
  EventNamespaceRegistry();

  static final EventNamespaceRegistry instance = EventNamespaceRegistry();

  final Map<String, EventTypeDefinition> _types = {};

  void register(EventTypeDefinition type) {
    _types[type.id] = type;
  }

  /// 移除类型（用于 `EventBus.resetRuntimeState` 回收自动注册的
  /// `agent.<id>.*` 类型，避免长跑进程里类型表单调增长）。
  void unregister(String id) {
    _types.remove(id);
  }

  void registerAll(Iterable<EventTypeDefinition> types) {
    for (final t in types) {
      register(t);
    }
  }

  EventTypeDefinition? get(String id) => _types[id];

  Iterable<EventTypeDefinition> get all => _types.values;

  List<EventTypeDefinition> byNamespace(String namespace) {
    final prefix = '$namespace.';
    return _types.values.where((t) => t.id.startsWith(prefix)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  void reset() => _types.clear();
}

/// P0 built-in types for Fake provider / tests.
void registerP0BuiltinEventTypes(EventNamespaceRegistry registry) {
  registry.registerAll([
    const EventTypeDefinition(
      id: 'test.event.ping',
      description: 'P0 fake provider ping',
      defaultDelivery: EventDelivery.pollOnly,
      requiredEnvelopeKeys: ['correlationId'],
    ),
    const EventTypeDefinition(
      id: 'test.event.pong',
      description: 'P0 fake provider pong',
      defaultDelivery: EventDelivery.passive,
      requiredEnvelopeKeys: ['correlationId'],
      dedupeKeyTemplate: '{type}:{correlation_id}',
    ),
  ]);
}
