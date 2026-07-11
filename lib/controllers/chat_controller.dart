import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart';
import '../models/mention_entry.dart';
import '../models/message.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../models/attachment_data.dart';
import '../models/pending_attachment.dart';
import '../services/chat_service.dart';
import '../services/local_database_service.dart';
import '../services/attachment_service.dart';
import '../services/message_search_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/local_llm_agent_service.dart';
import '../services/app_lifecycle_service.dart';
import '../services/notification_service.dart';
import '../services/interactive_response_handler.dart';
import '../services/logger_service.dart';
import '../services/workflow/workflow_service.dart';
import '../models/workflow_models.dart';
import '../models/workflow_pending_approval.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_agent_host_service.dart' show isPeerAgentChannel;
import '../peer/services/peer_storage_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent;
import '../peer/peer_approval_selection.dart';
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import '../services/workflow/workflow_restore_planner.dart';
import '../services/workflow/workflow_pending_approval_picker.dart';
import '../services/workflow/workflow_plan_approval_sync.dart';
import 'chat_workflow_coordinator.dart';
import 'chat_attachment_coordinator.dart';
import 'chat_attachment_validator.dart';
import 'chat_streaming_text.dart';
import 'chat_lifecycle_coordinator.dart';
import 'chat_group_streaming_tracker.dart';
import 'group_mention_resolver.dart';
import 'chat_message_reconciler.dart';
import 'chat_send_planner.dart';
import 'streaming_action_confirmation.dart';
import 'inbound_file_message_parser.dart';
import 'peer_approval_completer_resolver.dart';
import 'chat_events.dart';

// ChatEvent 及其全部子类已拆分到 chat_events.dart，这里重新导出，
// 使现有 `import '../controllers/chat_controller.dart'` 的调用方无需改动。
export 'chat_events.dart';

// 部分低耦合的方法簇（会话管理、群成员管理）以 part + mixin 形式拆到独立文件，
// 与本文件同属一个库，因此可直接访问 _ChatControllerBase 的私有字段与辅助方法。
part 'chat_controller_sessions.dart';
part 'chat_controller_group_members.dart';
part 'chat_controller_interactions.dart';

// ---------------------------------------------------------------------------
// ChatController
// ---------------------------------------------------------------------------

/// ChatController 的状态与核心逻辑基类。
///
/// 持有全部字段、构造与核心方法；低耦合的方法簇通过 part 文件中的 mixin
/// （[_SessionOps]、[_GroupMemberOps]）挂载到具体的 [ChatController] 子类上。
abstract class _ChatControllerBase extends ChangeNotifier with InteractiveStreamingContext {
  // ---- Constructor parameters ----
  final String? agentId;
  final String? initialAgentName;
  final String? initialAgentAvatar;
  final String? initialChannelId;
  final bool embedded;
  final VoidCallback? onClose;
  final void Function(String channelId, {String? highlightMessageId})? onSwitchChannel;
  final String Function() getUserId;
  final String Function() getUserName;

  // ---- Services ----
  late final ChatService chatService;
  late final AttachmentService attachmentService;
  late final ChatAttachmentCoordinator attachmentCoordinator;
  late final MessageSearchService searchService;
  late final LocalDatabaseService localDatabaseService;
  late final InteractiveResponseHandler interactiveResponseHandler;

  // ---- Event stream ----
  final _eventController = StreamController<ChatEvent>.broadcast();
  Stream<ChatEvent> get events => _eventController.stream;

  // ---- Core message state ----
  List<Message> messages = [];
  Map<String, Message> messageIdMap = {};
  bool isLoading = false;
  bool isSearching = false;
  String searchQuery = '';

  // ---- Streaming state ----
  final ChatStreamingSession streaming = ChatStreamingSession();

  @override
  String? get streamingMessageId => streaming.messageId;
  @override
  set streamingMessageId(String? v) {
    if (v == null) {
      streaming.messageId = null;
    } else {
      streaming.messageId = v;
    }
  }

  @override
  String get streamingContent => streaming.content;
  @override
  set streamingContent(String v) => streaming.content = v;

  // ---- Processing / queue ----
  bool isProcessing = false;
  ACPCancellationToken? acpCancellationToken;
  List<String> messageQueue = [];

  // ---- Agent health state ----
  bool isAgentOnline = false;
  bool isCheckingHealth = true;
  Timer? _healthCheckTimer;

  /// 当前 agent 若来自配对设备（peer agent），记录其来源 peerId。其在线状态跟随
  /// 该设备的 P2P 连接状态，而非普通的健康轮询；为 null 表示非 peer agent。
  String? _agentSourcePeerId;

  /// peer 连接状态变化订阅，用于让 peer agent 的在线状态实时跟随设备上/下线。
  StreamSubscription<PeerConnectionEvent>? _peerConnSub;

  // ---- Reply state ----
  Message? replyingToMessage;
  String? highlightedMessageId;

  // ---- Channel / lifecycle ----
  String? currentChannelId;
  final ChatLifecycleCoordinator lifecycle = ChatLifecycleCoordinator();

  bool get isAppActive => lifecycle.isAppActive;

  // ---- History request tracking ----
  int historySentCount = 40;
  String? lastUserQuestion;
  Map<String, dynamic>? pendingHistoryRequest;

  // ---- Mutable agent info ----
  String? agentName;
  String? agentAvatar;

  /// 当前会话来源设备标签。仅当本机作为 host、当前会话是某配对设备的入站会话
  /// （channelId 形如 `peer__{peerId}__{agentId}`）时为非空，用于在聊天界面标题
  /// 上标注「来自哪个设备」，避免多设备会话名过长被省略时分不清。
  String? sourceDeviceLabel;

  // ---- Group mode state ----
  bool isGroupMode = false;
  Channel? groupChannel;
  List<RemoteAgent> groupAgents = [];
  Set<String> respondingAgentNames = {};
  bool mentionOnlyMode = false;
  String? groupAdminAgentId;
  Set<String> groupStreamingMessageIds = {};
  Map<String, GroupInteractionRequestEvent> pendingGroupInteractions = {};

  /// Workflow step streaming placeholders keyed by agent id.
  Map<String, String> get _workflowStreamingIds => workflow.streamingIds;
  Map<String, String> get _workflowStreamingContents =>
      workflow.streamingContents;

  // ---- DM channel system prompt override ----
  /// Custom system prompt set by the user for the current DM channel.
  /// When non-null, overrides the agent's default system prompt.
  String? dmSystemPrompt;

  // ---- Frame coalescing ----
  bool _pendingStreamingRebuild = false;

  /// Workflow panel + local execution bookkeeping.
  final ChatWorkflowCoordinator workflow = ChatWorkflowCoordinator();

  /// The ID of the currently active workflow (set during flow execution).
  String? get activeWorkflowId => workflow.activeWorkflowId;

  /// Whether the floating workflow progress panel should be visible.
  bool get showWorkflowProgressPanel => workflow.showProgressPanel;

  /// Active workflow exists but the user collapsed the progress panel.
  bool get workflowNeedsPanelAttention => workflow.needsPanelAttention;

  void reopenWorkflowPanel() {
    workflow.reopenPanel();
    notifyListeners();
  }

  /// Peer agent tool approval blocking a workflow step (for progress panel UI).
  WorkflowPeerApprovalPending? get workflowPeerApprovalPending =>
      workflow.peerApprovalPending;

  /// Cancellation token for the currently executing workflow.
  WorkflowCancellationToken? get _workflowCancelToken => workflow.cancelToken;
  set _workflowCancelToken(WorkflowCancellationToken? value) =>
      workflow.adoptCancelToken(value);

  /// Set the active workflow ID (called by orchestration when flow starts).
  void setActiveWorkflowId(String? id) {
    workflow.setActiveWorkflowId(id);
    notifyListeners();
  }

  void setWorkflowPeerApprovalPending(WorkflowPeerApprovalPending? pending) {
    workflow.setPeerApprovalPending(pending);
    _notify();
  }

  /// User dismisses the workflow progress panel (workflow state is preserved).
  void dismissWorkflowPanel() {
    workflow.dismissPanel();
    notifyListeners();
  }

  /// Cancel a running workflow execution.
  /// Called when user explicitly stops a workflow from the UI.
  Future<void> cancelRunningWorkflow() async {
    final workflowId = activeWorkflowId;
    if (workflowId == null) return;

    // Signal cancellation to the ChatService-owned execution loop
    chatService.cancelWorkflowExecution(workflowId);

    // Complete all pending interaction Completers so blocked steps can exit
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();
    workflow.prepareLocalCancel();

    // Mark workflow as cancelled in DB
    final workflowService = WorkflowService.instance;
    await workflowService.cancelWorkflow(workflowId);

    notifyListeners();
  }

  /// Handle workflow approval/rejection from the WorkflowProgressPanel.
  Future<void> handleWorkflowApproval(bool approved, {String? feedback}) async {
    final workflowId = activeWorkflowId;
    if (workflowId == null || currentChannelId == null) return;

    // Keep the in-chat plan_approval card in sync with the panel action.
    _markPlanApprovalRespondedForWorkflow(
      workflowId,
      approved,
      feedback: feedback,
    );

    await workflow.applyPlanDecision(
      approved: approved,
      workflowId: workflowId,
      startWorkflow: (id) =>
          WorkflowService(db: localDatabaseService).startWorkflow(id),
      cancelWorkflow: (id) =>
          WorkflowService(db: localDatabaseService).cancelWorkflow(id),
      startExecution: (id) async => _beginWorkflowStepExecution(id),
      sendRejectionFeedback: (feedbackMessage) =>
          processGroupMessage(feedbackMessage),
      feedback: feedback,
      notify: notifyListeners,
    );
  }

