import 'event_delivery.dart';

/// Registered metadata for a single event type (mirrors [CliCommand]).
class EventTypeDefinition {
  final String id;
  final String description;
  final EventDeliveryPolicy defaultDelivery;
  final List<String> requiredEnvelopeKeys;
  final List<String> requiredScopeKeys;
  final String? dedupeKeyTemplate;
  final Set<String> supportedPlatforms;

  const EventTypeDefinition({
    required this.id,
    required this.description,
    this.defaultDelivery = EventDelivery.pollOnly,
    this.requiredEnvelopeKeys = const [],
    this.requiredScopeKeys = const [],
    this.dedupeKeyTemplate,
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
      };
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
