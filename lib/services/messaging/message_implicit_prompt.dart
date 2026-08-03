import '../../models/attachment_data.dart';
import '../../models/message.dart';

/// Per-message implicit prompts injected only into LLM message content
/// (not shown in chat UI bubbles).
///
/// Today covers store:// / pouch attachments; shape is open for more kinds later.
class MessageImplicitPrompt {
  MessageImplicitPrompt._();

  /// Matches `store://…` tokens (stops at whitespace / `]` / `)`).
  static final RegExp storeUriPattern = RegExp(r'store://[^\s\]\)]+');

  /// Build store-read hint from current-turn attachments, or null if none.
  static String? forAttachments(List<AttachmentData>? attachments) {
    if (attachments == null || attachments.isEmpty) return null;
    final uris = <String>{};
    for (final a in attachments) {
      final uri = a.extraMetadata?['store_uri'] as String?;
      if (uri != null && uri.isNotEmpty) uris.add(uri);
      uris.addAll(extractStoreUris(a.textDescription));
    }
    return renderStoreReadHint(uris);
  }

  /// Build hint from a history [Message] (metadata + content scan).
  static String? forHistoryMessage(Message m) {
    final uris = <String>{};
    final metaUri = m.metadata?['store_uri'] as String?;
    if (metaUri != null && metaUri.isNotEmpty) uris.add(metaUri);
    uris.addAll(extractStoreUris(m.content));
    return renderStoreReadHint(uris);
  }

  /// Scan free-form user text for store:// links.
  static String? forUserText(String text) =>
      renderStoreReadHint(extractStoreUris(text));

  /// Merge attachment + user-text triggers for the current turn.
  static String? forCurrentTurn({
    required String text,
    List<AttachmentData>? attachments,
  }) {
    final uris = <String>{
      ...extractStoreUris(text),
    };
    if (attachments != null) {
      for (final a in attachments) {
        final uri = a.extraMetadata?['store_uri'] as String?;
        if (uri != null && uri.isNotEmpty) uris.add(uri);
        uris.addAll(extractStoreUris(a.textDescription));
      }
    }
    return renderStoreReadHint(uris);
  }

  /// Extract distinct store:// URIs from [text], stripping trailing punctuation.
  static Set<String> extractStoreUris(String text) {
    if (!text.contains('store://')) return const {};
    final out = <String>{};
    for (final match in storeUriPattern.allMatches(text)) {
      var uri = match.group(0)!;
      while (uri.isNotEmpty &&
          (uri.endsWith('.') ||
              uri.endsWith(',') ||
              uri.endsWith(';') ||
              uri.endsWith(':'))) {
        uri = uri.substring(0, uri.length - 1);
      }
      if (uri.startsWith('store://')) out.add(uri);
    }
    return out;
  }

  /// Render the `[implicit]…[/implicit]` store-read block, or null if empty.
  static String? renderStoreReadHint(Iterable<String> uris) {
    final list = uris.where((u) => u.isNotEmpty).toSet().toList()..sort();
    if (list.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('[implicit]')
      ..writeln('This message references store:// URI(s). Read with:')
      ..writeln('`shepaw store read --uri <uri-as-is>`')
      ..writeln(
          'Do not use os.file.read / OS paths for store:// links.')
      ..writeln('URIs: ${list.join(', ')}')
      ..write('[/implicit]');
    return buf.toString();
  }

  /// Append [hint] to [base] if non-null/non-empty.
  static String appendHint(String base, String? hint) {
    if (hint == null || hint.isEmpty) return base;
    if (base.isEmpty) return hint;
    return '$base\n$hint';
  }
}
