part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Workflow panel + restore / step execution
//
// Implements abstract workflow hooks declared on [_ChatControllerBase] so
// loadMessages / interactions / messaging can call into this mixin.
// ---------------------------------------------------------------------------

mixin _WorkflowOps on _ChatControllerBase {
  @override
  void reopenWorkflowPanel() {
    workflow.reopenPanel();
    notifyListeners();
  }

  /// She 在 DM 中调用 `shepaw workflow create` 成功后回调：
  /// 激活进度面板状态，并把审批卡片挂到当前流式气泡上（回合末持久化
  /// metadata 由 AgentMessagingService 完成，重载后卡片仍可渲染）。
  @override
  void _handleDmWorkflowPlanCreated(
    String workflowId,
    Map<String, dynamic> planData,
  ) {
    setActiveWorkflowId(workflowId);
    _updateStreamingMetadata({'plan_approval': planData});
    final channelId = currentChannelId;
    if (channelId != null) {
      PendingApprovalHub.instance.upsert(
        PendingApprovalItem(
          id: PendingApprovalItem.planId(workflowId),
          channelId: channelId,
          messageId: streamingMessageId,
          agentId: agentId ?? '',
          agentName: agentName ?? initialAgentName ?? 'Agent',
          kind: PendingApprovalKind.plan,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  /// Peer agent tool approval blocking a workflow step (for progress panel UI).
  @override
  WorkflowPeerApprovalPending? get workflowPeerApprovalPending =>
      workflow.peerApprovalPending;

  /// Cancellation token for the currently executing workflow.
  @override
  WorkflowCancellationToken? get _workflowCancelToken => workflow.cancelToken;
  @override
  set _workflowCancelToken(WorkflowCancellationToken? value) =>
      workflow.adoptCancelToken(value);

  /// Set the active workflow ID (called by orchestration when flow starts).
  @override
  void setActiveWorkflowId(String? id) {
    workflow.setActiveWorkflowId(id);
    notifyListeners();
  }

  @override
  void setWorkflowPeerApprovalPending(WorkflowPeerApprovalPending? pending) {
    workflow.setPeerApprovalPending(pending);
    _notify();
  }

  /// User dismisses the workflow progress panel (workflow state is preserved).
  @override
  void dismissWorkflowPanel() {
    workflow.dismissPanel();
    notifyListeners();
  }

  /// Cancel a running workflow execution.
  /// Called when user explicitly stops a workflow from the UI.
  @override
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
  @override
  Future<void> handleWorkflowApproval(bool approved, {String? feedback}) async {
    final workflowId = activeWorkflowId;
    if (workflowId == null || currentChannelId == null) return;

    // Keep the in-chat plan_approval card in sync with the panel action.
    // She DM may still be on a streaming_* host — stash + flush after save.
    _markPlanApprovalRespondedForWorkflow(
      workflowId,
      approved,
      feedback: feedback,
    );

    try {
      await workflow.applyPlanDecision(
        approved: approved,
        workflowId: workflowId,
        startWorkflow: (id) =>
            WorkflowService(db: localDatabaseService).startWorkflow(id),
        cancelWorkflow: (id) =>
            WorkflowService(db: localDatabaseService).cancelWorkflow(id),
        startExecution: (id) async => _beginWorkflowStepExecution(id),
        // 拒绝反馈路由：群聊作为群消息让 admin 重新规划；
        // DM 作为发给 She 的用户消息，由她按反馈重新创建工作流。
        sendRejectionFeedback: (feedbackMessage) =>
            isGroupMode
                ? processGroupMessage(feedbackMessage)
                : processMessage(feedbackMessage),
        feedback: feedback,
        notify: notifyListeners,
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }

    // After DM create-turn save (waited inside startExecution), write the
    // decision onto the durable UUID row so loadMessages cannot revive pending.
    await _flushPlanApprovalResponseToDb(
      workflowId,
      approved,
      feedback: feedback,
    );
  }

  /// Capture in-memory plan decisions before a DB reload can wipe them.
  @override
  void _preserveInMemoryPlanApprovalResponses() {
    for (final msg in messages) {
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null) continue;
      final workflowId = plan['_workflowId'] as String?;
      if (workflowId == null || workflowId.isEmpty) continue;
      if (workflow.pendingPlanResponses.containsKey(workflowId)) continue;
      final responded =
          msg.metadata?['plan_approval_responded'] as Map<String, dynamic>?;
      final approved = responded?['approved'] as bool? ?? plan['_approved'] as bool?;
      if (approved == null) continue;
      workflow.stashPlanApprovalResponse(
        workflowId,
        WorkflowPlanApprovalResponse(
          approved: approved,
          feedback: responded?['feedback'] as String?,
        ),
      );
    }
  }

  /// Mirror panel approve/reject onto the message bubble's plan_approval card.
  @override
  void _markPlanApprovalRespondedForWorkflow(
    String workflowId,
    bool approved, {
    String? feedback,
    bool completeCompleter = true,
  }) {
    workflow.stashPlanApprovalResponse(
      workflowId,
      WorkflowPlanApprovalResponse(approved: approved, feedback: feedback),
    );

    // Update every in-memory card for this workflow (streaming host and/or
    // already-persisted UUID) so the badge flips immediately.
    for (final msg in List<Message>.from(messages)) {
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null || plan['_workflowId'] != workflowId) continue;
      _applyPlanApprovalResponseToMessageId(
        msg.id,
        approved: approved,
        feedback: feedback,
      );
    }

    // Also complete any ChatService-held plan approval Completer so the
    // orchestration path (if still waiting) does not hang.
    if (completeCompleter && currentChannelId != null) {
      chatService.completePlanApproval(
        currentChannelId!,
        WorkflowPlanApprovalSync.buildCompleterPayload(
          approved: approved,
          feedback: feedback,
        ),
      );
    }
  }

  void _applyPlanApprovalResponseToMessageId(
    String messageId, {
    required bool approved,
    String? feedback,
  }) {
    final existing = messageIdMap[messageId];
    if (existing == null) return;
    final existingPlan =
        existing.metadata?['plan_approval'] as Map<String, dynamic>?;
    _updateGroupStreamingMetadata(
      messageId,
      'plan_approval_responded',
      WorkflowPlanApprovalSync.buildRespondedPatch(
        approved: approved,
        feedback: feedback,
      ),
    );
    if (existingPlan != null) {
      _updateGroupStreamingMetadata(
        messageId,
        'plan_approval',
        WorkflowPlanApprovalSync.mergeApprovedFlag(existingPlan, approved),
      );
    }
  }

  /// Persist a stashed panel/card decision onto the durable plan_approval row.
  @override
  Future<void> _flushPlanApprovalResponseToDb(
    String workflowId,
    bool approved, {
    String? feedback,
  }) async {
    if (currentChannelId == null) return;

    Message? target = WorkflowPlanApprovalSync.findPlanApprovalMessage(
      messages: messages,
      workflowId: workflowId,
      preferPersisted: true,
    );
    if (target == null ||
        WorkflowPlanApprovalSync.isEphemeralHostId(target.id)) {
      final dbMessages =
          await chatService.loadChannelMessages(currentChannelId!);
      target = WorkflowPlanApprovalSync.findPlanApprovalMessage(
        messages: dbMessages,
        workflowId: workflowId,
        preferPersisted: true,
      );
    }
    if (target == null ||
        WorkflowPlanApprovalSync.isEphemeralHostId(target.id)) {
      return;
    }

    final baseMeta = messageIdMap[target.id]?.metadata ?? target.metadata;
    final meta = WorkflowPlanApprovalSync.applyResponseToMetadata(
      baseMeta,
      approved: approved,
      feedback: feedback,
    );
    await localDatabaseService.updateMessageMetadata(target.id, meta);

    _applyPlanApprovalResponseToMessageId(
      target.id,
      approved: approved,
      feedback: feedback,
    );
    // Ephemeral host may still be on screen until streaming clears — keep it
    // visually in sync too.
    for (final msg in List<Message>.from(messages)) {
      if (!WorkflowPlanApprovalSync.isEphemeralHostId(msg.id)) continue;
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null || plan['_workflowId'] != workflowId) continue;
      _applyPlanApprovalResponseToMessageId(
        msg.id,
        approved: approved,
        feedback: feedback,
      );
    }

    workflow.takePlanApprovalResponse(workflowId);
    _notify();
  }

  /// Re-apply stashed panel decisions after load/reload wiped streaming hosts.
  @override
  void _reapplyStashedPlanApprovalResponses() {
    if (workflow.pendingPlanResponses.isEmpty) return;
    for (final entry in workflow.pendingPlanResponses.entries) {
      _markPlanApprovalRespondedForWorkflow(
        entry.key,
        entry.value.approved,
        feedback: entry.value.feedback,
        completeCompleter: false,
      );
    }
  }

  @override
  Future<void> _flushAllStashedPlanApprovalResponses() async {
    final pending = Map<String, WorkflowPlanApprovalResponse>.from(
      workflow.pendingPlanResponses,
    );
    for (final entry in pending.entries) {
      await _flushPlanApprovalResponseToDb(
        entry.key,
        entry.value.approved,
        feedback: entry.value.feedback,
      );
    }
  }

  /// Run (or resume) workflow step execution in the background.
  Future<void> _beginWorkflowStepExecution(String workflowId) async {
    if (currentChannelId == null) return;
    // Prefer ChatService's in-process guard — controller token is lost on
    // dispose/channel switch and must not be the only concurrency check.
    if (chatService.isWorkflowExecuting(workflowId)) {
      _reattachWorkflowExecutionUI(workflowId);
      return;
    }

    // DM 竞态防护：用户在 She 的 create 回合尚未结束时就批准计划 ——
    // 先等该回合落库完毕再启动步骤执行，避免同频道两个回合重叠。
    if (!isGroupMode) {
      final activeTask = chatService.getActiveTask(currentChannelId!);
      if (activeTask != null) {
        await activeTask.dbSaveCompleter.future
            .timeout(const Duration(minutes: 2), onTimeout: () {});
      }
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
      onOsToolConfirmation: (toolName, args, risk) async {
        final event = ShowOsToolConfirmationEvent(toolName, args, risk);
        _emit(event);
        return await event.result.future;
      },
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
    scheduleStreamingScrollToBottom();
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
    // 排空工作流期间用户排队的消息（此前 isProcessing=true 导致入队）。
    unawaited(processNextInQueue());
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
    final savedMsgId = GroupInteractionPlanner.takeSavedMessageId(data);
    final sid = _resolveGroupInteractionMessageId(
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
      preferredSid: GroupInteractionPlanner.resolvePreferredSid(
        streamingSid: _workflowStreamingIds[agentId],
        savedMessageId: savedMsgId,
        hasMessage: messageIdMap.containsKey,
        preferSaved: true,
      ),
    );

    if (sid != null) {
      _updateGroupStreamingMetadata(sid, interactionType, data);
      localDatabaseService
          .updateMessageMetadata(
            sid,
            GroupInteractionPlanner.metadataForPersist(
              existing: messageIdMap[sid]?.metadata,
              interactionType: interactionType,
              data: data,
            ),
          )
          .ignore();
    }

    final event = GroupInteractionRequestEvent(
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
      groupStreamingMessageId: sid ?? agentId,
    );
    final confirmationId = data['confirmation_id'] as String?;
    final pendingKey = GroupInteractionPlanner.pendingKey(
      interactionType: interactionType,
      data: data,
      sid: sid,
      agentId: agentId,
    );
    pendingGroupInteractions[pendingKey] = event;
    _notify();
    _emit(event);

    if (currentChannelId != null) {
      final hubItem = PendingApprovalItem.fromInteraction(
        channelId: currentChannelId!,
        agentId: agentId,
        agentName: agentName,
        interactionType: interactionType,
        data: data,
        messageId: sid,
      );
      if (hubItem != null) {
        PendingApprovalHub.instance.upsert(hubItem);
      }
    }

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
  @override
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
  @override
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
}
