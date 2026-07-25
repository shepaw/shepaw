import '../../models/message.dart';

/// Result of planning / applying in-context history compaction.
class HistoryCompactionPlan {
  /// Older messages to summarize (may be empty when no compaction needed).
  final List<Message> older;

  /// Recent messages kept verbatim.
  final List<Message> recent;

  /// Total character count of [older] + [recent] before compaction.
  final int totalChars;

  bool get needsCompaction => older.isNotEmpty;

  const HistoryCompactionPlan({
    required this.older,
    required this.recent,
    required this.totalChars,
  });
}

/// Splits conversation history so older turns can be summarized while recent
/// turns stay raw — preserves signal that plain FIFO truncation would drop.
class HistoryCompactor {
  HistoryCompactor._();

  /// Default DM budget (matches local multi-round path).
  static const int defaultMaxChars = 20000;

  /// Keep at least this many recent messages as raw context.
  static const int defaultKeepRecentCount = 16;

  /// Reserve roughly this many chars for the recent tail before summarizing.
  static const int defaultKeepRecentChars = 8000;

  /// Max chars fed into the summarizer (older transcript may be truncated).
  static const int defaultSummaryInputMaxChars = 24000;

  /// Max chars allowed for the produced summary block.
  static const int defaultSummaryMaxChars = 2500;

  /// Decide which messages to summarize vs keep.
  ///
  /// When [totalChars] ≤ [maxChars], [older] is empty and [recent] is the full list.
  /// Otherwise keep a recent tail (by count and char budget) and put the rest in [older].
  static HistoryCompactionPlan plan({
    required List<Message> messages,
    int maxChars = defaultMaxChars,
    int keepRecentCount = defaultKeepRecentCount,
    int keepRecentChars = defaultKeepRecentChars,
  }) {
    final totalChars = messages.fold<int>(0, (sum, m) => sum + m.content.length);
    if (messages.isEmpty || totalChars <= maxChars) {
      return HistoryCompactionPlan(
        older: const [],
        recent: List<Message>.from(messages),
        totalChars: totalChars,
      );
    }

    // Grow recent from the end until we hit count or char limits.
    final recent = <Message>[];
    var recentChars = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final nextCount = recent.length + 1;
      final nextChars = recentChars + m.content.length;
      if (recent.isNotEmpty &&
          (nextCount > keepRecentCount || nextChars > keepRecentChars)) {
        break;
      }
      recent.insert(0, m);
      recentChars = nextChars;
    }

    final older = messages.sublist(0, messages.length - recent.length);
    // If everything landed in recent (pathological short messages), fall back
    // to keeping the last half raw so we still produce a useful split.
    if (older.isEmpty && messages.length > 1) {
      final splitAt = messages.length ~/ 2;
      return HistoryCompactionPlan(
        older: messages.sublist(0, splitAt),
        recent: messages.sublist(splitAt),
        totalChars: totalChars,
      );
    }

    return HistoryCompactionPlan(
      older: older,
      recent: recent,
      totalChars: totalChars,
    );
  }

  /// Linear transcript for the summarizer (oldest → newest).
  ///
  /// When the full transcript exceeds [maxChars], keeps the **tail** of the
  /// older segment (closer to recent turns) and prefixes an omission note.
  static String buildTranscript(
    List<Message> messages, {
    int maxChars = defaultSummaryInputMaxChars,
  }) {
    if (messages.isEmpty) return '';

    final lines = <String>[];
    var total = 0;
    for (final m in messages) {
      final role = m.from.isAgent ? 'Assistant' : 'User';
      lines.add('$role (${m.from.name}): ${m.content}');
      total += lines.last.length + 1;
    }

    if (total <= maxChars) return lines.join('\n');

    // Keep the end of the older segment within maxChars.
    final kept = <String>[];
    var used = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (used + line.length + 1 > maxChars && kept.isNotEmpty) break;
      kept.insert(0, line);
      used += line.length + 1;
    }
    return '[earlier omitted]\n${kept.join('\n')}';
  }

  /// Wrap a summary as a synthetic user context message for the LLM.
  static Map<String, dynamic> summaryMessage(String summary) {
    final clipped = summary.length <= defaultSummaryMaxChars
        ? summary
        : '${summary.substring(0, defaultSummaryMaxChars)}…';
    return {
      'role': 'user',
      'content':
          '[Earlier conversation summary — condensed for context]\n$clipped',
    };
  }

  /// System prompt for the compaction LLM call.
  static const summarizerSystemPrompt = '''
You compress earlier turns of a conversation for another AI assistant.
Preserve: decisions, names, preferences, open tasks, facts the user stated, file/tool outcomes that still matter.
Omit: chit-chat, repeated acknowledgements, tool-call boilerplate.
Output concise plain prose only. No tools, no markdown headings, no preamble.''';
}
