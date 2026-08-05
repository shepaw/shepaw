/// Token counts from a provider response (OpenAI / Claude compatible).
class LlmTokenUsage {
  /// Key under which per-message token usage is stored in
  /// [Message.metadata], e.g. `{'token_usage': {'input_tokens': 1, ...}}`.
  static const String metadataKey = 'token_usage';

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

  /// Sum with [other] — used to accumulate usage across the rounds of a
  /// multi-round tool-calling loop (unlike [merge], which prefers latest).
  LlmTokenUsage plus(LlmTokenUsage? other) {
    if (other == null) return this;
    int? sum(int? a, int? b) =>
        (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);
    return LlmTokenUsage(
      inputTokens: sum(inputTokens, other.inputTokens),
      outputTokens: sum(outputTokens, other.outputTokens),
    );
  }

  /// Persisted shape stored in message metadata. Null fields are omitted.
  Map<String, dynamic> toJson() => {
        if (inputTokens != null) 'input_tokens': inputTokens,
        if (outputTokens != null) 'output_tokens': outputTokens,
      };

  /// Read token usage back from a message `metadata` map. Tolerates both the
  /// persisted shape and raw provider aliases (see [fromJson]).
  static LlmTokenUsage? fromMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    return fromJson(metadata[metadataKey]);
  }

  /// Compact label for chat bubbles, e.g. `↑12.3k ↓456`.
  /// Null when neither direction has a positive count.
  String? get compactLabel {
    final parts = <String>[
      if (inputTokens != null && inputTokens! > 0)
        '↑${formatCount(inputTokens!)}',
      if (outputTokens != null && outputTokens! > 0)
        '↓${formatCount(outputTokens!)}',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// `999` → `999`, `1234` → `1.2k`, `12345` → `12k`, `2345678` → `2.3M`.
  static String formatCount(int n) {
    String trim(double v) {
      final s = v.toStringAsFixed(1);
      return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    }

    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return v < 100 ? '${trim(v)}k' : '${v.round()}k';
    }
    final v = n / 1000000;
    return v < 100 ? '${trim(v)}M' : '${v.round()}M';
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
