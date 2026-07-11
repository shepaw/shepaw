import '../models/message.dart';

/// Pure helpers for in-flight streaming message text / metadata.
class ChatStreamingText {
  ChatStreamingText._();

  static const stoppedMarker = '[Stopped]';

  /// Append a visible stop marker, or return the marker alone when empty.
  static String withStoppedMarker(String content) {
    if (content.isNotEmpty) return '$content\n\n$stoppedMarker';
    return stoppedMarker;
  }

  /// Copy [message] with a new content string (preserves routing fields).
  static Message withUpdatedContent(Message message, String content) {
    return Message(
      id: message.id,
      content: content,
      timestampMs: message.timestampMs,
      from: message.from,
      to: message.to,
      channelId: message.channelId,
      type: message.type,
      replyTo: message.replyTo,
      metadata: message.metadata,
    );
  }

  /// Copy [message] merging [patch] into metadata.
  static Message withMergedMetadata(
    Message message,
    Map<String, dynamic> patch,
  ) {
    final existing = Map<String, dynamic>.from(message.metadata ?? {});
    existing.addAll(patch);
    return Message(
      id: message.id,
      content: message.content,
      timestampMs: message.timestampMs,
      from: message.from,
      to: message.to,
      channelId: message.channelId,
      type: message.type,
      replyTo: message.replyTo,
      metadata: existing,
    );
  }

  /// Copy [message] with stopped content (preserves metadata / routing fields).
  static Message markMessageStopped(Message message, {String? contentOverride}) {
    return withUpdatedContent(
      message,
      withStoppedMarker(contentOverride ?? message.content),
    );
  }

  /// Build a transient streaming placeholder bubble.
  static Message placeholder({
    required String id,
    required MessageFrom from,
    required MessageFrom to,
    int? timestampMs,
    Map<String, dynamic>? metadata,
  }) {
    return Message(
      id: id,
      content: '',
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      from: from,
      to: to,
      type: MessageType.text,
      metadata: metadata,
    );
  }
}

/// Tracks the active DM streaming bubble id + accumulated content.
class ChatStreamingSession {
  String? messageId;
  String content = '';

  bool get isActive => messageId != null;

  void begin(String id) {
    messageId = id;
    content = '';
  }

  void append(String chunk) {
    content += chunk;
  }

  void clear() {
    messageId = null;
    content = '';
  }

  /// Apply accumulated [content] onto the matching message in [messages].
  /// Returns the updated message, or null if not found.
  Message? applyContentTo(
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    final id = messageId;
    if (id == null) return null;
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withUpdatedContent(messages[idx], content);
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    return updated;
  }

  /// Merge metadata onto the active streaming message.
  Message? applyMetadataTo(
    List<Message> messages,
    Map<String, Message> messageIdMap,
    Map<String, dynamic> patch,
  ) {
    final id = messageId;
    if (id == null) return null;
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withMergedMetadata(messages[idx], patch);
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    return updated;
  }
}
