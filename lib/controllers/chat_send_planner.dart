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

  /// 本条 DM 是否按「排队回合」处理 UI。
  ///
  /// 主机还在跑上一轮时，这条 `agent_chat` 会被 SessionRuntime 收进队列，
  /// 真正开跑要等上一轮结束。此时 App 只有一份 `streaming` / `isProcessing` /
  /// `_activeTasks[channelId]`，若在发送当下就抢过去，上一轮剩下的分片会
  /// 写进新气泡，新回合反而没有占位。所以排队回合只先落用户气泡，等主机
  /// 开始这一轮（首个帧）再接管。
  ///
  /// 只决定 **UI 何时接管**，绝不决定「发不发」：消息一律交给主机裁决。
  /// 四个信号取或：主机镜像是权威，其余三个覆盖 `session.state` 尚未到达、
  /// 或上一轮刚结束但本机状态还没收口的窗口。
  static bool deferTurnUi({
    required bool hostRunning,
    required bool localProcessing,
    required bool localStreaming,
    required bool hasInflightTurn,
  }) =>
      hostRunning || localProcessing || localStreaming || hasInflightTurn;
}