  /// Mirror panel approve/reject onto the message bubble's plan_approval card.
  void _markPlanApprovalRespondedForWorkflow(
    String workflowId,
    bool approved, {
    String? feedback,
  }) {
    final target = WorkflowPlanApprovalSync.findPlanApprovalMessage(
      messages: messages,
      workflowId: workflowId,
    );
    if (target == null) return;

    _updateGroupStreamingMetadata(
      target.id,
      'plan_approval_responded',
      WorkflowPlanApprovalSync.buildRespondedPatch(
        approved: approved,
        feedback: feedback,
      ),
    );
    final existingPlan =
        target.metadata?['plan_approval'] as Map<String, dynamic>?;
    if (existingPlan != null) {
      _updateGroupStreamingMetadata(
        target.id,
        'plan_approval',
        WorkflowPlanApprovalSync.mergeApprovedFlag(existingPlan, approved),
      );
    }
    final meta =
        Map<String, dynamic>.from(messageIdMap[target.id]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(target.id, meta).ignore();

    // Also complete any ChatService-held plan approval Completer so the
    // orchestration path (if still waiting) does not hang.
    if (currentChannelId != null) {
      chatService.completePlanApproval(
        currentChannelId!,
        WorkflowPlanApprovalSync.buildCompleterPayload(
          approved: approved,
          feedback: feedback,
        ),
      );
    }
  }

  /// Run (or resume) workflow step execution in the background.
  void _beginWorkflowStepExecution(String workflowId) {
    if (currentChannelId == null) return;
    // Prefer ChatService's in-process guard — controller token is lost on
    // dispose/channel switch and must not be the only concurrency check.
    if (chatService.isWorkflowExecuting(workflowId)) {
      _reattachWorkflowExecutionUI(workflowId);
      return;
    }
    final cancelToken = workflow.takeCancelTokenForNewExecution(
      chatService: chatService,
      workflowId: workflowId,
    );
    if (cancelToken == null) return;

    final userId = getUserId();
    final userName = getUserName();

    unawaited(chatService.executeWorkflowSteps(
      workflowId: workflowId,
      channelId: currentChannelId!,
      userId: userId,
      userName: userName,
      cancelToken: cancelToken,
      onAgentStart: (aid, anm) {
        _onWorkflowAgentStart(aid, anm, userId: userId, userName: userName);
      },
      onStreamChunk: _onWorkflowStreamChunk,
      onAgentDone: _onWorkflowAgentDone,
      onInteractionRequest: _workflowStepInteractionRequest,
      onExecutionFinished: _onWorkflowExecutionFinished,
    ));
  }

  void _onWorkflowAgentStart(
    String aid,
    String anm, {
    required String userId,
    required String userName,
  }) {
    respondingAgentNames.add(anm);
    isProcessing = true;
    final sid =
        'wf_streaming_${aid}_${DateTime.now().millisecondsSinceEpoch}';
    _workflowStreamingIds[aid] = sid;
    _workflowStreamingContents[aid] = '';
    final sm = Message(
      id: sid,
      content: '',
      timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      from: MessageFrom(id: aid, type: 'agent', name: anm),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
    );
    groupStreamingMessageIds.add(sid);
    messages.add(sm);
    messageIdMap[sid] = sm;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));
  }

  void _onWorkflowStreamChunk(String aid, String anm, String chunk) {
    final sid = _workflowStreamingIds[aid];
    if (sid == null) return;
    final updatedContent = workflow.appendStreamChunk(aid, chunk);
    ChatGroupStreamingTracker.applyContentById(
      sid,
      updatedContent,
      messages,
      messageIdMap,
    );
    scheduleStreamingRebuild();
    if (!isUserScrolledUp) {
      _emit(RequestScrollToBottomEvent());
    }
  }

  void _onWorkflowAgentDone(String aid, String anm, bool skipped) {
    final sid = _workflowStreamingIds.remove(aid);
    if (sid != null) groupStreamingMessageIds.remove(sid);
    _workflowStreamingContents.remove(aid);
    respondingAgentNames.remove(anm);
    _notify();
    reconcileGroupMessages();
  }

  void _onWorkflowExecutionFinished() {
    workflow.onExecutionFinished();
    isProcessing = false;
    respondingAgentNames.clear();
    groupStreamingMessageIds.clear();
    _notify();
  }

  /// Re-attach UI callbacks to a workflow that is still running in ChatService
  /// after a channel switch (controller was disposed and recreated).
  void _reattachWorkflowExecutionUI(String workflowId) {
    final userId = getUserId();
    final userName = getUserName();
    final exec = chatService.attachWorkflowExecutionUI(
      workflowId,
      onAgentStart: (aid, anm) {
        _onWorkflowAgentStart(aid, anm, userId: userId, userName: userName);
      },
      onStreamChunk: _onWorkflowStreamChunk,
      onAgentDone: _onWorkflowAgentDone,
      onInteractionRequest: _workflowStepInteractionRequest,
      onExecutionFinished: _onWorkflowExecutionFinished,
    );
    if (exec == null) return;
    _workflowCancelToken = exec.cancelToken;
    isProcessing = true;
    _notify();
  }

  Future<Map<String, dynamic>?> _workflowStepInteractionRequest(
    String agentId,
    String agentName,
    String interactionType,
    Map<String, dynamic> data,
  ) async {
    await reconcileGroupMessages();
    final savedMsgId = data.remove('_savedMessageId') as String?;
    String? sid;
    if (savedMsgId != null && messageIdMap.containsKey(savedMsgId)) {
      sid = savedMsgId;
    } else {
      sid = _workflowStreamingIds[agentId];
    }

    sid = _resolveGroupInteractionMessageId(
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
      preferredSid: sid,
    );

    if (sid != null) {
      _updateGroupStreamingMetadata(sid, interactionType, data);
      final existingMeta =
          Map<String, dynamic>.from(messageIdMap[sid]?.metadata ?? {});
      existingMeta[interactionType] = data;
      localDatabaseService.updateMessageMetadata(sid, existingMeta).ignore();
    }

    final event = GroupInteractionRequestEvent(
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
      groupStreamingMessageId: sid ?? agentId,
    );
    final confirmationId = data['confirmation_id'] as String?;
    final pendingKey = ChatWorkflowCoordinator.interactionPendingKey(
      interactionType: interactionType,
      data: data,
      sid: sid,
      agentId: agentId,
    );
    pendingGroupInteractions[pendingKey] = event;
    _notify();
    _emit(event);

    if (interactionType == 'action_confirmation') {
      final staleConfirmationId = workflow.registerWorkflowPeerApproval(
        agentId: agentId,
        agentName: agentName,
        messageId: sid,
        data: data,
      );
      if (staleConfirmationId != null) {
        final stale = pendingGroupInteractions.remove(staleConfirmationId);
        if (stale != null && !stale.result.isCompleted) {
          LoggerService().warning(
            'Superseding stale peer approval $staleConfirmationId '
            'with $confirmationId on step ${data['_workflowStepId']}',
            tag: 'PeerApproval',
          );
          stale.result.complete(
            PeerApprovalSelection.buildSupersededDenyResponse(),
          );
        }
      }
      if (confirmationId != null &&
          confirmationId.isNotEmpty &&
          sid != null &&
          data['_workflowPeerApproval'] == true) {
        WorkflowService.instance
            .updatePendingApprovalMessageId(confirmationId, sid)
            .ignore();
      }
    }

    try {
      return await event.result.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () => null,
      );
    } finally {
      pendingGroupInteractions.remove(pendingKey);
      if (interactionType == 'action_confirmation' &&
          data['_workflowPeerApproval'] == true) {
        workflow.clearPeerApprovalIfCurrent(
          completedConfirmationId: confirmationId,
          completedStepId: data['_workflowStepId'] as String?,
        );
      }
      _notify();
    }
  }

  /// Resume workflow execution after a deferred peer approval (e.g. app restart).
  Future<void> _resumeWorkflowExecutionIfNeeded(String workflowId) async {
    if (chatService.isWorkflowExecuting(workflowId)) {
      _reattachWorkflowExecutionUI(workflowId);
      return;
    }
    if (workflow.hasLocalExecution) return;
    final wf = await WorkflowService.instance
        .getWorkflowExecutionWithSteps(workflowId);
    final plan = WorkflowRestorePlanner.plan(
      active: wf,
      isExecutingInProcess: false,
      hasLocalCancelToken: false,
      withSteps: wf,
    );
    switch (plan.kind) {
      case WorkflowRestoreActionKind.none:
      case WorkflowRestoreActionKind.reattachOnly:
        return;
      case WorkflowRestoreActionKind.finalizeSucceeded:
        await WorkflowService.instance
            .completeWorkflow(workflowId, summary: '所有阶段执行完毕');
        return;
      case WorkflowRestoreActionKind.finalizeFailed:
        await WorkflowService.instance.failWorkflow(
          workflowId,
          'Workflow has failed steps and no remaining work',
        );
        return;
      case WorkflowRestoreActionKind.healOrphansThenFinalize:
      case WorkflowRestoreActionKind.healOrphansThenResume:
      case WorkflowRestoreActionKind.resumePending:
        // Peer-approval resume path historically only restarted pending work;
        // orphan healing is handled by full channel restore.
        if (plan.kind == WorkflowRestoreActionKind.resumePending ||
            plan.kind == WorkflowRestoreActionKind.healOrphansThenResume) {
          setActiveWorkflowId(workflowId);
          _beginWorkflowStepExecution(workflowId);
        }
        return;
    }
  }

  /// Restore active workflow + pending peer approvals after channel load.
  Future<void> _restoreWorkflowContext() async {
    if (currentChannelId == null) return;
    final workflowService = WorkflowService(db: localDatabaseService);
    final active = await workflowService.getActiveWorkflow(currentChannelId!);

    if (active != null) {
      setActiveWorkflowId(active.id);
    }

    final dbPending =
        await workflowService.getPendingApprovalsForChannel(currentChannelId!);
    final record = WorkflowPendingApprovalPicker.pickDbRecord(
      dbPending: dbPending,
      activeWorkflowId: active?.id,
    );

    if (record == null && active != null) {
      final uiPending = WorkflowPendingApprovalPicker.findInMessages(
        activeWorkflowId: active.id,
        messages: messages,
      );
      if (uiPending != null) {
        setWorkflowPeerApprovalPending(uiPending);
        final msgId = uiPending.messageId;
        if (msgId != null && messageIdMap.containsKey(msgId)) {
          _reattachWorkflowPeerApprovalInteraction(
            messageIdMap[msgId]!,
            uiPending.approvalData ?? const {},
          );
        }
        if (chatService.isWorkflowExecuting(active.id)) {
          _reattachWorkflowExecutionUI(active.id);
        }
        return;
      }
    }

    if (record != null) {
      setWorkflowPeerApprovalPending(record.toUiPending());
      final msgId = record.messageId;
      if (msgId != null && messageIdMap.containsKey(msgId)) {
        _reattachWorkflowPeerApprovalInteraction(
          messageIdMap[msgId]!,
          record.approvalData,
        );
      }
      if (active != null && chatService.isWorkflowExecuting(active.id)) {
        _reattachWorkflowExecutionUI(active.id);
      }
      return;
    }

    if (active == null || active.status != WorkflowStatus.running) return;

    final isExecuting = chatService.isWorkflowExecuting(active.id);
    WorkflowExecution? withSteps;
    if (!isExecuting) {
      withSteps =
          await workflowService.getWorkflowExecutionWithSteps(active.id);
    }

    final plan = WorkflowRestorePlanner.plan(
      active: active,
      isExecutingInProcess: isExecuting,
      hasLocalCancelToken: workflow.hasLocalExecution,
      withSteps: withSteps,
    );

    switch (plan.kind) {
      case WorkflowRestoreActionKind.none:
        return;
      case WorkflowRestoreActionKind.reattachOnly:
        _reattachWorkflowExecutionUI(active.id);
        return;
      case WorkflowRestoreActionKind.finalizeSucceeded:
        LoggerService().info(
          '_restoreWorkflowContext: finalizing completed workflow ${active.id}',
          tag: 'ChatController',
        );
        await workflowService.completeWorkflow(
          active.id,
          summary: '所有阶段执行完毕',
        );
        return;
      case WorkflowRestoreActionKind.finalizeFailed:
        LoggerService().info(
          '_restoreWorkflowContext: failing terminal workflow ${active.id}',
          tag: 'ChatController',
        );
        await workflowService.failWorkflow(
          active.id,
          'Workflow has failed steps and no remaining work',
        );
        return;
      case WorkflowRestoreActionKind.healOrphansThenFinalize:
      case WorkflowRestoreActionKind.healOrphansThenResume:
        LoggerService().info(
          '_restoreWorkflowContext: healing ${plan.stuckRunning.length} orphaned '
          'running step(s) on workflow ${active.id}',
          tag: 'ChatController',
        );
        for (final step in plan.stuckRunning) {
          await workflowService.completeStep(
            step.id,
            outputSummary:
                step.outputSummary ?? 'Recovered after channel switch',
          );
        }
        if (plan.kind == WorkflowRestoreActionKind.healOrphansThenFinalize) {
          final refreshed =
              await workflowService.getWorkflowExecutionWithSteps(active.id);
          if (refreshed != null && refreshed.failedSteps > 0) {
            await workflowService.failWorkflow(
              active.id,
              'Workflow has failed steps and no remaining work',
            );
          } else {
            await workflowService.completeWorkflow(
              active.id,
              summary: '所有阶段执行完毕',
            );
          }
          return;
        }
        LoggerService().info(
          '_restoreWorkflowContext: resuming interrupted workflow ${active.id} '
          '(pending=${plan.pendingCount}, '
          'completed=${plan.completedSteps}/${plan.totalSteps})',
          tag: 'ChatController',
        );
        _beginWorkflowStepExecution(active.id);
        return;
      case WorkflowRestoreActionKind.resumePending:
        LoggerService().info(
          '_restoreWorkflowContext: resuming interrupted workflow ${active.id} '
          '(pending=${plan.pendingCount}, '
          'completed=${plan.completedSteps}/${plan.totalSteps})',
          tag: 'ChatController',
        );
        _beginWorkflowStepExecution(active.id);
        return;
    }
  }

  void _reattachWorkflowPeerApprovalInteraction(
    Message msg,
    Map<String, dynamic> data,
  ) {
    if (data['confirmation_id'] == null) return;
    _emit(GroupInteractionRequestEvent(
      agentId: msg.from.id,
      agentName: msg.from.name,
      interactionType: 'action_confirmation',
      data: Map<String, dynamic>.from(data),
      groupStreamingMessageId: msg.id,
    ));
  }

  _ChatControllerBase({
    required this.agentId,
    this.initialAgentName,
    this.initialAgentAvatar,
    this.initialChannelId,
    this.embedded = false,
    this.onClose,
    this.onSwitchChannel,
    required this.getUserId,
    required this.getUserName,
  }) {
    agentName = initialAgentName;
    agentAvatar = initialAgentAvatar;

    final databaseService = LocalDatabaseService();
    localDatabaseService = databaseService;
    chatService = ChatService();
    attachmentService = AttachmentService(
      LocalFileStorageService(),
      databaseService,
    );
    attachmentCoordinator = ChatAttachmentCoordinator(attachmentService);
    searchService = MessageSearchService(databaseService);
    interactiveResponseHandler = InteractiveResponseHandler(this);
  }

  /// Initialize the controller. Call this after constructing.
  Future<void> init() async {
    await loadMessages();
    refreshAgentStatus();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      refreshAgentStatus();
    });
    // peer agent 的在线状态需实时跟随来源设备上/下线，不能只靠 10s 轮询。
    _peerConnSub = PeerConnectionManager.instance.events.listen((event) {
      if (_agentSourcePeerId != null && event.peerId == _agentSourcePeerId) {
        refreshAgentStatus();
      }
    });
  }

  @override
  void dispose() {
    AppLifecycleService().setActiveChannel(null);
    if (currentChannelId != null) {
      chatService.detachTaskUI(currentChannelId!);
      chatService.detachGroupTaskUI(currentChannelId!);
    }
    // Detach workflow UI only — do NOT cancel. ChatService keeps the
    // execution loop alive so switching back reattaches instead of restarting.
    final wfId = activeWorkflowId;
    if (wfId != null) {
      chatService.detachWorkflowExecutionUI(wfId);
    }
    workflow.detachOnDispose();
    messageQueue.clear();
    _healthCheckTimer?.cancel();
    _peerConnSub?.cancel();
    if (currentChannelId != null) {
      chatService.closeChannelStream(currentChannelId!);
    }
    _eventController.close();
    super.dispose();
  }

  void _emit(ChatEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _notify() {
    if (_eventController.isClosed) return;
    notifyListeners();
  }

  // ---- InteractiveStreamingContext implementation ----
  @override
  void notifyUI() => _notify();

  @override
  void emitScrollToBottom({bool force = false}) =>
      _emit(RequestScrollToBottomEvent(force: force));

  @override
  void emitError(String message) => _emit(ShowErrorSnackBarEvent(message));

  @override
  bool get isMounted => !_eventController.isClosed;

  /// Add a message to the local list and notify listeners. Used by the UI shell
  /// for voice messages and other locally-generated messages.
  void addLocalMessage(Message message) {
    messages.add(message);
    messageIdMap[message.id] = message;
    _notify();
  }

  /// Update the group channel and notify listeners.
  void updateGroupChannelInfo(Channel updated) {
    groupChannel = updated;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // App lifecycle
  // ---------------------------------------------------------------------------

  void onAppLifecycleChanged(bool resumed) {
    final shouldHandleResume = lifecycle.onLifecycleChanged(resumed);
    if (!shouldHandleResume) return;

    // Delay DB writes slightly — on iOS the SQLite file handle may still be
    // readonly for a brief moment after the app returns from background.
    Future.delayed(const Duration(milliseconds: 500), () {
      markMessagesAsReadIfAtBottom();
      handleResumeFromBackground();
    });
  }

  Future<void> handleResumeFromBackground() async {
    final bgMs = lifecycle.takeBackgroundedAtMs();
    if (bgMs == null || currentChannelId == null) return;

    final duration = ChatLifecycleCoordinator.backgroundDuration(bgMs);
    if (duration == null) return;

    try {
      await chatService.handleAppResumed(duration);
    } catch (e) {
      // Database may still be recovering from background on iOS.
      LoggerService().error('handleAppResumed failed', tag: 'ChatController', error: e);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 200));

    final interruptedInfo = chatService.getInterruptedTaskInfo(currentChannelId!);
    if (interruptedInfo != null) {
      chatService.clearInterruptedTaskInfo(currentChannelId!);

      streaming.clear();
      isProcessing = false;
      _notify();

      await reloadMessagesFromDB();

      _emit(ShowRetrySnackBarEvent(
        'chat_connectionInterrupted',
        'chat_connectionInterruptedRetry',
        interruptedInfo,
      ));
    }
  }

  Future<void> retryLastUserMessage(Map<String, String> interruptedInfo) async {
    if (currentChannelId == null) return;

    final userMsgId = interruptedInfo['userMessageId'];
    if (userMsgId == null) return;

    String? messageContent;
    for (final msg in messages.reversed) {
      if (msg.id == userMsgId) {
        messageContent = msg.content;
        break;
      }
    }

    if (messageContent == null) {
      final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
      for (final msg in dbMessages.reversed) {
        if (msg.id == userMsgId) {
          messageContent = msg.content;
          break;
        }
      }
    }

    if (messageContent != null && messageContent.isNotEmpty) {
      if (isGroupMode) {
        await processGroupMessage(messageContent);
      } else {
        await processMessage(messageContent);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Message loading
  // ---------------------------------------------------------------------------

  Future<void> loadMessages() async {
    isLoading = true;
    _notify();

    try {
      final userId = getUserId();

      if (initialChannelId != null && currentChannelId == null) {
        currentChannelId = initialChannelId;
      } else if (agentId != null && currentChannelId == null) {
        final latestChannelId = await chatService.getLatestActiveChannelId(userId, agentId!);
        currentChannelId = latestChannelId ?? chatService.generateChannelId(userId, agentId!);
      } else if (agentId == null && currentChannelId == null) {
        isLoading = false;
        _notify();
        return;
      }

      // Mark this channel as the most recently opened for this agent so
      // re-entry from the conversation list restores the same session.
      await localDatabaseService.touchChannelUpdatedAt(currentChannelId!);

      AppLifecycleService().setActiveChannel(currentChannelId);
      NotificationService().cancelNotification(currentChannelId.hashCode);

      // 始终从数据库读取最新 name/avatar，避免会话列表等入口传入过期的缓存值。
      if (agentId != null) {
        final agent = await localDatabaseService.getRemoteAgentById(agentId!);
        if (agent != null) {
          agentName = agent.name;
          agentAvatar = agent.avatar;
        }
      }

      // Detect group mode & resolve agent info from channel metadata
      final channel = await localDatabaseService.getChannelById(currentChannelId!);
      // channel 已落库时按 channel 解析；全新会话（channel 尚未持久化）回退到
      // 构造参数 agentId，确保 peer agent 首次对话也能展示来源设备标签。
      sourceDeviceLabel = channel != null
          ? await _resolveSourceDeviceLabel(channel)
          : await _resolveClientPeerAgentDeviceLabel(null);
      if (channel != null && channel.isGroup) {
        isGroupMode = true;
        groupChannel = channel;
        mentionOnlyMode = channel.isAllMembersMentionMode;
        final agentIds = channel.memberIds.where((id) => id != userId && id != 'user').toList();
        final agents = <RemoteAgent>[];
        for (final aid in agentIds) {
          final agent = await localDatabaseService.getRemoteAgentById(aid);
          if (agent != null) agents.add(agent);
        }
        groupAgents = agents;
        groupAdminAgentId = channel.adminAgentId;
      } else if (channel != null && channel.isDM) {
        // Load DM channel's custom system prompt
        dmSystemPrompt = channel.systemPrompt;
        if (agentName == null) {
          // Resolve agent name/avatar from channel when not provided
          // (e.g. navigating from search results by channelId only)
          final agentMember = channel.members.where((m) => m.isAgent).toList();
          if (agentMember.isNotEmpty) {
            final agent = await localDatabaseService.getRemoteAgentById(agentMember.first.id);
            if (agent != null) {
              agentName = agent.name;
              agentAvatar = agent.avatar;
            }
          }
        }
      } else if (channel != null && !channel.isGroup && agentName == null) {
        // Non-group, non-DM typed channel — resolve agent name from channel
        final agentMember = channel.members.where((m) => m.isAgent).toList();
        if (agentMember.isNotEmpty) {
          final agent = await localDatabaseService.getRemoteAgentById(agentMember.first.id);
          if (agent != null) {
            agentName = agent.name;
            agentAvatar = agent.avatar;
          }
        }
      }

      final loadedMessages = await chatService.loadChannelMessages(currentChannelId!);

      if (isGroupMode) {
        messages = loadedMessages;
      } else {
        _mergeDmStreamingPlaceholders(loadedMessages);
      }
      rebuildMessageIdMap();
      isLoading = false;
      _notify();

      markMessagesAsReadIfAtBottom();

      _emit(RequestScrollToBottomEvent(force: true));

      if (!isGroupMode) {
        reattachToActiveTask();
      }
      if (isGroupMode) {
        reattachToGroupActiveTasks();
        _reattachPendingPlanApproval();
        await _restoreWorkflowContext();
      }
    } catch (e) {
      isLoading = false;
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_loadFailed:$e'));
    }
  }

  /// 解析当前会话的来源设备标签。
  ///
  /// 覆盖两类「来自配对设备」的会话：
  /// - **Host 侧入站会话**（`peer__{peerId}__{agentId}`）：从 channel 成员中取出
  ///   `peer:{peerId}` 成员，按 peerId 查配对设备名；查不到时回退到 channel 名称中
  ///   `← ` 之后的部分。
  /// - **Client 侧访问对端分享的 agent**（普通 `dm_` channel，agent 为 peer 类型）：
  ///   从 agent 成员对应的 [RemoteAgent.sourcePeerId] 实时查配对设备名，回退到
  ///   [RemoteAgent.sourcePeerName] 快照。
  ///
  /// 都解析不到时返回 null。
  Future<String?> _resolveSourceDeviceLabel(Channel channel) async {
    if (isPeerAgentChannel(channel.id)) {
      return _resolveHostInboundDeviceLabel(channel);
    }
    return _resolveClientPeerAgentDeviceLabel(channel);
  }

  /// Host 侧：本机被某配对设备访问时的入站会话来源设备名。
  Future<String?> _resolveHostInboundDeviceLabel(Channel channel) async {
    String? peerId;
    for (final m in channel.members) {
      if (m.id.startsWith('peer:')) {
        peerId = m.id.substring('peer:'.length);
        break;
      }
    }

    final byId = await _peerDeviceNameById(peerId);
    if (byId != null) return byId;

    // 回退：channel 名称形如 `Agent 名 ← 设备名`
    const sep = ' ← ';
    final idx = channel.name.lastIndexOf(sep);
    if (idx >= 0) {
      final label = channel.name.substring(idx + sep.length).trim();
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  /// Client 侧：当前 DM 会话访问的是对端分享的 peer agent 时的来源设备名。
  Future<String?> _resolveClientPeerAgentDeviceLabel(Channel? channel) async {
    // 优先用 channel 中的 agent 成员；取不到时回退到构造参数 agentId。
    String? targetAgentId = agentId;
    final agentMembers =
        channel?.members.where((m) => m.isAgent).toList() ?? const [];
    if (agentMembers.isNotEmpty) {
      targetAgentId = agentMembers.first.id;
    }
    if (targetAgentId == null) return null;

    try {
      final agent = await localDatabaseService.getRemoteAgentById(targetAgentId);
      if (agent == null || !agent.isPeerAgent) return null;

      // 优先用 sourcePeerId 实时查配对设备名（设备改名后能跟随更新）。
      final byId = await _peerDeviceNameById(agent.sourcePeerId);
      if (byId != null) return byId;

      // 回退：agent metadata 中的设备名快照。
      final snapshot = agent.sourcePeerName;
      if (snapshot != null && snapshot.isNotEmpty) return snapshot;
    } catch (_) {}
    return null;
  }

  /// 按 peerId 查配对设备的显示名；查不到或为空时返回 null。
  Future<String?> _peerDeviceNameById(String? peerId) async {
    if (peerId == null || peerId.isEmpty) return null;
    try {
      final peers = await PeerStorageService().loadAllPeers();
      for (final p in peers) {
        if (p.id == peerId && p.deviceName.isNotEmpty) return p.deviceName;
      }
    } catch (_) {}
    return null;
  }

  Future<void> reloadMessagesFromDB() async {
    if (currentChannelId == null) return;
    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
    if (isGroupMode) {
      messages.clear();
      messageIdMap.clear();
      for (final m in dbMessages) {
        messages.add(m);
        messageIdMap[m.id] = m;
      }
    } else {
      _mergeDmStreamingPlaceholders(dbMessages);
      rebuildMessageIdMap();
    }
    _notify();
  }

  void rebuildMessageIdMap() {
    messageIdMap = {for (final m in messages) m.id: m};
  }

  /// Ensure [messageId] is present in the in-memory list, loading older history if needed.
  Future<bool> ensureMessageLoaded(String messageId) async {
    if (messages.any((m) => m.id == messageId)) return true;
    if (currentChannelId == null) return false;

    try {
      final loadedMessages = await chatService.loadChannelMessagesIncluding(
        currentChannelId!,
        messageId,
      );
      if (!loadedMessages.any((m) => m.id == messageId)) return false;
      messages = loadedMessages;
      rebuildMessageIdMap();
      _notify();
      return true;
    } catch (e) {
      LoggerService().warning(
        'Failed to load message for scroll: $messageId',
        tag: 'ChatController',
        error: e,
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Agent health
  // ---------------------------------------------------------------------------

  Future<void> refreshAgentStatus() async {
    if (agentId == null) return;
    try {
      final agent = await localDatabaseService.getAgentById(agentId!);
      if (agent != null) {
        if (agent.isPeerAgent) {
          // peer agent 通过 P2P 隧道访问对端本地 agent，其可用性完全取决于来源
          // 配对设备是否在线，因此在线状态直接跟随该设备的连接状态。
          _agentSourcePeerId = agent.sourcePeerId;
          final peerId = agent.sourcePeerId;
          isAgentOnline = peerId != null &&
              PeerConnectionManager.instance.getPeerState(peerId) ==
                  PeerConnectionState.connected;
        } else {
          _agentSourcePeerId = null;
          isAgentOnline = agent.status.isOnline;
        }
        isCheckingHealth = false;
        _notify();
      }
    } catch (_) {
      isCheckingHealth = false;
      _notify();
    }
  }

  // ---------------------------------------------------------------------------
  // DM system prompt
  // ---------------------------------------------------------------------------

  /// Save a custom system prompt for the current DM channel.
  /// Persists to the database and updates the in-memory value.
  Future<void> updateDmSystemPrompt(String? prompt) async {
    if (currentChannelId == null) return;
    final channel = await localDatabaseService.getChannelById(currentChannelId!);
    if (channel == null) return;
    final updated = channel.copyWith(systemPrompt: prompt?.isNotEmpty == true ? prompt : null);
    await localDatabaseService.updateChannel(updated);
    dmSystemPrompt = updated.systemPrompt;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Read status
  // ---------------------------------------------------------------------------

  bool isUserScrolledUp = false;
  int unreadMessageCount = 0;

  Future<void> markMessagesAsReadIfAtBottom() async {
    if (currentChannelId == null) return;
    if (!isAppActive) return;
    if (isUserScrolledUp) return;
    try {
      await localDatabaseService.markChannelMessagesAsRead(currentChannelId!);
    } catch (e) {
      // On iOS, SQLite can be temporarily readonly after returning from
      // background. Swallow the error — messages will be marked read on the
      // next successful attempt.
      LoggerService().error('markMessagesAsRead failed (db may be recovering)', tag: 'ChatController', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // Reattach to background tasks
  // ---------------------------------------------------------------------------

  void reattachToActiveTask() {
    if (currentChannelId == null) return;

    final activeTask = chatService.getActiveTask(currentChannelId!);
    if (activeTask == null) return;

    streaming.begin(
      'streaming_reattach_${DateTime.now().millisecondsSinceEpoch}',
    );
    streaming.content = activeTask.accumulatedContent;

    final streamingMessage = ChatStreamingText.placeholder(
      id: streaming.messageId!,
      from: MessageFrom(id: activeTask.agentId, type: 'agent', name: activeTask.agentName),
      to: MessageFrom(id: activeTask.userId, type: 'user', name: activeTask.userName),
      timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
    );
    // placeholder starts empty — restore accumulated content
    final seeded = ChatStreamingText.withUpdatedContent(
      streamingMessage,
      streaming.content,
    );

    isProcessing = true;
    messages.add(seeded);
    messageIdMap[seeded.id] = seeded;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    acpCancellationToken = ACPCancellationToken();

    chatService.attachTaskUI(
      currentChannelId!,
        onStreamChunk: (chunk) {
        streaming.append(chunk);
        streaming.applyContentTo(messages, messageIdMap);
        scheduleStreamingRebuild();
        if (!isUserScrolledUp) {
          _emit(RequestScrollToBottomEvent());
        }
      },
      onActionConfirmation: _handleStreamingActionConfirmation,
      onMessageMetadata: (metadata) {
        streaming.applyMetadataTo(messages, messageIdMap, metadata);
        _notify();
      },
      onTaskFinished: () async {
        await activeTask.dbSaveCompleter.future;
        acpCancellationToken = null;
        streaming.clear();
        isProcessing = false;
        await loadMessages();
        _notify();
        processNextInQueue();
      },
    );
  }

  void reattachToGroupActiveTasks() {
    if (currentChannelId == null) return;

    final activeTasks = chatService.getActiveGroupTasks(currentChannelId!);
    if (activeTasks.isEmpty) return;

    final turn = ChatGroupStreamingTracker();

    for (final entry in activeTasks.entries) {
      final aid = entry.key;
      final task = entry.value;
      final sid = 'group_streaming_${aid}_${DateTime.now().millisecondsSinceEpoch}';
      turn.begin(aid, sid, initialContent: task.accumulatedContent);

      final streamingMessage = ChatStreamingText.withUpdatedContent(
        ChatStreamingText.placeholder(
          id: sid,
          from: MessageFrom(id: aid, type: 'agent', name: task.agentName),
          timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
        ),
        task.accumulatedContent,
      );

      isProcessing = true;
      respondingAgentNames.add(task.agentName);
      groupStreamingMessageIds.add(sid);
      messages.add(streamingMessage);
      messageIdMap[streamingMessage.id] = streamingMessage;
    }
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    chatService.attachGroupTaskUI(
      currentChannelId!,
      onStreamChunk: (aid, agentNameVal, chunk) {
        if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
          return;
        }
        scheduleStreamingRebuild();
        if (!isUserScrolledUp) {
          _emit(RequestScrollToBottomEvent());
        }
      },
      onTaskFinished: (aid, agentNameVal) {
        final sid = turn.finish(aid);
        if (sid != null) groupStreamingMessageIds.remove(sid);
        respondingAgentNames.remove(agentNameVal);
        _notify();

        if (turn.isEmpty) {
          reconcileGroupMessages().then((_) {
            isProcessing = false;
            respondingAgentNames.clear();
            groupStreamingMessageIds.clear();
            _notify();
            processNextInQueue();
          });
        }
      },
    );
  }

  /// Re-emit a GroupInteractionRequestEvent for any pending plan_approval
  /// that survived a channel switch. Called from loadMessages() so the UI
  /// can re-render the approve/reject card after navigating back.
  void _reattachPendingPlanApproval() {
    if (currentChannelId == null) return;
    final pendingApproval = chatService.getPendingPlanApproval(currentChannelId!);
    if (pendingApproval == null) return;

    final msgId = pendingApproval.messageId;
    if (msgId.isEmpty || !messageIdMap.containsKey(msgId)) return;

    // Re-emit the event so the UI shows the interactive card again.
    _emit(GroupInteractionRequestEvent(
      agentId: pendingApproval.agentId,
      agentName: pendingApproval.agentName,
      interactionType: 'plan_approval',
      data: Map<String, dynamic>.from(pendingApproval.planData),
      groupStreamingMessageId: msgId,
    ));
  }

  // ---------------------------------------------------------------------------
  // Sending messages
  // ---------------------------------------------------------------------------

  Future<void> sendMessage({
    required String content,
    required List<PendingAttachment> pendingAttachments,
    required VoidCallback clearMessageController,
    String? replyToId,
    List<MentionEntry> mentions = const [],
  }) async {
    final hasPendingAttachments = pendingAttachments.isNotEmpty;
    LoggerService().debug('User sending message', tag: 'ChatController');

    final early = ChatSendPlanner.decide(
      content: content,
      hasAttachments: hasPendingAttachments,
      isGroupMode: isGroupMode,
      hasAgent: agentId != null,
      isProcessing: false,
    );
    if (early == ChatSendDisposition.empty) return;
    if (early == ChatSendDisposition.noAgent) {
      _emit(ShowSnackBarEvent('chat_noAgentSelected'));
      return;
    }

    if (!isGroupMode && agentId != null && hasPendingAttachments) {
      final agent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (agent != null) {
        final validation = ChatAttachmentValidator.validatePendingForAgent(
          agent,
          pendingAttachments,
        );
        if (!validation.ok) {
          _emit(ShowSnackBarEvent(validation.errorKey!));
          return;
        }
      }
    }

    final attachmentsToSend = List<PendingAttachment>.from(pendingAttachments);
    pendingAttachments.clear();

    clearMessageController();

    // Capture reply state
    final capturedReplyToId = replyToId ?? replyingToMessage?.id;
    cancelReply();

    // Save all pending attachments and build AttachmentData list
    final persisted = await attachmentCoordinator.persistPending(
      pending: attachmentsToSend,
      channelId: currentChannelId ?? '',
      userId: getUserId(),
      userName: getUserName(),
      agentId: agentId ?? '',
      onMessageSaved: (message) {
        messages.add(message);
        messageIdMap[message.id] = message;
        _notify();
        _emit(RequestScrollToBottomEvent(force: true));
      },
    );
    final savedAttachmentMessages = persisted.messages;
    final attachmentDataList = persisted.data;
    final hasAttachments = attachmentDataList.isNotEmpty;

    final disposition = ChatSendPlanner.decide(
      content: content,
      hasAttachments: hasAttachments,
      isGroupMode: isGroupMode,
      hasAgent: agentId != null,
      isProcessing: isProcessing,
    );

    switch (disposition) {
      case ChatSendDisposition.empty:
      case ChatSendDisposition.noAgent:
        return;
      case ChatSendDisposition.attachmentsOnly:
        if (!isGroupMode) {
          for (final msg in savedAttachmentMessages) {
            await sendAttachmentToAgent(msg);
          }
        }
        return;
      case ChatSendDisposition.queueText:
        if (hasAttachments && !isGroupMode) {
          for (final msg in savedAttachmentMessages) {
            await sendAttachmentToAgent(msg);
          }
        }
        messageQueue.add(content);
        _notify();
        return;
      case ChatSendDisposition.sendGroup:
        LoggerService().debug(
          'sendMessage -> processGroupMessage (isGroupMode=true, '
          'groupAgents=${groupAgents.length}, adminId=$groupAdminAgentId)',
          tag: 'ChatController',
        );
        await processGroupMessage(
          content,
          replyToId: capturedReplyToId,
          attachments: hasAttachments ? attachmentDataList : null,
          mentions: mentions,
        );
        return;
      case ChatSendDisposition.sendDm:
        await processMessage(
          content,
          replyToId: capturedReplyToId,
          attachments: hasAttachments ? attachmentDataList : null,
          attachmentMessages: hasAttachments ? savedAttachmentMessages : null,
        );
        return;
    }
  }

  /// Stop only the current message being streamed, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentMessageOnly() {
    LoggerService().debug('Stopping current message only (queue preserved)', tag: 'ChatController');

    if (streamingMessageId != null) {
      final stoppedId = streamingMessageId!;
      final idx = messages.indexWhere((m) => m.id == stoppedId);
      if (idx != -1) {
        final current = messages[idx];
        final updated = ChatStreamingText.markMessageStopped(
          current,
          contentOverride: streamingContent,
        );
        messages[idx] = updated;
        messageIdMap[current.id] = updated;
      }
      streaming.clear();
      _notify();
    }

    acpCancellationToken?.cancel();
    // DO NOT clear messageQueue — let processNextInQueue() pick up the next one
    _notify();
  }

  /// Stop all active group streaming messages, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentGroupMessageOnly() {
    LoggerService().debug('Stopping current group messages only (queue preserved)', tag: 'ChatController');

    // Mark all active group streaming messages with [Stopped]
    for (final sid in groupStreamingMessageIds) {
      final existing = messageIdMap[sid];
      if (existing != null) {
        final idx = messages.indexOf(existing);
        if (idx != -1) {
          final updated = ChatStreamingText.markMessageStopped(messages[idx]);
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
      }
    }

    // Cancel the cancellation token to stop all active agent tasks
    acpCancellationToken?.cancel();

    // Force-complete all group tasks in ChatService
    if (currentChannelId != null) {
      chatService.cancelActiveGroupTasks(currentChannelId!);
    }

    // Complete all pending group interaction Completers with null.
    // Note: plan_approval is no longer tracked in pendingGroupInteractions —
    // its Completer lives in ChatService._pendingPlanApprovals and survives
    // channel navigation. So this loop only cancels other interaction types.
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();

    // Reset group streaming state but DO NOT clear messageQueue
    respondingAgentNames.clear();
    groupStreamingMessageIds.clear();
    isProcessing = false;
    _notify();
    processNextInQueue();
  }

  void stopStreaming() {
    LoggerService().debug('Stopping streaming', tag: 'ChatController');

    if (streamingMessageId != null) {
      final stoppedId = streamingMessageId!;
      final idx = messages.indexWhere((m) => m.id == stoppedId);
      if (idx != -1) {
        final current = messages[idx];
        final updated = ChatStreamingText.markMessageStopped(
          current,
          contentOverride: streamingContent,
        );
        messages[idx] = updated;
        messageIdMap[current.id] = updated;
      }
      streaming.clear();
      _notify();
    }

    acpCancellationToken?.cancel();

    // Clear queued messages so they won't be sent after stopping
    messageQueue.clear();
    _notify();
  }

  void stopGroupStreaming() {
    LoggerService().debug('Stopping group streaming', tag: 'ChatController');

    // Mark all active group streaming messages with [Stopped]
    for (final sid in groupStreamingMessageIds) {
      final existing = messageIdMap[sid];
      if (existing != null) {
        final idx = messages.indexOf(existing);
        if (idx != -1) {
          final updated = ChatStreamingText.markMessageStopped(messages[idx]);
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
      }
    }

    // Cancel the cancellation token to stop all active agent tasks
    acpCancellationToken?.cancel();

    // Force-complete all group tasks in ChatService so typing indicators
    // are cleared and reattach won't resume cancelled tasks.
    if (currentChannelId != null) {
      chatService.cancelActiveGroupTasks(currentChannelId!);
    }

    // Cancel any pending plan_approval so the orchestration loop terminates.
    if (currentChannelId != null) {
      chatService.cancelPlanApproval(currentChannelId!);
    }

    // Complete all pending group interaction Completers with null.
    // Note: plan_approval is no longer tracked here — its Completer is in
    // ChatService._pendingPlanApprovals and was cancelled above.
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();

    // Reset group streaming state
    respondingAgentNames.clear();
    groupStreamingMessageIds.clear();
    messageQueue.clear();
    isProcessing = false;
    _notify();
  }

  Future<void> processNextInQueue() async {
    if (messageQueue.isEmpty) return;

    final nextContent = messageQueue.removeAt(0);
    _notify();
    if (isGroupMode) {
      await processGroupMessage(nextContent);
    } else {
      await processMessage(nextContent);
    }
  }

  // ---------------------------------------------------------------------------
  // Process DM message
  // ---------------------------------------------------------------------------

  Future<void> processMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<Message>? attachmentMessages}) async {
    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    _notify();

    lastUserQuestion = content;
    acpCancellationToken = ACPCancellationToken();

    // Set to true when the agent supports async-confirmation: the task lives
    // on past this method's return, and the finally block must NOT clear
    // `streamingMessageId` / `isProcessing` — those belong to the task's
    // onTaskFinished callback, which fires later when task.completed arrives.
    bool awaitingAsyncTask = false;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = remoteAgent.isLocal;

      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      // 注意：不再在此做前置的 checkAgentHealth 探测。
      // AgentMessagingService 内部在建连阶段已带 3 次指数退避重试 +
      // checkAgentHealth 兜底，并通过 onReconnecting 回调把进度推给 UI。
      // 移除这里可以避免"一次失败就抛出"的体验，并减少一次冗余 ping。

      // Add user message to UI immediately
      final userMessage = Message(
        id: 'temp_user_${DateTime.now().millisecondsSinceEpoch}',
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: userId, type: 'user', name: userName),
        to: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        type: MessageType.text,
        replyTo: replyToId,
      );

      streaming.begin('streaming_${DateTime.now().millisecondsSinceEpoch}');
      final streamingMessage = ChatStreamingText.placeholder(
        id: streaming.messageId!,
        from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      );

      messages.add(userMessage);
      messages.add(streamingMessage);
      messageIdMap[userMessage.id] = userMessage;
      messageIdMap[streamingMessage.id] = streamingMessage;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));

      if (currentChannelId != null) {
        final currentMessages = await chatService.loadChannelMessages(
          currentChannelId!, limit: 40,
        );
        historySentCount = currentMessages.where((m) => m.type == MessageType.text).length;
      }

      final agentResponse = await chatService.sendMessageToAgent(
        content: content,
        agent: remoteAgent,
        userId: userId,
        userName: userName,
        channelId: currentChannelId,
        replyToId: replyToId,
        dmSystemPrompt: dmSystemPrompt,
        acpCancellationToken: acpCancellationToken,
        attachments: attachments,
        onReconnecting: (attempt, total) {
          if (attempt == 0) {
            _emit(HideReconnectingSnackBarEvent());
          } else {
            _emit(ShowReconnectingSnackBarEvent(attempt, total));
          }
        },
        onOsToolConfirmation: (toolName, args, risk) async {
          final event = ShowOsToolConfirmationEvent(toolName, args, risk);
          _emit(event);
          return await event.result.future;
        },
        onStreamChunk: (chunk) {
          streaming.append(chunk);
          streaming.applyContentTo(messages, messageIdMap);
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
        onActionConfirmation: _handleStreamingActionConfirmation,
        onSingleSelect: (selectData) {
          _updateStreamingMetadata({'single_select': Map<String, dynamic>.from(selectData)});
        },
        onMultiSelect: (selectData) {
          _updateStreamingMetadata({'multi_select': Map<String, dynamic>.from(selectData)});
        },
        onFileUpload: (uploadData) {
          _updateStreamingMetadata({'file_upload': Map<String, dynamic>.from(uploadData)});
        },
        onForm: (formData) {
          _updateStreamingMetadata({'form': Map<String, dynamic>.from(formData)});
        },
        onFileMessage: (fileData) async {
          await _handleFileMessage(fileData);
        },
        onMessageMetadata: (metadata) {
          streaming.applyMetadataTo(messages, messageIdMap, metadata);
          _notify();
        },
        onRequestHistory: (historyData) {
          pendingHistoryRequest = Map<String, dynamic>.from(historyData);
        },
      );

      // Phase 2-A: async-confirmation fast path.
      // When the agent supports async_confirmation, `sendMessageToAgent`
      // returns `null` as soon as the agent has ACK'd the request — the
      // streaming chunks, action_confirmation metadata, and eventual
      // task.completed all flow through TaskCallbacks asynchronously.
      //
      // Hook the underlying ActiveTask's onTaskFinished so that when the
      // agent's SDK turn finally ends (milliseconds to seconds later), we
      // reload messages from DB, drop the streaming id, and clear the
      // processing flag. Until then the UI stays responsive — the user can
      // tap Allow / Deny on a confirmation card, or even send a follow-up.
      final asyncConn = chatService.getACPConnection(remoteAgent.id);
      final supportsAsync = asyncConn?.supportsAsyncConfirmation ?? false;
      if (supportsAsync && currentChannelId != null) {
        final activeTask = chatService.getActiveTask(currentChannelId!);
        if (activeTask != null) {
          awaitingAsyncTask = true;
          final channelAtDispatch = currentChannelId;
          activeTask.onTaskFinished = () async {
            try {
              await activeTask.dbSaveCompleter.future;
            } catch (_) {}
            // Only clean up if we're still on the same channel (user may have
            // navigated away). If they did, the values are already detached
            // and another call will just be a no-op on stale state.
            if (currentChannelId == channelAtDispatch) {
              acpCancellationToken = null;
              streaming.clear();
              await loadMessages();
              isProcessing = false;
              _notify();
              processNextInQueue();
            }
          };
        }
      }

      // Handle pending history request
      bool handledHistorySupplement = false;
      if (pendingHistoryRequest != null) {
        final historyData = pendingHistoryRequest!;
        pendingHistoryRequest = null;

        if (agentResponse != null) {
          try { await chatService.deleteMessage(agentResponse.id); } catch (_) {}
        }

        final reason = historyData['reason'] as String? ?? 'Agent needs more context';
        final requestId = historyData['request_id'] as String? ?? '';
        final requestedCount = historyData['requested_count'] as int? ?? 40;

        addSystemHint('$reason');

        final dialogEvent = ShowHistoryRequestDialogEvent(reason);
        _emit(dialogEvent);
        final approved = await dialogEvent.result.future;

        if (approved) {
          handledHistorySupplement = true;
          addSystemHint('Loading more chat history...');

          streaming.begin(
            'streaming_reanswer_${DateTime.now().millisecondsSinceEpoch}',
          );
          acpCancellationToken = ACPCancellationToken();

          final reanswer = ChatStreamingText.placeholder(
            id: streaming.messageId!,
            from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
            to: MessageFrom(id: userId, type: 'user', name: userName),
            timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
          );
          messages.add(reanswer);
          messageIdMap[reanswer.id] = reanswer;
          _notify();
          _emit(RequestScrollToBottomEvent(force: true));

          int currentRequestedCount = requestedCount;
          const int maxSupplementRounds = 3;
          try {
            for (int round = 0; round < maxSupplementRounds; round++) {
              final supplementResult = await chatService.sendHistorySupplement(
                agent: remoteAgent,
                sessionId: currentChannelId!,
                requestId: requestId,
                originalQuestion: lastUserQuestion ?? '',
                offset: historySentCount,
                batchSize: currentRequestedCount,
                onStreamChunk: (chunk) {
                  streaming.append(chunk);
                  streaming.applyContentTo(messages, messageIdMap);
                  scheduleStreamingRebuild();
                  if (!isUserScrolledUp) {
                    _emit(RequestScrollToBottomEvent());
                  }
                },
                acpCancellationToken: acpCancellationToken,
              );

              if (supplementResult == null) {
                addSystemHint('No more history records available');
                messages.removeWhere((m) => m.id == streamingMessageId);
                messageIdMap.remove(streamingMessageId);
                _notify();
                break;
              }

              historySentCount += supplementResult.actualSentCount;

              if (supplementResult.pendingHistoryRequest != null) {
                final nextReason = supplementResult.pendingHistoryRequest!['reason'] as String? ?? 'Agent needs more context';
                currentRequestedCount = supplementResult.pendingHistoryRequest!['requested_count'] as int? ?? 40;
                if (supplementResult.message.content.isEmpty) {
                  try { await chatService.deleteMessage(supplementResult.message.id); } catch (_) {}
                }
                addSystemHint(nextReason);
                addSystemHint('Loading more chat history...');
                streamingContent = '';
                acpCancellationToken = ACPCancellationToken();
                continue;
              }

              addSystemHint('History loaded, agent is re-answering...');
              break;
            }
          } catch (e) {
            addSystemHint('Failed to load history: $e');
            messages.removeWhere((m) => m.id == streamingMessageId);
            messageIdMap.remove(streamingMessageId);
            _notify();
          }
        } else {
          addSystemHint('History request ignored');
        }
      }

      if (!handledHistorySupplement && agentResponse == null) {
        // Phase 2-A: in async-confirmation mode, `sendMessageToAgent` returns
        // null as soon as the agent has acknowledged the request — the actual
        // response (text + confirmation metadata) flows through the registered
        // TaskCallbacks asynchronously. A `null` here is NOT an error in that
        // mode; suppress the snackbar and leave the streaming message in place
        // for the callbacks to keep updating.
        final isAsync = chatService
                .getACPConnection(remoteAgent.id)
                ?.supportsAsyncConfirmation ??
            false;
        if (!isAsync) {
          _emit(ShowSnackBarEvent('chat_responseError'));
        }
      }

      isAgentOnline = true;
      _notify();
      // In async mode, skip loadMessages() here — the DB save happens later
      // (in onTaskCompleted), so reloading now would overwrite the in-memory
      // streaming content with a stale DB snapshot. The onTaskFinished
      // callback does its own loadMessages() when the task actually ends.
      if (!awaitingAsyncTask) {
        await loadMessages();
      }
    } catch (e, stackTrace) {
      LoggerService().error('Send message failed', tag: 'ChatController', error: e, stackTrace: stackTrace);
      messageQueue.clear();
      await loadMessages();
      _emit(ShowErrorSnackBarEvent('$e'));
    } finally {
      if (awaitingAsyncTask) {
        // Async path: don't clear streamingMessageId / isProcessing here —
        // the activeTask.onTaskFinished callback owns that cleanup and will
        // fire when the agent's SDK turn actually ends. We still drain the
        // send queue so the next queued message can start preparing.
        processNextInQueue();
      } else {
        acpCancellationToken = null;
        streaming.clear();
        pendingHistoryRequest = null;
        isProcessing = false;
        _notify();
        processNextInQueue();
      }
    }
  }

  void _updateStreamingMetadata(Map<String, dynamic> metadata) {
    streaming.applyMetadataTo(messages, messageIdMap, metadata);
    // Keep content in sync with the session accumulator when present.
    if (streaming.isActive && streaming.content.isNotEmpty) {
      streaming.applyContentTo(messages, messageIdMap);
    }
    _notify();
  }

  /// Attach (or replace) an in-band action-confirmation card on the active
  /// streaming bubble. Supports multiple sequential approvals on the same turn:
  /// each new `confirmation_id` replaces the prior card and clears any stale
  /// `selected_action_id` from the previous approval.
  ///
  /// Peer DM path: if `streamingMessageId` was already cleared (e.g. a racing
  /// `agent_done` finished the turn before the approval frame arrived), fall
  /// back to the latest agent message so the card is still visible.
  void _handleStreamingActionConfirmation(Map<String, dynamic> actionData) {
    final confirmationId = actionData['confirmation_id'] as String? ?? '';
    LoggerService().info(
      'onActionConfirmation: confirmationId=$confirmationId '
      'streamingMessageId=$streamingMessageId isProcessing=$isProcessing '
      'actions=${(actionData['actions'] as List?)?.length ?? 0} '
      'context=${actionData['confirmation_context']}',
      tag: 'PeerApproval',
    );

    final streamingId = StreamingActionConfirmation.resolveHostMessageId(
      preferredId: streamingMessageId,
      messageIdMap: messageIdMap,
      messages: messages,
    );

    if (streamingId == null) {
      // No host bubble yet — create a dedicated peer-approval placeholder so
      // the card is never silently dropped.
      if (agentId == null) {
        LoggerService().warning(
          'onActionConfirmation: no streamingMessageId and no agentId — UI not attached',
          tag: 'PeerApproval',
        );
        return;
      }
      final userId = getUserId();
      final userName = getUserName();
      final displayName = agentName ?? 'Agent';
      final sid = StreamingActionConfirmation.dmFallbackId(agentId!);
      final sm = StreamingActionConfirmation.buildFallbackBubble(
        id: sid,
        agentId: agentId!,
        agentName: displayName,
        userId: userId,
        userName: userName,
        actionData: actionData,
      );
      messages.add(sm);
      messageIdMap[sid] = sm;
      streamingMessageId = sid;
      streamingContent = sm.content;
      isProcessing = true;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));
      LoggerService().info(
        'onActionConfirmation: created fallback bubble sid=$sid',
        tag: 'PeerApproval',
      );
      // Persist so a subsequent loadMessages cannot drop the card.
      if (currentChannelId != null) {
        localDatabaseService
            .createMessage(
              id: sid,
              channelId: currentChannelId!,
              senderId: agentId!,
              senderType: 'agent',
              senderName: displayName,
              content: sm.content,
              messageType: 'text',
              metadata: sm.metadata,
            )
            .ignore();
      }
      return;
    }

    final idx = messages.indexWhere((m) => m.id == streamingId);
    if (idx == -1) {
      LoggerService().warning(
        'onActionConfirmation: message not found for id=$streamingId',
        tag: 'PeerApproval',
      );
      return;
    }
    if (StreamingActionConfirmation.replacesPrior(
      existingMetadata: messages[idx].metadata,
      confirmationId: confirmationId,
    )) {
      final prev = messages[idx].metadata?['action_confirmation'];
      LoggerService().info(
        'onActionConfirmation: new approval replaces prior '
        'prevId=${prev is Map ? prev['confirmation_id'] : null} '
        'prevSelected=${prev is Map ? prev['selected_action_id'] : null} '
        '→ $confirmationId',
        tag: 'PeerApproval',
      );
    }
    final updated = StreamingActionConfirmation.attachToHost(
      host: messages[idx],
      actionData: actionData,
      contentOverride: streamingContent,
    );
    messages[idx] = updated;
    messageIdMap[updated.id] = updated;
    // Keep streamingMessageId pointing at the host bubble so subsequent
    // sequential approvals land on the same card.
    streamingMessageId ??= streamingId;
    LoggerService().debug(
      'onActionConfirmation: attached seq=${updated.metadata?['approval_seq']} '
      'msgLen=${updated.content.length}',
      tag: 'PeerApproval',
    );
    _notify();
    // Persist so loadMessages after sendChat cannot revive a card-less bubble.
    localDatabaseService
        .updateMessageMetadata(streamingId, updated.metadata ?? {})
        .ignore();
  }

  /// Resolve (or create) the group message bubble that should host an interactive
  /// component. For peer-relayed tool approvals, ensures a visible card even when
  /// the streaming placeholder was already reconciled away.
  String? _resolveGroupInteractionMessageId({
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
    String? preferredSid,
  }) {
    if (preferredSid != null && messageIdMap.containsKey(preferredSid)) {
      return preferredSid;
    }

    if (interactionType == 'action_confirmation' &&
        data['confirmation_context'] == 'peer' &&
        currentChannelId != null) {
      final userId = getUserId();
      final userName = getUserName();
      final sid = StreamingActionConfirmation.groupFallbackId(agentId);
      final sm = StreamingActionConfirmation.buildFallbackBubble(
        id: sid,
        agentId: agentId,
        agentName: agentName,
        userId: userId,
        userName: userName,
        actionData: data,
        metadataKey: interactionType,
      );
      messages.add(sm);
      messageIdMap[sm.id] = sm;
      groupStreamingMessageIds.add(sid);
      localDatabaseService
          .createMessage(
            id: sid,
            channelId: currentChannelId!,
            senderId: agentId,
            senderType: 'agent',
            senderName: agentName,
            content: sm.content,
            messageType: 'text',
            metadata: sm.metadata,
          )
          .ignore();
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));
      return sid;
    }

    return preferredSid;
  }

  void _updateGroupStreamingMetadata(String streamingId, String key, Map<String, dynamic> data) {
    ChatGroupStreamingTracker.putMetadataKey(
      streamingId,
      key,
      data,
      messages,
      messageIdMap,
    );
    _notify();
  }

  Future<void> _handleFileMessage(Map<String, dynamic> fileData) async {
    try {
      int? resolvedSize;
      final url = fileData['url'] as String?;
      final rawSize = (fileData['size'] as num?)?.toInt();
      if (InboundFileMessageParser.needsLocalSizeProbe(url, rawSize) &&
          url != null) {
        try {
          final f = File(url);
          if (await f.exists()) resolvedSize = await f.length();
        } catch (_) {}
      }

      final draft = InboundFileMessageParser.parse(
        fileData,
        resolvedSize: resolvedSize ?? rawSize,
      );
      if (draft == null) return;

      final currentAgentName = agentName ?? 'Agent';
      final messageId = 'file_${DateTime.now().millisecondsSinceEpoch}';
      await localDatabaseService.createMessage(
        id: messageId,
        channelId: currentChannelId ?? '',
        senderId: agentId ?? '',
        senderType: 'agent',
        senderName: currentAgentName,
        content: draft.content,
        messageType: draft.messageType.toString().split('.').last,
        metadata: draft.metadata,
      );

      await loadMessages();
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_fileMessageFailed:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Process group message
  // ---------------------------------------------------------------------------

  Future<void> processGroupMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<MentionEntry> mentions = const []}) async {
    if (currentChannelId == null || groupAgents.isEmpty) {
      LoggerService().debug('processGroupMessage ABORTED: channelId=$currentChannelId, groupAgents=${groupAgents.length}', tag: 'ChatController');
      return;
    }
    LoggerService().debug('processGroupMessage: channelId=$currentChannelId, agents=${groupAgents.map((a) => a.name).toList()}, adminId=$groupAdminAgentId', tag: 'ChatController');

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    acpCancellationToken = ACPCancellationToken();
    _notify();

    final userMessage = Message(
      id: 'temp_user_${DateTime.now().millisecondsSinceEpoch}',
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: replyToId,
    );
    messages.add(userMessage);
    messageIdMap[userMessage.id] = userMessage;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    final turn = ChatGroupStreamingTracker();

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();

      // Determine which agents to actually trigger based on structured mentions.
      // If the caller provided explicit MentionEntry list, use notify:true entries.
      // Fall back to legacy text-parsing when no structured mentions are provided
      // (e.g. queued messages, agent-triggered flows).
      final mentionedAgentIds = GroupMentionResolver.resolveAgentIds(
        content: content,
        mentions: mentions,
        agents: [
          for (final a in groupAgents) (id: a.id, name: a.name),
        ],
      );

      // Build metadata to persist on the user message.
      final Map<String, dynamic>? userMsgMetadata = mentions.isNotEmpty
          ? {'mentions': mentions.map((m) => m.toJson()).toList()}
          : null;

      await chatService.sendMessageToGroup(
        channelId: currentChannelId!,
        content: content,
        userId: userId,
        userName: userName,
        agentIds: agentIds,
        mentionedAgentIds: mentionedAgentIds,
        mentionOnlyMode: mentionOnlyMode,
        adminAgentId: groupAdminAgentId,
        replyToId: replyToId,
        flowMode: groupChannel?.flowMode ?? false,
        acpCancellationToken: acpCancellationToken,
        userMessageMetadata: userMsgMetadata,
        onAgentStart: (aid, anm) {
          final sid = 'group_streaming_${aid}_${DateTime.now().millisecondsSinceEpoch}';
          turn.begin(aid, sid);
          final sm = ChatStreamingText.placeholder(
            id: sid,
            from: MessageFrom(id: aid, type: 'agent', name: anm),
            to: MessageFrom(id: userId, type: 'user', name: userName),
            timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
          );
          respondingAgentNames.add(anm);
          groupStreamingMessageIds.add(sid);
          messages.add(sm);
          messageIdMap[sm.id] = sm;
          _notify();
          _emit(RequestScrollToBottomEvent(force: true));
        },
        onStreamChunk: (aid, anm, chunk) {
          if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
            return;
          }
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
        onAgentDone: (aid, anm, skipped) {
          final sid = turn.idFor(aid);
          if (skipped && sid != null) {
            messages.removeWhere((m) => m.id == sid);
            messageIdMap.remove(sid);
            groupStreamingMessageIds.remove(sid);
          } else if (sid != null) {
            groupStreamingMessageIds.remove(sid);
          }
          turn.finish(aid);
          respondingAgentNames.remove(anm);
          _notify();
        },
        onAllDone: () {},
        onActiveWorkflowChanged: (workflowId) => setActiveWorkflowId(workflowId),
        onInteractionRequest: (agentId, agentName, interactionType, data) async {
          // Workflow: if this is a plan_approval with a workflow ID, show the progress panel
          if (interactionType == 'plan_approval') {
            final workflowId = data['_workflowId'] as String?;
            if (workflowId != null) {
              setActiveWorkflowId(workflowId);
            }
          }

          // Determine the message ID to attach the interactive component to.
          // If the agent is still streaming, use the streaming message ID.
          // If the agent has already finished (local LLM path), the streaming
          // ID is gone — reconcile first so the DB message is in the list,
          // then use the saved message ID injected by the service.
          var sid = turn.idFor(agentId);
          if (sid == null) {
            // Agent already done — reconcile to load DB message into the list
            await reconcileGroupMessages();
            final savedMsgId = data.remove('_savedMessageId') as String?;
            if (savedMsgId != null && messageIdMap.containsKey(savedMsgId)) {
              sid = savedMsgId;
            }
          }

          sid = _resolveGroupInteractionMessageId(
            agentId: agentId,
            agentName: agentName,
            interactionType: interactionType,
            data: data,
            preferredSid: sid,
          );

          // 1. Update message metadata to show the interactive component
          if (sid != null) {
            _updateGroupStreamingMetadata(sid, interactionType, data);
            // Persist the interaction metadata to DB so it survives a channel
            // switch. Without this, returning to the chat reloads from DB and
            // the plan_approval / action_confirmation card is missing, making
            // the message appear blank or invisible.
            // updateMessageMetadata overwrites the entire metadata field, so
            // merge with whatever is already in memory before writing.
            final existingMeta = Map<String, dynamic>.from(
                messageIdMap[sid]?.metadata ?? {});
            existingMeta[interactionType] = data;
            localDatabaseService
                .updateMessageMetadata(sid, existingMeta)
                .ignore();
          }

          // 2. Create event, track it, emit, and await with timeout
          final event = GroupInteractionRequestEvent(
            agentId: agentId,
            agentName: agentName,
            interactionType: interactionType,
            data: data,
            groupStreamingMessageId: sid ?? agentId,
          );
          final confirmationId = data['confirmation_id'] as String?;
          final pendingKey =
              (interactionType == 'action_confirmation' &&
                      confirmationId != null &&
                      confirmationId.isNotEmpty)
                  ? confirmationId
                  : (sid ?? agentId);
          pendingGroupInteractions[pendingKey] = event;
          _notify();
          _emit(event);

          // form / file_upload / action_confirmation / single_select / multi_select
          // are always non-blocking: the current turn ends immediately so the
          // user can interact with the component.
          // plan_approval is also non-blocking here: the actual blocking wait is
          // managed by ChatService._pendingPlanApprovals, which survives channel
          // navigation. The UI card is already persisted to DB by the code above.
          const _nonBlockingTypes = {'form', 'file_upload', 'action_confirmation', 'single_select', 'multi_select', 'plan_approval'};
          if (_nonBlockingTypes.contains(interactionType)) {
            if (!event.result.isCompleted) {
              event.result.complete(const {'_non_blocking': true});
            }
            pendingGroupInteractions.remove(pendingKey);
            _notify();
            return const {'_non_blocking': true};
          }

          try {
            return await event.result.future.timeout(
              const Duration(minutes: 5),
              onTimeout: () => null,
            );
          } finally {
            pendingGroupInteractions.remove(pendingKey);
            _notify();
          }
        },
      );

      await reconcileGroupMessages();
      markMessagesAsReadIfAtBottom();
    } catch (e, stackTrace) {
      LoggerService().error('processGroupMessage error: $e', tag: 'ChatController', error: e, stackTrace: stackTrace);
      _emit(ShowErrorSnackBarEvent('chat_groupChatError:$e'));
    } finally {
      acpCancellationToken = null;
      streaming.clear();
      turn.clear();
      // Complete all pending group interaction Completers with null
      for (final e in pendingGroupInteractions.values) {
        if (!e.result.isCompleted) e.result.complete(null);
      }
      pendingGroupInteractions.clear();
      isProcessing = false;
      respondingAgentNames.clear();
      groupStreamingMessageIds.clear();
      _notify();
      processNextInQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Send attachment to agent
  // ---------------------------------------------------------------------------

  Future<bool> _validateAttachmentDataForAgent(
    RemoteAgent agent,
    AttachmentData attachment,
  ) async {
    final result =
        ChatAttachmentValidator.validateDataForAgent(agent, attachment);
    if (!result.ok) {
      _emit(ShowSnackBarEvent(result.errorKey!));
    }
    return result.ok;
  }

  Future<void> sendAttachmentToAgent(Message attachmentMessage) async {
    final attachmentData = await attachmentService.buildAttachmentData(attachmentMessage);
    if (attachmentData == null) return;
    if (attachmentData.exceedsSizeLimit) {
      _emit(ShowSnackBarEvent('File too large (max 20MB) to send to agent'));
      return;
    }

    if (agentId != null) {
      final agent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (agent != null &&
          !await _validateAttachmentDataForAgent(agent, attachmentData)) {
        return;
      }
    }

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    _notify();

    acpCancellationToken = ACPCancellationToken();

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = remoteAgent.isLocal;
      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      streaming.begin('streaming_${DateTime.now().millisecondsSinceEpoch}');
      final sm = ChatStreamingText.placeholder(
        id: streaming.messageId!,
        from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      );

      messages.add(sm);
      messageIdMap[sm.id] = sm;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));

      final agentResponse = await chatService.sendMessageToAgent(
        content: attachmentMessage.content,
        agent: remoteAgent,
        userId: userId,
        userName: userName,
        channelId: currentChannelId,
        dmSystemPrompt: dmSystemPrompt,
        acpCancellationToken: acpCancellationToken,
        attachments: [attachmentData],
        existingUserMessage: attachmentMessage,
        onStreamChunk: (chunk) {
          streaming.append(chunk);
          streaming.applyContentTo(messages, messageIdMap);
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
      );

      if (agentResponse != null) {
        final idx = messages.indexWhere((m) => m.id == streamingMessageId);
        if (idx != -1) {
          messages[idx] = agentResponse;
          messageIdMap.remove(streamingMessageId);
          messageIdMap[agentResponse.id] = agentResponse;
        }
        _notify();
      } else {
        messages.removeWhere((m) => m.id == streamingMessageId);
        messageIdMap.remove(streamingMessageId);
        _notify();
      }
    } catch (e) {
      messages.removeWhere((m) => m.id == streamingMessageId);
      messageIdMap.remove(streamingMessageId);
      _notify();
    } finally {
      streaming.clear();
      isProcessing = false;
      _notify();
      processNextInQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Reply
  // ---------------------------------------------------------------------------

  void startReply(Message message) {
    replyingToMessage = message;
    _notify();
  }

  void cancelReply() {
    replyingToMessage = null;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  Future<void> searchMessages(String query) async {
    if (query.trim().isEmpty) {
      searchQuery = '';
      isSearching = false;
      _notify();
      await loadMessages();
      return;
    }

    isSearching = true;
    searchQuery = query;
    _notify();

    try {
      final results = await searchService.searchMessages(
        query: query,
        channelId: currentChannelId,
      );

      messages = results.map((r) => r.message).toList();
      rebuildMessageIdMap();
      isSearching = false;
      _notify();
    } catch (e) {
      isSearching = false;
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_searchError:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Message operations
  // ---------------------------------------------------------------------------

  Future<void> deleteMessage(Message message) async {
    if (message.type == MessageType.image || message.type == MessageType.file || message.type == MessageType.audio) {
      await attachmentService.deleteAttachment(message);
    } else {
      await chatService.deleteMessage(message.id);
    }

    messages.removeWhere((m) => m.id == message.id);
    messageIdMap.remove(message.id);
    _notify();
  }

  Future<void> rollbackMessage(Message message, {bool reEdit = false}) async {
    if (agentId == null || currentChannelId == null) return;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      await chatService.rollbackFromMessage(
        messageId: message.id,
        channelId: currentChannelId!,
        agent: remoteAgent,
      );

      await loadMessages();
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_rollbackFailed:$e'));
    }
  }

  List<String> parseMentionedAgentIds(String content) {
    return GroupMentionResolver.parseFromContent(
      content,
      [for (final a in groupAgents) (id: a.id, name: a.name)],
    );
  }

  // ---------------------------------------------------------------------------
  // Group message reconciliation
  // ---------------------------------------------------------------------------

  /// Merge in-memory DM `streaming_*` placeholders with DB messages.
  ///
  /// Unlike group chats (which use [reconcileGroupMessages]), DM historically
  /// did a hard replace in [loadMessages], which dropped the live streaming
  /// bubble whenever the final DB row was missing or still empty (e.g. peer
  /// cancel before answer text). Keep the placeholder when it still has
  /// visible content and no usable DB agent message exists yet.
  void _mergeDmStreamingPlaceholders(List<Message> dbMessages) {
    messages = ChatMessageReconciler.mergeDmStreamingPlaceholders(
      current: messages,
      dbMessages: dbMessages,
    );
  }

  Future<void> reconcileGroupMessages() async {
    if (currentChannelId == null) return;

    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
    final result = ChatMessageReconciler.reconcileGroupMessages(
      current: messages,
      dbMessages: dbMessages,
    );

    LoggerService().debug(
      'reconcileGroupMessages: temps=${messages.where((m) => ChatMessageReconciler.isGroupTempId(m.id)).length}, '
      'db=${dbMessages.length}, migrations=${result.pendingKeyMigrations.length}',
      tag: 'ChatController',
    );

    for (final entry in result.pendingKeyMigrations.entries) {
      if (pendingGroupInteractions.containsKey(entry.key)) {
        pendingGroupInteractions[entry.value] =
            pendingGroupInteractions.remove(entry.key)!;
      }
    }

    messages = result.messages;
    rebuildMessageIdMap();
    LoggerService().debug(
      'reconcileGroupMessages done: ${messages.length} messages',
      tag: 'ChatController',
    );
    _notify();
  }

  void scheduleStreamingRebuild() {
    if (_pendingStreamingRebuild) return;
    _pendingStreamingRebuild = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStreamingRebuild = false;
      _notify();
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void addSystemHint(String text) {
    final hint = Message(
      id: 'hint_${DateTime.now().millisecondsSinceEpoch}',
      content: text,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
    );
    messages.add(hint);
    messageIdMap[hint.id] = hint;
    _notify();
    _emit(RequestScrollToBottomEvent());
  }

  /// Update agent info (e.g. after editing in detail screen)
  void updateAgentInfo(String? name, String? avatar) {
    agentName = name;
    agentAvatar = avatar;
    _notify();
  }
}

/// 聊天页面控制器。
///
/// 在 [_ChatControllerBase] 的状态与核心逻辑之上，通过 mixin 组合会话管理
/// （[_SessionOps]）与群成员管理（[_GroupMemberOps]）两个职责模块。
class ChatController extends _ChatControllerBase
    with _SessionOps, _GroupMemberOps, _InteractionOps {
  ChatController({
    required super.agentId,
    super.initialAgentName,
    super.initialAgentAvatar,
    super.initialChannelId,
    super.embedded,
    super.onClose,
    super.onSwitchChannel,
    required super.getUserId,
    required super.getUserName,
  });
}
