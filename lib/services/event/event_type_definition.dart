import 'event_delivery.dart';
import 'event_envelope.dart';
import 'event_namespace_registry.dart';

/// Registered metadata for a single event type (mirrors [CliCommand]).
class EventTypeDefinition {
  final String id;
  final String description;
  final EventDeliveryPolicy defaultDelivery;
  final List<String> requiredEnvelopeKeys;
  final List<String> requiredScopeKeys;
  final String? dedupeKeyTemplate;
  final Set<String> supportedPlatforms;

  /// notify-only 感知回合允许的 CLI 命令 id（如 `peer.accept`）。
  /// 空 = 该类型不限制；批次内多类型时取并集。
  final Set<String> perceptionCliAllowlist;

  const EventTypeDefinition({
    required this.id,
    required this.description,
    this.defaultDelivery = EventDelivery.pollOnly,
    this.requiredEnvelopeKeys = const [],
    this.requiredScopeKeys = const [],
    this.dedupeKeyTemplate,
    this.perceptionCliAllowlist = const {},
    this.supportedPlatforms = const {
      'macos',
      'linux',
      'windows',
      'android',
      'ios',
    },
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'default_delivery': defaultDelivery.wireValue,
        'required_envelope_keys': requiredEnvelopeKeys,
        'required_scope_keys': requiredScopeKeys,
        if (dedupeKeyTemplate != null) 'dedupe_key_template': dedupeKeyTemplate,
        if (perceptionCliAllowlist.isNotEmpty)
          'perception_cli_allowlist': perceptionCliAllowlist.toList()..sort(),
      };
}

/// 合并批次事件的感知 CLI 白名单；无一类型声明限制时返回 null（不限制）。
Set<String>? perceptionCliAllowlistForEvents(
  List<EventEnvelope> events,
  EventNamespaceRegistry registry,
) {
  Set<String>? merged;
  for (final event in events) {
    final allow = registry.get(event.type)?.perceptionCliAllowlist;
    if (allow == null || allow.isEmpty) continue;
    merged ??= {};
    merged.addAll(allow);
  }
  return merged;
}

/// Computes dedupe key from template placeholders.
String? computeDedupeKey(
  EventTypeDefinition typeDef, {
  required String type,
  String? correlationId,
  Map<String, dynamic>? payload,
  Map<String, String?> scopeValues = const {},
}) {
  final template = typeDef.dedupeKeyTemplate;
  if (template == null || template.isEmpty) return null;

  var result = template
      .replaceAll('{type}', type)
      .replaceAll('{correlation_id}', correlationId ?? '');

  if (payload != null) {
    for (final entry in payload.entries) {
      result = result.replaceAll('{payload.${entry.key}}', '${entry.value}');
    }
  }
  for (final entry in scopeValues.entries) {
    result = result.replaceAll('{scope.${entry.key}}', entry.value ?? '');
  }
  return result.isEmpty ? null : result;
}
