/// Pure send-path gating for [ChatController.sendMessage].
enum ChatSendDisposition {
  /// Nothing to send.
  empty,

  /// DM send attempted without a selected agent.
  noAgent,

  /// Text-only (or text+attachments) while another turn is in flight → queue text.
  queueText,

  /// Attachments only (no text) on DM → send each attachment.
  attachmentsOnly,

  /// Group text path.
  sendGroup,

  /// DM text path.
  sendDm,
}

class ChatSendPlanner {
  ChatSendPlanner._();

  /// 「这条立刻发还是排队」由主机 SessionRuntime 裁决，App 一律把消息交出去。
  /// 不再看本地 `isProcessing`：旧代码用它把「上一轮还在跑」的消息塞进本地
  /// 队列，而 App 判「还在跑」又靠静默秒数猜，正是状态分叉的根源。
  static ChatSendDisposition decide({
    required String content,
    required bool hasAttachments,
    required bool isGroupMode,
    required bool hasAgent,
  }) {
    final hasText = content.isNotEmpty;
    if (!hasText && !hasAttachments) return ChatSendDisposition.empty;
    if (!isGroupMode && !hasAgent) return ChatSendDisposition.noAgent;
    if (!hasText && hasAttachments) return ChatSendDisposition.attachmentsOnly;
    if (isGroupMode) return ChatSendDisposition.sendGroup;
    return ChatSendDisposition.sendDm;
  }
}
