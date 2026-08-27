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

  /// Default DM budget (summary + recent tail). Lowered so long 1:1 chats
  /// don't dwarf the system prompt.
  static const int defaultMaxChars = 10000;

  /// Keep at least this many recent messages as raw context.
  static const int defaultKeepRecentCount = 8;

  /// Reserve roughly this many chars for the recent tail before summarizing.
  static const int defaultKeepRecentChars = 4000;

  /// Don't call the summarizer for a tiny older remainder (wait for more).
  static const int minOlderCharsToSummarize = 1200;

  /// Max chars fed into the summarizer (older transcript may be truncated).
  static const int defaultSummaryInputMaxChars = 12000;

  /// Max chars allowed for the produced summary block.
  static const int defaultSummaryMaxChars = 1200;

  /// Per-message cap when injecting / summarizing, so one dump cannot fill
  /// the whole recent window.
  static const int defaultMaxMessageChars = 2500;

  /// Minimum raw turns to keep after a summary is prepended.
  static const int minRecentAfterSummary = 4;

  /// Decide which messages to summarize vs keep.
  ///
  /// Compacts when over [maxChars], or when the conversation already fills a
  /// recent window **and** the older remainder is large enough to be worth
  /// summarizing ([minOlderCharsToSummarize]).
  static HistoryCompactionPlan plan({
    required List<Message> messages,
    int maxChars = defaultMaxChars,
    int keepRecentCount = defaultKeepRecentCount,
    int keepRecentChars = defaultKeepRecentChars,
  }) {
    final totalChars = messages.fold<int>(0, (sum, m) => sum + m.content.length);
    if (messages.isEmpty ||
        !shouldCompact(
          totalChars: totalChars,
          messageCount: messages.length,
          maxChars: maxChars,
          keepRecentCount: keepRecentCount,
          keepRecentChars: keepRecentChars,
        )) {
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

    // Tiny older remainder is not worth an LLM call — keep it raw.
    final olderChars = older.fold<int>(0, (s, m) => s + m.content.length);
    if (olderChars < minOlderCharsToSummarize && totalChars <= maxChars) {
      return HistoryCompactionPlan(
        older: const [],
        recent: List<Message>.from(messages),
        totalChars: totalChars,
      );
    }

    return HistoryCompactionPlan(
      older: older,
      recent: recent,
      totalChars: totalChars,
    );
  }

  /// Whether [plan] should split off an older window to summarize.
  static bool shouldCompact({
    required int totalChars,
    required int messageCount,
    int maxChars = defaultMaxChars,
    int keepRecentCount = defaultKeepRecentCount,
    int keepRecentChars = defaultKeepRecentChars,
  }) {
    if (totalChars > maxChars) return true;
    if (messageCount <= keepRecentCount) return false;
    return totalChars > keepRecentChars + minOlderCharsToSummarize;
  }

  /// Clip a single message so one dump cannot consume the whole budget.
  static String clipContent(
    String content, {
    int maxChars = defaultMaxMessageChars,
  }) {
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}… [${content.length} chars clipped]';
  }

  /// Drop oldest recent turns until content fits [maxChars], keeping at least
  /// [minCount] messages (the latest ones).
  static List<Message> trimRecentToBudget(
    List<Message> recent, {
    required int maxChars,
    int minCount = minRecentAfterSummary,
  }) {
    var result = List<Message>.from(recent);
    while (result.length > minCount &&
        result.fold<int>(0, (s, m) => s + m.content.length) > maxChars) {
      result = result.sublist(1);
    }
    return result;
  }

  /// Recent-window budget once a summary block is taking [summaryChars].
  static int recentBudgetAfterSummary({
    required int summaryChars,
    int maxChars = defaultMaxChars,
    int keepRecentChars = defaultKeepRecentChars,
  }) {
    final leftover = maxChars - summaryChars;
    if (leftover < keepRecentChars) return leftover < 0 ? 0 : leftover;
    return keepRecentChars;
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
      final body = clipContent(m.content);
      lines.add('$role (${m.from.name}): $body');
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

  /// Drop oldest messages until total content length fits [maxChars].
  static List<Message> fifoTruncate(List<Message> messages, int maxChars) {
    final result = List<Message>.from(messages);
    var totalChars = result.fold<int>(0, (sum, m) => sum + m.content.length);
    while (totalChars > maxChars && result.isNotEmpty) {
      totalChars -= result.first.content.length;
      result.removeAt(0);
    }
    return result;
  }

  /// Compact note describing [dropped] messages that were omitted from the
  /// in-context replay (used when no LLM summarizer is available — e.g. remote
  /// ACP members — so the loss is surfaced instead of silent).
  ///
  /// Lists how many messages and which distinct senders were dropped, so the
  /// agent knows early participants existed and can ask for details / consult
  /// the group workspace if those turns still matter.
  static String rollupNote(List<Message> dropped) {
    if (dropped.isEmpty) return '';
    final senders = <String>{};
    var totalChars = 0;
    for (final m in dropped) {
      final name = m.from.name.trim();
      if (name.isNotEmpty) senders.add(name);
      totalChars += m.content.length;
    }
    final senderList = senders.take(8).join('、');
    final more = senders.length > 8 ? ' 等 ${senders.length} 位' : '';
    return '[更早的 ${dropped.length} 条群消息已省略'
        '（约 $totalChars 字符；发送者：$senderList$more）'
        '以控制上下文长度。如需早期讨论细节，请查阅群工作空间共享产物'
        '或直接询问对应成员。]';
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
Preserve: decisions, names, how they want to be addressed, preferences, open tasks, facts the user stated, file/image message_ids, agent ids, and tool outcomes that still matter.
Omit: chit-chat, repeated acknowledgements, tool-call boilerplate, full file dumps.
Output concise plain prose only. No tools, no markdown headings, no preamble.''';
}
