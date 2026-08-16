import '../../models/attachment_data.dart';
import '../../models/message.dart';

/// Per-message implicit prompts for store:// / pouch attachments.
///
/// Persisted on the message row as [metaKey] (and optional [urisMetaKey]),
/// kept out of user-visible [Message.content]. Assembled into LLM / peer wire
/// content at send time.
class MessageImplicitPrompt {
  MessageImplicitPrompt._();

  static const markerOpen = '[implicit]';
  static const markerClose = '[/implicit]';

  /// DB / wire metadata key for the rendered hint block.
  static const metaKey = 'implicit_prompt';

  /// Optional structured URI list alongside [metaKey].
  static const urisMetaKey = 'store_uris';

  /// Matches well-formed `store://<space>/<16-hex device>/<path>` URIs
  /// (stops at whitespace / `]` / `)`).
  ///
  /// Strict on purpose: placeholders (`store://xxx`) and doc templates
  /// (`store://<space>/<device>/<path>`) mentioned while *discussing* the
  /// protocol must not trigger the implicit read hint. The store layer
  /// always mints this shape (see ArtifactService / DeviceIdentity).
  /// Spaces are intentionally not enumerated so new spaces need no change.
  static final RegExp storeUriPattern = RegExp(
    r'store://[a-z]+/[0-9a-f]{16}/[^\s\]\)<>]+',
  );

  static final RegExp _blockPattern = RegExp(
    r'\[implicit\][\s\S]*?\[/implicit\]',
    multiLine: true,
  );

  /// True when [text] already carries an `[implicit]…[/implicit]` block.
  static bool containsImplicitBlock(String text) =>
      text.contains(markerOpen) && text.contains(markerClose);

  /// Read a persisted hint from message / attachment metadata.
  static String? fromMetadata(Map<String, dynamic>? metadata) {
    final raw = metadata?[metaKey];
    if (raw is! String || raw.isEmpty) return null;
    return raw;
  }

  /// Merge hint (+ optional URI list) into a metadata map (mutates [target]).
  static void putInMetadata(
    Map<String, dynamic> target, {
    String? hint,
    Iterable<String>? uris,
  }) {
    if (hint != null && hint.isNotEmpty) {
      target[metaKey] = hint;
    }
    if (uris != null) {
      final list = uris.where((u) => u.isNotEmpty).toSet().toList()..sort();
      if (list.isNotEmpty) target[urisMetaKey] = list;
    }
  }

  /// Build metadata map for a new message that may reference store://.
  static Map<String, dynamic>? metadataForTurn({
    required String text,
    List<AttachmentData>? attachments,
  }) {
    final uris = collectUris(text: text, attachments: attachments);
    final hint = renderStoreReadHint(uris);
    if (hint == null) return null;
    final meta = <String, dynamic>{};
    putInMetadata(meta, hint: hint, uris: uris);
    return meta;
  }

  /// Collect store:// URIs from text + attachment extras / descriptions.
  static Set<String> collectUris({
    String text = '',
    List<AttachmentData>? attachments,
  }) {
    final uris = <String>{...extractStoreUris(text)};
    if (attachments != null) {
      for (final a in attachments) {
        final uri = a.extraMetadata?['store_uri'] as String?;
        if (uri != null && uri.isNotEmpty) uris.add(uri);
        uris.addAll(extractStoreUris(a.textDescription));
        final listed = a.extraMetadata?[urisMetaKey];
        if (listed is List) {
          for (final item in listed) {
            if (item is String && item.isNotEmpty) uris.add(item);
          }
        }
      }
    }
    return uris;
  }

  /// Build store-read hint from current-turn attachments, or null if none.
  static String? forAttachments(List<AttachmentData>? attachments) {
    if (attachments == null || attachments.isEmpty) return null;
    for (final a in attachments) {
      final stored = fromMetadata(a.extraMetadata);
      if (stored != null) return stored;
    }
    return renderStoreReadHint(collectUris(attachments: attachments));
  }

