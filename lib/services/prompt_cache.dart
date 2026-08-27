/// Helpers for LLM prompt-prefix caching (Anthropic `cache_control`, plus
/// stable prefixes that OpenAI-compatible providers cache automatically).
class PromptCache {
  PromptCache._();

  static const Map<String, String> ephemeral = {'type': 'ephemeral'};

  /// Anthropic prompt-caching beta. Harmless on proxies that ignore it.
  static const String anthropicBetaHeader = 'prompt-caching-2024-07-31';

  /// Claude Messages API `system`: cached static block + uncached volatile tail.
  static Object claudeSystem({
    required String staticPrefix,
    String dynamicSuffix = '',
  }) {
    final blocks = <Map<String, dynamic>>[];
    final a = staticPrefix.trim();
    final b = dynamicSuffix.trim();
    if (a.isNotEmpty) {
      blocks.add({
        'type': 'text',
        'text': a,
        'cache_control': ephemeral,
      });
    }
    if (b.isNotEmpty) {
      blocks.add({'type': 'text', 'text': b});
    }
    if (blocks.isEmpty) return '';
    return blocks;
  }

  /// Single Claude system blob with a cache breakpoint (stable group prompts,
  /// tool-calling rounds, etc.).
  static Object claudeSystemBlob(String text) {
    final t = text.trim();
    if (t.isEmpty) return '';
    return [
      {
        'type': 'text',
        'text': t,
        'cache_control': ephemeral,
      },
    ];
  }

  /// Attach `cache_control` to the last tool so Claude can cache the tools
  /// prefix across rounds. No-op on an empty list.
  static List<Map<String, dynamic>> markLastTool(
    List<Map<String, dynamic>> tools,
  ) {
    if (tools.isEmpty) return tools;
    final out = <Map<String, dynamic>>[
      for (var i = 0; i < tools.length - 1; i++)
        Map<String, dynamic>.from(tools[i]),
    ];
    final last = Map<String, dynamic>.from(tools.last);
    last['cache_control'] = ephemeral;
    out.add(last);
    return out;
  }
}

/// System prompt split into a cache-stable prefix and a per-turn suffix.
///
/// [full] concatenates prefix then suffix (OpenAI automatic prefix cache).
/// [toClaudeSystem] emits Anthropic content blocks with a cache breakpoint.
class BuiltSystemPrompt {
  const BuiltSystemPrompt({
    required this.staticPrefix,
    required this.dynamicSuffix,
  });

  static const empty = BuiltSystemPrompt(staticPrefix: '', dynamicSuffix: '');

  final String staticPrefix;
  final String dynamicSuffix;

  bool get isEmpty =>
      staticPrefix.trim().isEmpty && dynamicSuffix.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  String get full {
    final a = staticPrefix.trim();
    final b = dynamicSuffix.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a\n\n$b';
  }

  Object toClaudeSystem() => PromptCache.claudeSystem(
        staticPrefix: staticPrefix,
        dynamicSuffix: dynamicSuffix,
      );
}
