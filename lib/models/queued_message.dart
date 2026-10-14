import 'mention_entry.dart';
import 'attachment_data.dart';
import 'message.dart';

/// 一条待发送队列中的消息。
///
/// 相比旧的 `List<String>` 队列，带 id 便于定位与逐条编辑/删除/重排，同时
/// 保留引用、群 @、附件信息，出队时透传给 [processMessage]/[processGroupMessage]
/// （旧的裸字符串队列会丢弃这些信息）。
class QueuedMessage {
  final String id;

  /// 文本内容，可编辑。
  String content;

  /// 引用消息 id（DM / 群聊共用）。
  final String? replyToId;

  /// 引用回复时选中的部分文字（可选）；为空表示引用整条消息。
  final String? replyQuoteText;

  /// 群聊 @ 提及（DM 无此概念，发送时会被忽略）。
  final List<MentionEntry> mentions;

  /// 附件（仅群聊入队路径携带；DM 附件在入队前已立即发送）。
  final List<AttachmentData>? attachments;

  /// 指令集预填标记：出队发送时写入消息 metadata，气泡只展示标题。
  final String? instructionName;

  /// 已经交到主机排队。本机不再出队重发，主机回合结束自己接着跑。
  bool hostOwned;

  final DateTime createdAt;

  QueuedMessage({
    required this.id,
    required this.content,
    this.replyToId,
    this.replyQuoteText,
    this.mentions = const [],
    this.attachments,
    this.instructionName,
    this.hostOwned = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 主机开始执行这条排队消息时，用队列 id 立刻放进对话。
  ///
  /// id 与交给主机的 `user_message_id` 相同，之后的事件和同步不会再插一条。
  Message toChatBubble({
    required String userId,
    required String userName,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final metadata = <String, dynamic>{};
    final instruction = instructionName;
    if (instruction != null && instruction.isNotEmpty) {
      metadata['instruction'] = instruction;
    }
    final quote = replyQuoteText;
    if (quote != null && quote.isNotEmpty) {
      metadata['reply_quote'] = quote;
    }
    if (mentions.isNotEmpty) {
      metadata['mentions'] = [
        for (final mention in mentions) mention.toJson(),
      ];
    }
    return Message(
      id: id,
      content: content,
      timestampMs: now,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: replyToId,
      metadata: metadata.isEmpty ? null : metadata,
    );
  }
}

/// 从各频道队列里取出 [id] 对应的那一条。没有则返回 null。
({String channelId, QueuedMessage message})? takeQueuedMessage(
  Map<String, List<QueuedMessage>> queues,
  String id,
) {
  if (id.isEmpty) return null;
  for (final entry in queues.entries) {
    final index = entry.value.indexWhere((item) => item.id == id);
    if (index == -1) continue;
    return (channelId: entry.key, message: entry.value.removeAt(index));
  }
  return null;
}
