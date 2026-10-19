import '../../models/message.dart';
import 'message_implicit_prompt.dart';

/// Helpers still shared by history replay and CLI attachment rendering.
///
/// The in-app local LLM execution path has been retired (turns now run on the
/// Hub), so the tool-list / message-construction helpers are gone. Only the
/// renderers below remain in use.
class LocalLLMHelpers {
  LocalLLMHelpers._();

  /// Build lightweight attachment metadata for history entries.
  static Map<String, dynamic> buildAttachmentInfo(Message m) {
    final info = <String, dynamic>{
      'message_id': m.id,
      'type': m.type.toString().split('.').last,
      'fetch_command':
          'shepaw chat message get --id ${m.id} --analyze "describe content"',
    };
    if (m.metadata != null) {
      if (m.metadata!['name'] != null) info['file_name'] = m.metadata!['name'];
      if (m.metadata!['size'] != null) info['file_size'] = m.metadata!['size'];
      if (m.metadata!['type'] != null) info['mime_type'] = m.metadata!['type'];
      if (m.metadata!['duration_ms'] != null) {
        info['duration_ms'] = m.metadata!['duration_ms'];
      }
      final storeUri = m.metadata!['pouch_uri'] as String?;
      if (storeUri != null && storeUri.isNotEmpty) {
        info['pouch_uri'] = storeUri;
        info['pouch_read_command'] = 'shepaw pouch read --uri $storeUri';
      }
    }
    return info;
  }

  /// Append LLM-only hints so historical attachments stay actionable.
  ///
  /// History keeps a short `chat message get` hint for non-text attachments.
  /// Per-message `[implicit]` blocks are stripped: the Hub owns the
  /// store-read hint, and old rows must not replay a second copy.
  ///
  /// DM and group history call this via [ChatHistoryContent.replayContent]
  /// with [Message.content] only — `metadata.progress_content` (collapsible
  /// thinking) is UI-only and is never passed as [baseContent].
  static String enrichHistoryContent(Message m, String baseContent) {
    if (m.type == MessageType.system ||
        m.type == MessageType.permissionAudit) {
      return baseContent;
    }

    final content = MessageImplicitPrompt.stripImplicitBlocks(baseContent);

    if (m.type == MessageType.text) {
      return content;
    }

    // Non-text attachment: always surface message_id for chat message get.
    final fetchHint =
        '(attachment message_id=${m.id} — to read/analyze call: '
        'shepaw chat message get --id ${m.id} --analyze "your question")';
    return MessageImplicitPrompt.appendHint(content, fetchHint);
  }
}
