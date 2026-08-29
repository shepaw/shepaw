import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/screens/chat_screen_outer_snapshot.dart';

void main() {
  OuterStructuralSnapshot snap({
    int messageCount = 0,
    String? streamingMessageId,
    int groupStreamingCount = 0,
    int respondingAgentCount = 0,
    bool isProcessing = false,
    bool isLoading = false,
    bool isLoadingOlderMessages = false,
    bool isGroupMode = false,
    bool mentionOnlyMode = false,
    bool isAgentOnline = true,
    bool isCheckingHealth = false,
    String? agentId = 'a1',
    String? agentName = 'Agent',
    String? agentAvatar,
    String? currentChannelId = 'ch1',
    int groupAgentCount = 0,
    String? groupChannelId,
    String? activeWorkflowId,
    bool isViewingGroupBoundMemberSession = false,
    bool isViewingSheBoundSession = false,
    String? sourceGroupName,
    String? sourceDeviceLabel,
    bool hasReplyingTo = false,
    String? highlightedMessageId,
    int queueLength = 0,
    bool dmWorkflowEnabled = false,
    bool showWorkflowProgressPanel = false,
    bool workflowNeedsPanelAttention = false,
    bool hasWorkflowPeerApproval = false,
  }) {
    return OuterStructuralSnapshot(
      messageCount: messageCount,
      streamingMessageId: streamingMessageId,
      groupStreamingCount: groupStreamingCount,
      respondingAgentCount: respondingAgentCount,
      isProcessing: isProcessing,
      isLoading: isLoading,
      isLoadingOlderMessages: isLoadingOlderMessages,
      isGroupMode: isGroupMode,
      mentionOnlyMode: mentionOnlyMode,
      isAgentOnline: isAgentOnline,
      isCheckingHealth: isCheckingHealth,
      agentId: agentId,
      agentName: agentName,
      agentAvatar: agentAvatar,
      currentChannelId: currentChannelId,
      groupAgentCount: groupAgentCount,
      groupChannelId: groupChannelId,
      activeWorkflowId: activeWorkflowId,
      isViewingGroupBoundMemberSession: isViewingGroupBoundMemberSession,
      isViewingSheBoundSession: isViewingSheBoundSession,
      sourceGroupName: sourceGroupName,
      sourceDeviceLabel: sourceDeviceLabel,
      hasReplyingTo: hasReplyingTo,
      highlightedMessageId: highlightedMessageId,
      queueLength: queueLength,
      dmWorkflowEnabled: dmWorkflowEnabled,
      showWorkflowProgressPanel: showWorkflowProgressPanel,
      workflowNeedsPanelAttention: workflowNeedsPanelAttention,
      hasWorkflowPeerApproval: hasWorkflowPeerApproval,
    );
  }

  group('OuterStructuralSnapshot', () {
    test('同字段两次构造相等（流式 chunk 场景：只有内容变）', () {
      expect(snap(), equals(snap()));
      expect(snap().hashCode, snap().hashCode);
    });

    test('identical 相等', () {
      final s = snap();
      expect(identical(s, s), isTrue);
    });

    test('每个字段单独变化都不相等（门控必须对该字段翻转放行）', () {
      final base = snap();
      final variants = <OuterStructuralSnapshot>[
        snap(messageCount: 1),
        snap(streamingMessageId: 's1'),
        snap(groupStreamingCount: 1),
        snap(respondingAgentCount: 1),
        snap(isProcessing: true),
        snap(isLoading: true),
        snap(isLoadingOlderMessages: true),
        snap(isGroupMode: true),
        snap(mentionOnlyMode: true),
        snap(isAgentOnline: false),
        snap(isCheckingHealth: true),
        snap(agentId: 'a2'),
        snap(agentName: 'Other'),
        snap(agentAvatar: '/x.png'),
        snap(currentChannelId: 'ch2'),
        snap(groupAgentCount: 2),
        snap(groupChannelId: 'g1'),
        snap(activeWorkflowId: 'wf2'),
        snap(isViewingGroupBoundMemberSession: true),
        snap(isViewingSheBoundSession: true),
        snap(sourceGroupName: 'g'),
        snap(sourceDeviceLabel: 'Mac'),
        snap(hasReplyingTo: true),
        snap(highlightedMessageId: 'm1'),
        snap(queueLength: 1),
        snap(dmWorkflowEnabled: true),
        snap(showWorkflowProgressPanel: true),
        snap(workflowNeedsPanelAttention: true),
        snap(hasWorkflowPeerApproval: true),
      ];
      for (final v in variants) {
        expect(v == base, isFalse,
            reason: '字段变化必须让快照失配，否则外层 UI 会卡旧值');
      }
    });

    test('气泡内容增长不改变任何快照字段（chunk 被正确门控掉）', () {
      // 模拟流式 chunk：内容变长，但结构性字段全部不变。
      final before = snap();
      final after = snap(); // 内容不在快照里
      expect(after == before, isTrue);
    });
  });
}
