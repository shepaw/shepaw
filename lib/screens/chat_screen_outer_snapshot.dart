import '../controllers/chat_controller.dart';

/// 外层 ChatScreen build 真正消费的 controller 字段快照。
///
/// `_onControllerChanged` 用它做门控：快照相等就不 `setState`。流式
/// chunk 只改消息内容（气泡内容由 contentListenable 驱动列表子树重
/// 建），外层 Scaffold/AppBar/输入区/面板不消费这些变化，无需整页
/// rebuild。
///
/// ⚠️ 维护约定：`build` / `_buildChatScaffold` / 外层各 `_build*` 若新增
/// 读取 controller 的字段，必须同步加到这里（并参与 == 比较），否则该
/// 字段变化时 UI 会卡旧值。方法引用（回调）不参与比较。
class OuterStructuralSnapshot {
  final int messageCount;
  final String? streamingMessageId;
  final int groupStreamingCount;
  final int respondingAgentCount;
  final bool isProcessing;
  final bool isLoading;
  final bool isLoadingOlderMessages;
  final bool isGroupMode;
  final bool mentionOnlyMode;
  final bool isAgentOnline;
  final bool isCheckingHealth;
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final String? currentChannelId;
  final int groupAgentCount;
  final String? groupChannelId;
  final String? activeWorkflowId;
  final bool isViewingGroupBoundMemberSession;
  final bool isViewingSheBoundSession;
  final String? sourceGroupName;
  final String? sourceDeviceLabel;
  final bool hasReplyingTo;
  final String? highlightedMessageId;
  final int queueLength;
  final bool dmWorkflowEnabled;
  final bool showWorkflowProgressPanel;
  final bool workflowNeedsPanelAttention;
  final bool hasWorkflowPeerApproval;

  const OuterStructuralSnapshot({
    required this.messageCount,
    required this.streamingMessageId,
    required this.groupStreamingCount,
    required this.respondingAgentCount,
    required this.isProcessing,
    required this.isLoading,
    required this.isLoadingOlderMessages,
    required this.isGroupMode,
    required this.mentionOnlyMode,
    required this.isAgentOnline,
    required this.isCheckingHealth,
    required this.agentId,
    required this.agentName,
    required this.agentAvatar,
    required this.currentChannelId,
    required this.groupAgentCount,
    required this.groupChannelId,
    required this.activeWorkflowId,
    required this.isViewingGroupBoundMemberSession,
    required this.isViewingSheBoundSession,
    required this.sourceGroupName,
    required this.sourceDeviceLabel,
    required this.hasReplyingTo,
    required this.highlightedMessageId,
    required this.queueLength,
    required this.dmWorkflowEnabled,
    required this.showWorkflowProgressPanel,
    required this.workflowNeedsPanelAttention,
    required this.hasWorkflowPeerApproval
  });

  factory OuterStructuralSnapshot.of(ChatController c) {
    return OuterStructuralSnapshot(
      messageCount: c.messages.length,
      streamingMessageId: c.streamingMessageId,
      groupStreamingCount: c.groupStreamingMessageIds.length,
      respondingAgentCount: c.respondingAgentNames.length,
      isProcessing: c.isProcessing,
      isLoading: c.isLoading,
      isLoadingOlderMessages: c.isLoadingOlderMessages,
      isGroupMode: c.isGroupMode,
      mentionOnlyMode: c.mentionOnlyMode,
      isAgentOnline: c.isAgentOnline,
      isCheckingHealth: c.isCheckingHealth,
      agentId: c.agentId,
      agentName: c.agentName,
      agentAvatar: c.agentAvatar,
      currentChannelId: c.currentChannelId,
      groupAgentCount: c.groupAgents.length,
      groupChannelId: c.groupChannel?.id,
      activeWorkflowId: c.activeWorkflowId,
      isViewingGroupBoundMemberSession: c.isViewingGroupBoundMemberSession,
      isViewingSheBoundSession: c.isViewingSheBoundSession,
      sourceGroupName: c.sourceGroupName,
      sourceDeviceLabel: c.sourceDeviceLabel,
      hasReplyingTo: c.replyingToMessage != null,
      highlightedMessageId: c.highlightedMessageId,
      queueLength: c.messageQueue.length,
      dmWorkflowEnabled: c.dmWorkflowEnabled,
      showWorkflowProgressPanel: c.showWorkflowProgressPanel,
      workflowNeedsPanelAttention: c.workflowNeedsPanelAttention,
      hasWorkflowPeerApproval: c.workflowPeerApprovalPending != null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OuterStructuralSnapshot &&
        other.messageCount == messageCount &&
        other.streamingMessageId == streamingMessageId &&
        other.groupStreamingCount == groupStreamingCount &&
        other.respondingAgentCount == respondingAgentCount &&
        other.isProcessing == isProcessing &&
        other.isLoading == isLoading &&
        other.isLoadingOlderMessages == isLoadingOlderMessages &&
        other.isGroupMode == isGroupMode &&
        other.mentionOnlyMode == mentionOnlyMode &&
        other.isAgentOnline == isAgentOnline &&
        other.isCheckingHealth == isCheckingHealth &&
        other.agentId == agentId &&
        other.agentName == agentName &&
        other.agentAvatar == agentAvatar &&
        other.currentChannelId == currentChannelId &&
        other.groupAgentCount == groupAgentCount &&
        other.groupChannelId == groupChannelId &&
        other.activeWorkflowId == activeWorkflowId &&
        other.isViewingGroupBoundMemberSession ==
            isViewingGroupBoundMemberSession &&
        other.isViewingSheBoundSession == isViewingSheBoundSession &&
        other.sourceGroupName == sourceGroupName &&
        other.sourceDeviceLabel == sourceDeviceLabel &&
        other.hasReplyingTo == hasReplyingTo &&
        other.highlightedMessageId == highlightedMessageId &&
        other.queueLength == queueLength &&
        other.dmWorkflowEnabled == dmWorkflowEnabled &&
        other.showWorkflowProgressPanel == showWorkflowProgressPanel &&
        other.workflowNeedsPanelAttention == workflowNeedsPanelAttention &&
        other.hasWorkflowPeerApproval == hasWorkflowPeerApproval;
  }

  @override
  int get hashCode => Object.hashAll([
        messageCount,
        streamingMessageId,
        groupStreamingCount,
        respondingAgentCount,
        isProcessing,
        isLoading,
        isLoadingOlderMessages,
        isGroupMode,
        mentionOnlyMode,
        isAgentOnline,
        isCheckingHealth,
        agentId,
        agentName,
        agentAvatar,
        currentChannelId,
        groupAgentCount,
        groupChannelId,
        activeWorkflowId,
        isViewingGroupBoundMemberSession,
        isViewingSheBoundSession,
        sourceGroupName,
        sourceDeviceLabel,
        hasReplyingTo,
        highlightedMessageId,
        queueLength,
        dmWorkflowEnabled,
        showWorkflowProgressPanel,
        workflowNeedsPanelAttention,
        hasWorkflowPeerApproval,
      ]);
}
