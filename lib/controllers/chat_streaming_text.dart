import '../models/message.dart';

/// Pure helpers for in-flight streaming message text.
class ChatStreamingText {
  ChatStreamingText._();

  static const stoppedMarker = '[Stopped]';

  /// Append a visible stop marker, or return the marker alone when empty.
  static String withStoppedMarker(String content) {
    if (content.isNotEmpty) return '$content\n\n$stoppedMarker';
    return stoppedMarker;
  }

  /// Copy [message] with stopped content (preserves metadata / routing fields).
  static Message markMessageStopped(Message message, {String? contentOverride}) {
    return Message(
      id: message.id,
      content: withStoppedMarker(contentOverride ?? message.content),
      timestampMs: message.timestampMs,
      from: message.from,
      to: message.to,
      channelId: message.channelId,
      type: message.type,
      replyTo: message.replyTo,
      metadata: message.metadata,
    );
  }
}
