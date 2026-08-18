import '../models/message.dart';
import 'chat_streaming_text.dart';

/// Per-turn multi-agent streaming id/content maps for group chat.
///
/// Callers keep a separate `groupStreamingMessageIds` set for Stop-button UI so
/// reattach turns and send turns do not share map lifecycle.
class ChatGroupStreamingTracker {
  final Map<String, String> streamingIds = {};
  final Map<String, String> streamingContents = {};

  bool get isEmpty => streamingIds.isEmpty;

  String? idFor(String agentId) => streamingIds[agentId];

  String contentFor(String agentId) => streamingContents[agentId] ?? '';

  /// Register an agent bubble for this turn.
  void begin(
    String agentId,
    String messageId, {
    String initialContent = '',
  }) {
    streamingIds[agentId] = messageId;
    streamingContents[agentId] = initialContent;
  }

  /// Append [chunk] for [agentId]. Returns the streaming message id, or null.
  String? append(String agentId, String chunk) {
    final sid = streamingIds[agentId];
    if (sid == null) return null;
    streamingContents[agentId] = (streamingContents[agentId] ?? '') + chunk;
    return sid;
  }

  /// Apply accumulated content onto the message list/map. Preserves metadata.
  ///
  /// 自愈：reconcileGroupMessages 回合中途会把 `group_streaming_*` 占位
  /// 折叠进 DB 行（占位 id 被改名）。锚点失效时回退到同发送者的在途宿主
  /// （flush 部分行 / 残余占位）并改指，避免后续 chunk 被静默丢弃。
  Message? applyContent(
    String agentId,
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    var sid = streamingIds[agentId];
    if (sid == null) return null;
    final existing = messageIdMap[sid];
    if (existing == null || messages.indexOf(existing) == -1) {
      final host = ChatStreamingText.findStreamingHost(
        messages,
        fromId: agentId,
        group: true,
      );
      if (host == null) return null;
      streamingIds[agentId] = host.id;
      sid = host.id;
    }
    return applyContentById(
      sid,
      contentFor(agentId),
      messages,
      messageIdMap,
    );
  }

  /// Append then apply in one step.
  Message? appendAndApply(
    String agentId,
    String chunk,
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    if (append(agentId, chunk) == null) return null;
    return applyContent(agentId, messages, messageIdMap);
  }

  /// Finish an agent turn. Returns the streaming id that was removed (if any).
  String? finish(String agentId) {
    streamingContents.remove(agentId);
    return streamingIds.remove(agentId);
  }

  void clear() {
    streamingIds.clear();
    streamingContents.clear();
  }

  /// Apply content by message id (preserves routing fields + metadata).
  static Message? applyContentById(
    String messageId,
    String content,
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    final existing = messageIdMap[messageId];
    if (existing == null) return null;
    final idx = messages.indexOf(existing);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withUpdatedContent(messages[idx], content);
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    return updated;
  }

  /// Set a top-level metadata [key] to [data] on the streaming message.
  static Message? putMetadataKey(
    String messageId,
    String key,
    Map<String, dynamic> data,
    List<Message> messages,
    Map<String, Message> messageIdMap,
  ) {
    final existing = messageIdMap[messageId];
    if (existing == null) return null;
    final idx = messages.indexOf(existing);
    if (idx == -1) return null;
    final updated = ChatStreamingText.withMergedMetadata(
      messages[idx],
      {key: Map<String, dynamic>.from(data)},
    );
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    return updated;
  }
}
