import '../../models/message.dart';
import 'local_llm_handler.dart';

/// Rules for text replayed into DM and group LLM history.
///
/// Collapsible thinking and tool-progress blocks live in
/// [Message.metadata] (`progress_content`) for the chat UI only — they are
/// never merged into orchestration history.
class ChatHistoryContent {
  ChatHistoryContent._();

  /// Metadata keys holding UI-only progress/thinking — excluded from replay.
  static const uiOnlyMetadataKeys = ['progress_content'];

  /// Human-readable policy (DM + group `history_policy` notes reference this).
  static const replayPolicyNote =
      'Replays message.content (answer text) only. Collapsible thinking and '
      'tool progress live in metadata.progress_content for the chat UI and are '
      'not injected into orchestration history.';

  /// Answer body replayed to LLM history.
  ///
  /// Uses [Message.content] only; does not read [Message.metadata].
  static String replayContent(Message m) {
    return LocalLLMHelpers.enrichHistoryContent(m, m.content);
  }

  /// Like [replayContent], but prefixes user rows with [formatUserTimestamp]
  /// when provided (DM paths timestamp user messages for disambiguation).
  static String replayContentFormatted(
    Message m, {
    String Function(int timestampMs)? formatUserTimestamp,
  }) {
    final base = m.from.isAgent
        ? m.content
        : formatUserTimestamp != null
            ? '[${formatUserTimestamp(m.timestampMs)}] ${m.content}'
            : m.content;
    return LocalLLMHelpers.enrichHistoryContent(m, base);
  }
}
