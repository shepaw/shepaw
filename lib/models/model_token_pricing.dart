/// Rough USD pricing per million tokens for common model id substrings.
///
/// Estimates only — real bills depend on provider discounts and cached tokens.
class ModelTokenPricing {
  final double inputPerMillionUsd;
  final double outputPerMillionUsd;

  const ModelTokenPricing({
    required this.inputPerMillionUsd,
    required this.outputPerMillionUsd,
  });

  double estimateUsd({int? inputTokens, int? outputTokens}) {
    final inCost = ((inputTokens ?? 0) / 1e6) * inputPerMillionUsd;
    final outCost = ((outputTokens ?? 0) / 1e6) * outputPerMillionUsd;
    return inCost + outCost;
  }

  /// Match [modelId] against known substrings (longest / first wins).
  static ModelTokenPricing? forModel(String? modelId) {
    if (modelId == null || modelId.isEmpty) return null;
    final id = modelId.toLowerCase();
    for (final entry in _table.entries) {
      if (id.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// Conservative defaults for popular families (USD / 1M tokens).
  static const _table = <String, ModelTokenPricing>{
    'gpt-4o-mini': ModelTokenPricing(
      inputPerMillionUsd: 0.15,
      outputPerMillionUsd: 0.60,
    ),
    'gpt-4o': ModelTokenPricing(
      inputPerMillionUsd: 2.50,
      outputPerMillionUsd: 10.0,
    ),
    'gpt-4.1-mini': ModelTokenPricing(
      inputPerMillionUsd: 0.40,
      outputPerMillionUsd: 1.60,
    ),
    'gpt-4.1': ModelTokenPricing(
      inputPerMillionUsd: 2.0,
      outputPerMillionUsd: 8.0,
    ),
    'o4-mini': ModelTokenPricing(
      inputPerMillionUsd: 1.10,
      outputPerMillionUsd: 4.40,
    ),
    'claude-3-5-haiku': ModelTokenPricing(
      inputPerMillionUsd: 0.80,
      outputPerMillionUsd: 4.0,
    ),
    'claude-3-5-sonnet': ModelTokenPricing(
      inputPerMillionUsd: 3.0,
      outputPerMillionUsd: 15.0,
    ),
    'claude-sonnet-4': ModelTokenPricing(
      inputPerMillionUsd: 3.0,
      outputPerMillionUsd: 15.0,
    ),
    'claude-opus-4': ModelTokenPricing(
      inputPerMillionUsd: 15.0,
      outputPerMillionUsd: 75.0,
    ),
    'deepseek-chat': ModelTokenPricing(
      inputPerMillionUsd: 0.27,
      outputPerMillionUsd: 1.10,
    ),
    'deepseek-reasoner': ModelTokenPricing(
      inputPerMillionUsd: 0.55,
      outputPerMillionUsd: 2.19,
    ),
  };
}

/// One row of aggregated token usage (agent × day).
class TokenUsageAggregate {
  final String? agentId;
  final String day; // YYYY-MM-DD local
  final int inputTokens;
  final int outputTokens;
  final int sessionCount;
  final double? estimatedCostUsd;

  const TokenUsageAggregate({
    required this.agentId,
    required this.day,
    required this.inputTokens,
    required this.outputTokens,
    required this.sessionCount,
    this.estimatedCostUsd,
  });

  int get totalTokens => inputTokens + outputTokens;
}
