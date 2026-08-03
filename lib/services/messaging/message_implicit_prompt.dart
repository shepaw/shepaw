import '../../models/attachment_data.dart';
import '../../models/message.dart';

/// Per-message implicit prompts injected only into LLM message content
/// (not shown in chat UI bubbles).
///
/// Today covers store:// / pouch attachments; shape is open for more kinds later.
class MessageImplicitPrompt {
  MessageImplicitPrompt._();

  static const markerOpen = '[implicit]';
  static const markerClose = '[/implicit]';

  /// Matches `store://…` tokens (stops at whitespace / `]` / `)`).
  static final RegExp storeUriPattern = RegExp(r'store://[^\s\]\)]+');

  /// True when [text] already carries an `[implicit]…[/implicit]` block.
  static bool containsImplicitBlock(String text) =>
      text.contains(markerOpen) && text.contains(markerClose);

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
    if (containsImplicitBlock(m.content)) return null;
    final uris = <String>{};
    final metaUri = m.metadata?['store_uri'] as String?;
    if (metaUri != null && metaUri.isNotEmpty) uris.add(metaUri);
    uris.addAll(extractStoreUris(m.content));
    return renderStoreReadHint(uris);
  }

  /// Scan free-form user text for store:// links.
  static String? forUserText(String text) {
    if (containsImplicitBlock(text)) return null;
    return renderStoreReadHint(extractStoreUris(text));
  }

  /// Merge attachment + user-text triggers for the current turn.
  ///
  /// Returns null when [text] already has an implicit block (e.g. peer wire
  /// message that was enriched on the sender) to avoid double injection.
  static String? forCurrentTurn({
    required String text,
    List<AttachmentData>? attachments,
  }) {
    if (containsImplicitBlock(text)) return null;
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

  /// Enrich a peer `agent_chat.message` for the wire only (do not persist).
  ///
  /// Keeps Nexuspouch `store://` read instructions on the wire so the remote
  /// agent can follow them even without this app's system-prompt scaffolding.
  static String forPeerWireMessage({
    required String message,
    List<AttachmentData>? attachments,
  }) {
    final hint = forCurrentTurn(text: message, attachments: attachments);
    return appendHint(message, hint);
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
      ..writeln(markerOpen)
      ..writeln('This message references store:// URI(s). Read with:')
      ..writeln('`shepaw store read --uri <uri-as-is>`')
      ..writeln(
          'Do not use os.file.read / OS paths for store:// links.')
      ..writeln(
          'Across paired Nexuspouch devices the same URI is readable via store CLI.')
      ..writeln('URIs: ${list.join(', ')}')
      ..write(markerClose);
    return buf.toString();
  }

  /// Append [hint] to [base] if non-null/non-empty.
  ///
  /// If [hint] is an `[implicit]` block and [base] already has one, skip
  /// (dedupe). Other hints (e.g. attachment message_id) still append.
  static String appendHint(String base, String? hint) {
    if (hint == null || hint.isEmpty) return base;
    if (hint.contains(markerOpen) && containsImplicitBlock(base)) {
      return base;
    }
    if (base.isEmpty) return hint;
    return '$base\n$hint';
  }

  /// Remove `[implicit]…[/implicit]` blocks for UI / DB persistence.
  static String stripImplicitBlocks(String text) {
    if (!containsImplicitBlock(text)) return text;
    final stripped = text.replaceAll(
      RegExp(
        r'\n?\[implicit\][\s\S]*?\[/implicit\]',
        multiLine: true,
      ),
      '',
    );
    return stripped.trimRight();
  }
}
