/// Token counts from a provider response (OpenAI / Claude compatible).
class LlmTokenUsage {
  final int? inputTokens;
  final int? outputTokens;

  const LlmTokenUsage({this.inputTokens, this.outputTokens});

  bool get hasAny =>
      (inputTokens != null && inputTokens! > 0) ||
      (outputTokens != null && outputTokens! > 0);

  /// Merge preferring non-null values from [other] (later chunks win).
  LlmTokenUsage merge(LlmTokenUsage? other) {
    if (other == null) return this;
    return LlmTokenUsage(
      inputTokens: other.inputTokens ?? inputTokens,
      outputTokens: other.outputTokens ?? outputTokens,
    );
  }

  /// Parse OpenAI (`prompt_tokens`/`completion_tokens`) or Claude
  /// (`input_tokens`/`output_tokens`) usage objects.
  static LlmTokenUsage? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final input = asInt(m['prompt_tokens']) ?? asInt(m['input_tokens']);
    final output =
        asInt(m['completion_tokens']) ?? asInt(m['output_tokens']);
    if (input == null && output == null) return null;
    return LlmTokenUsage(inputTokens: input, outputTokens: output);
  }
}
