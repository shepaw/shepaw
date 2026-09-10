/// Message metadata keys for group orchestration / task scoping.
class GroupOrchestrationMetadata {
  GroupOrchestrationMetadata._();

  static const orchestrationIdKey = 'orchestration_id';
  static const orchestrationRoundKey = 'orchestration_round';

  static String? readOrchestrationId(Map<String, dynamic>? metadata) {
    final raw = metadata?[orchestrationIdKey];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Merge orchestration fields into [base] (mutates a copy).
  static Map<String, dynamic> stamp({
    Map<String, dynamic>? base,
    required String orchestrationId,
    int? orchestrationRound,
  }) {
    final out = Map<String, dynamic>.from(base ?? const {});
    out[orchestrationIdKey] = orchestrationId;
    if (orchestrationRound != null) {
      out[orchestrationRoundKey] = orchestrationRound;
    }
    return out;
  }
}
