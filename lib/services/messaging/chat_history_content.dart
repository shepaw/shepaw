import '../../models/message.dart';
import '../session/dm_session_create_service.dart';
import 'local_llm_handler.dart';

/// Rules for text replayed into DM and group LLM history.
///
/// Collapsible thinking and tool-progress blocks live in
/// [Message.metadata] (`progress_content`) for the chat UI only — they are
/// never merged into orchestration history. Session-switch cards are the
/// same: UI metadata (or a system row), never replayed as chat turns.
class ChatHistoryContent {
  ChatHistoryContent._();

  /// Metadata keys holding UI-only progress/thinking — excluded from replay.
  static const uiOnlyMetadataKeys = ['progress_content'];

  /// Mark a persisted row as UI-only (switch card fallback).
  static const historyExcludeMetaKey = 'history_exclude';

  static const _switchCardPlaceholder =
      'New session ready. Open it to continue.';

  /// Human-readable policy (DM + group `history_policy` notes reference this).
  static const replayPolicyNote =
      'Replays message.content (answer text) only. Collapsible thinking and '
      'tool progress live in metadata.progress_content for the chat UI and are '
      'not injected into orchestration history.';

  /// False for system / audit / switch-card-only rows.
  static bool shouldReplay(Message m) {
    if (m.type == MessageType.system ||
        m.type == MessageType.permissionAudit) {
      return false;
    }
    if (m.metadata?[historyExcludeMetaKey] == true) return false;
    if (_isSwitchCardOnly(m)) return false;
    return true;
  }

  static bool _isSwitchCardOnly(Message m) {
    if (sessionSwitchActionOf(m.metadata) == null) return false;
    final c = m.content.trim();
    return c.isEmpty || c == _switchCardPlaceholder;
  }

  /// Answer body replayed to LLM history.
  ///
  /// Uses [Message.content] only; does not read [Message.metadata].
  static String replayContent(Message m) {
    if (m.metadata?[historyExcludeMetaKey] == true || _isSwitchCardOnly(m)) {
      return '';
    }
    return LocalLLMHelpers.enrichHistoryContent(m, m.content);
  }

  /// Like [replayContent], but prefixes user rows with [formatUserTimestamp]
  /// when provided (DM paths timestamp user messages for disambiguation).
  static String replayContentFormatted(
    Message m, {
    String Function(int timestampMs)? formatUserTimestamp,
  }) {
    if (m.metadata?[historyExcludeMetaKey] == true || _isSwitchCardOnly(m)) {
      return '';
    }
    final base = m.from.isAgent
        ? m.content
        : formatUserTimestamp != null
            ? '[${formatUserTimestamp(m.timestampMs)}] ${m.content}'
            : m.content;
    return LocalLLMHelpers.enrichHistoryContent(m, base);
  }
}
