import '../../models/attachment_data.dart';
import '../../storage/store_protocol.dart';

/// Per-message implicit prompts for pouch:// / pouch attachments.
///
/// Persisted on the message row as [metaKey] (and optional [urisMetaKey]),
/// kept out of user-visible content. The Hub owns wire generation now; these
/// helpers keep local metadata/display consistent and hide hints from old rows.
class MessageImplicitPrompt {
  MessageImplicitPrompt._();

  static const markerOpen = '[implicit]';
  static const markerClose = '[/implicit]';

  /// DB / wire metadata key for the rendered hint block.
  static const metaKey = 'implicit_prompt';

  /// Optional structured URI list alongside [metaKey].
  static const urisMetaKey = 'pouch_uris';

  /// Matches well-formed `pouch://<space>/<16-hex device>/<path>` URIs
  /// (stops at whitespace / `]` / `)`).
  ///
  /// Strict on purpose: placeholders (`pouch://xxx`) and doc templates
  /// (`pouch://<space>/<device>/<path>`) mentioned while *discussing* the
  /// protocol must not trigger the implicit read hint. The store layer
  /// always mints this shape (see ArtifactService / DeviceIdentity).
  /// Spaces are intentionally not enumerated so new spaces need no change.
  static final RegExp storeUriPattern = RegExp(
    r'pouch://[a-z]+/[^\s\]\)<>]+',
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

  /// Build metadata map for a new message that may reference pouch://.
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

  /// Collect pouch:// URIs from text + attachment extras / descriptions.
  static Set<String> collectUris({
    String text = '',
    List<AttachmentData>? attachments,
  }) {
    final uris = <String>{...extractStoreUris(text)};
    if (attachments != null) {
      for (final a in attachments) {
        final uri = a.extraMetadata?['pouch_uri'] as String?;
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

  /// Extract distinct pouch:// URIs from [text], stripping trailing punctuation.
  static Set<String> extractStoreUris(String text) {
    if (!containsPouchUri(text)) return const {};
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
      if (isPouchUri(uri)) out.add(uri);
    }
    return out;
  }

  /// Render the `[implicit]…[/implicit]` store-read block, or null if empty.
  static String? renderStoreReadHint(Iterable<String> uris) {
    final list = uris.where((u) => u.isNotEmpty).toSet().toList()..sort();
    if (list.isEmpty) return null;
    // Keep this byte-for-byte aligned with the Hub's `attachment_hint`
    // (crates/api/src/pouch.rs): one template on both sides.
    final buf = StringBuffer()
      ..writeln(markerOpen)
      ..writeln('This message mentions pouch:// URI(s). If you need their')
      ..writeln('contents, read each with the `pouch_read` MCP tool (or')
      ..writeln('`shepaw pouch read --uri <uri-as-is>`).')
      ..writeln(
          'pouch:// URIs are not OS paths; never read them as local files.')
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