  /// Hint for a history [Message]: prefer persisted metadata, else synthesize.
  ///
  /// Prefer [urisFromMessage] + Scope Card fold for LLM turns; this long form
  /// remains for peer wire / metadata persistence.
  static String? forHistoryMessage(Message m) {
    final stored = fromMetadata(m.metadata);
    if (stored != null) return stored;
    if (containsImplicitBlock(m.content)) {
      return extractImplicitBlock(m.content);
    }
    return renderStoreReadHint(urisFromMessage(m));
  }

  /// Structured + inline store URIs on a single message (no long hint render).
  static Set<String> urisFromMessage(Message m) {
    final uris = <String>{};
    final metaUri = m.metadata?['store_uri'] as String?;
    if (metaUri != null && metaUri.isNotEmpty) uris.add(metaUri);
    final listed = m.metadata?[urisMetaKey];
    if (listed is List) {
      for (final item in listed) {
        if (item is String && item.isNotEmpty) uris.add(item);
      }
    }
    final fromHint = fromMetadata(m.metadata);
    if (fromHint != null) uris.addAll(extractStoreUris(fromHint));
    uris.addAll(extractStoreUris(m.content));
    return uris;
  }

  /// Collect store URIs across history messages.
  static Set<String> collectUrisFromMessages(Iterable<Message> messages) {
    final out = <String>{};
    for (final m in messages) {
      out.addAll(urisFromMessage(m));
    }
    return out;
  }

  /// Scan chat-map history (role/content) for store:// after enrich/strip.
  static Set<String> collectUrisFromChatMaps(
    Iterable<Map<String, dynamic>> messages,
  ) {
    final out = <String>{};
    for (final m in messages) {
      final c = m['content'];
      if (c is String) {
        out.addAll(extractStoreUris(c));
      } else if (c is List) {
        for (final part in c) {
          if (part is Map && part['text'] is String) {
            out.addAll(extractStoreUris(part['text'] as String));
          }
        }
      }
      final info = m['attachment_info'];
      if (info is Map && info['store_uri'] is String) {
        final u = info['store_uri'] as String;
        if (u.isNotEmpty) out.add(u);
      }
    }
    return out;
  }

  /// Build store-read hint from current-turn attachments, or null if none.
  static String? forUserText(String text) {
    if (containsImplicitBlock(text)) return extractImplicitBlock(text);
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
    if (attachments != null) {
      for (final a in attachments) {
        final stored = fromMetadata(a.extraMetadata);
        if (stored != null) return stored;
      }
    }
    return renderStoreReadHint(
      collectUris(text: text, attachments: attachments),
    );
  }

  /// Enrich a peer `agent_chat.message` for the wire only (do not put in bubble).
  static String forPeerWireMessage({
    required String message,
    List<AttachmentData>? attachments,
    Map<String, dynamic>? messageMetadata,
  }) {
    if (containsImplicitBlock(message)) return message;
    final fromMeta = fromMetadata(messageMetadata);
    if (fromMeta != null) return appendHint(message, fromMeta);
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

  /// First `[implicit]…[/implicit]` block in [text], or null.
  static String? extractImplicitBlock(String text) {
    final match = _blockPattern.firstMatch(text);
    return match?.group(0);
  }

  /// Render the `[implicit]…[/implicit]` store-read block, or null if empty.
  static String? renderStoreReadHint(Iterable<String> uris) {
    final list = uris.where((u) => u.isNotEmpty).toSet().toList()..sort();
    if (list.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln(markerOpen)
      ..writeln('This message mentions store:// URI(s). If you need their')
      ..writeln('contents, read each with:')
      ..writeln('`shepaw store read --uri <uri-as-is>`')
      ..writeln(
          'store:// URIs are not OS paths; never read them as local files.')
      ..writeln(
          'Across paired Nexus Pouch devices the same URI is readable via store CLI.')
      ..writeln(
          'If a URI is only being discussed (not an actual reference), skip reading it.')
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

  /// Remove `[implicit]…[/implicit]` blocks for UI / DB content field.
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
