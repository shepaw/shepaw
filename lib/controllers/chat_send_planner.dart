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

  static ChatSendDisposition decide({
    required String content,
    required bool hasAttachments,
    required bool isGroupMode,
    required bool hasAgent,
    required bool isProcessing,
  }) {
    final hasText = content.isNotEmpty;
    if (!hasText && !hasAttachments) return ChatSendDisposition.empty;
    if (!isGroupMode && !hasAgent) return ChatSendDisposition.noAgent;
    if (!hasText && hasAttachments) return ChatSendDisposition.attachmentsOnly;
    if (isProcessing) return ChatSendDisposition.queueText;
    if (isGroupMode) return ChatSendDisposition.sendGroup;
    return ChatSendDisposition.sendDm;
  }
}
