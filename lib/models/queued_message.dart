import 'mention_entry.dart';
import 'attachment_data.dart';

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

  final DateTime createdAt;

  QueuedMessage({
    required this.id,
    required this.content,
    this.replyToId,
    this.replyQuoteText,
    this.mentions = const [],
    this.attachments,
    this.instructionName,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}
