part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Interactive response handlers (delegates to InteractiveResponseHandler)
//
// 处理消息内交互组件（动作确认 / 单选 / 多选 / 文件上传 / 表单 / 计划审批）
// 的用户响应。除内部互调的 [_handleGroupInteractionLocally] 外，均为 UI 回调，
// 不被控制器核心逻辑反向调用，因此拆分为挂载在 [_ChatControllerBase] 上的 mixin。
// ---------------------------------------------------------------------------

mixin _InteractionOps on _ChatControllerBase {
  /// Helper: for group chat with local LLM agents that have already finished,
  /// just persist the user's interactive response to the message metadata in
  /// DB.  Returns true if handled (caller should return early).
  Future<bool> _handleGroupInteractionLocally(
    Message originalMessage,
    String metadataKey,
    Map<String, dynamic> selectedData, {
    String? responseText,
  }) async {
    if (!isGroupMode) return false;
    final updatedMeta = Map<String, dynamic>.from(originalMessage.metadata ?? {});
    final section = Map<String, dynamic>.from(
      updatedMeta[metadataKey] as Map<String, dynamic>? ?? {},
    );
    section.addAll(selectedData);
    section['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    updatedMeta[metadataKey] = section;

    // Update in-memory message
    final idx = messages.indexWhere((m) => m.id == originalMessage.id);
    if (idx != -1) {
      final updated = Message(
        id: originalMessage.id,
        content: originalMessage.content,
        timestampMs: originalMessage.timestampMs,
        from: originalMessage.from,
        to: originalMessage.to,
        type: originalMessage.type,
        replyTo: originalMessage.replyTo,
        metadata: updatedMeta,
      );
      messages[idx] = updated;
      messageIdMap[updated.id] = updated;
      _notify();
    }

    try {
      await localDatabaseService.updateMessageMetadata(originalMessage.id, updatedMeta);
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }

    // For local LLM agents, trigger a follow-up round so the agent can
    // process the user's interaction response and generate a reply.
    // Prefix with @agentName so the agent has context that it is being
    // directly addressed (needed for it to generate UI widgets like
    // action_confirmation).  When there is a group admin and the mentioned
    // agent IS the admin, sendMessageToGroup will detect that the sole
    // mention is the admin and fall through to the admin orchestration loop
    // (path 5b) rather than the simple direct-dispatch path (5a), so the
    // admin's subsequent @mentions of member agents will still be honoured.
    if (responseText != null && originalMessage.from.isAgent) {
      final agentName = originalMessage.from.name;
      Future.microtask(() => processGroupMessage('@$agentName $responseText'));
    }

    return true;
  }

  /// Unblock a workflow step (or in-flight peer gate) waiting on tool approval.
  /// Returns true when an active completer was satisfied.
  bool _completePendingPeerApproval(
    Message originalMessage, {
    required String actionId,
    required String actionLabel,
    String? confirmationId,
  }) {
    return PeerApprovalCompleterResolver.completePending(
      pendingGroupInteractions,
      originalMessage: originalMessage,
      actionId: actionId,
      actionLabel: actionLabel,
      confirmationId: confirmationId,
    );
  }

  /// Merge a selected action into the message's `action_confirmation` metadata
  /// so the inline buttons switch to the post-approval (selected) visual state.
  void _markActionConfirmationSelected(
    String messageId, {
    required String actionId,
    required String actionLabel,
  }) {
    final existing = messageIdMap[messageId];
    final existingAc = existing?.metadata?['action_confirmation'];
    final merged = existingAc is Map
        ? Map<String, dynamic>.from(existingAc)
        : <String, dynamic>{};
    PeerApprovalSelection.applySelection(merged, {
      'selected_action_id': actionId,
      if (actionLabel.isNotEmpty) 'selected_action_label': actionLabel,
    });
    _updateGroupStreamingMetadata(messageId, 'action_confirmation', merged);
    _updateGroupStreamingMetadata(
      messageId,
      'action_confirmation_responded',
      {'action_id': actionId, 'action_label': actionLabel},
    );
    // Persist so reconcile / channel reload cannot revive the pending card.
    final meta = Map<String, dynamic>.from(messageIdMap[messageId]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(messageId, meta).ignore();
  }

  /// Handle peer tool approval from the workflow progress panel (or detail).
  Future<void> handleWorkflowPeerApprovalAction(
    String confirmationId,
    String actionId,
    String actionLabel,
  ) async {
    final pending = workflowPeerApprovalPending;
    final workflowIdForResume = pending?.workflowId;
    Message? msg;
    final messageId = pending?.messageId;
    if (messageId != null) {
      msg = messageIdMap[messageId] ??
          await chatService.getMessageById(messageId);
    }

    if (msg != null) {
      final unblocked = await _handlePeerActionSelected(
        msg,
        confirmationId,
        actionId,
        actionLabel,
        channelId: pending?.execChannelId,
      );
      if (!unblocked && workflowIdForResume != null) {
        await _resumeWorkflowExecutionIfNeeded(workflowIdForResume);
      }
      return;
    }

    final record =
        await WorkflowService.instance.getPendingApprovalById(confirmationId);
    if (record == null) return;

    try {
      await PeerAgentClientService.instance.submitApproval(
        peerId: record.peerId,
        approvalId: record.confirmationId,
        selectedActionId: actionId,
        selectedActionLabel: actionLabel,
      );
      await WorkflowService.instance.markPendingApprovalSubmitted(
        confirmationId,
        selectedActionId: actionId,
      );
      setWorkflowPeerApprovalPending(null);
      if (record.messageId != null &&
          messageIdMap.containsKey(record.messageId)) {
        _markActionConfirmationSelected(
          record.messageId!,
          actionId: actionId,
          actionLabel: actionLabel,
        );
      }
      await _resumeWorkflowExecutionIfNeeded(record.workflowId);
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<bool> _handlePeerActionSelected(
    Message originalMessage,
    String confirmationId,
    String actionId,
    String actionLabel, {
    String? channelId,
  }) async {
    try {
      await interactiveResponseHandler.handleActionConfirmation(
        originalMessage: originalMessage,
        confirmationId: confirmationId,
        actionId: actionId,
        actionLabel: actionLabel,
        confirmationContext: 'peer',
        channelId: channelId,
      );
      final unblocked = _completePendingPeerApproval(
        originalMessage,
        actionId: actionId,
        actionLabel: actionLabel,
        confirmationId: confirmationId,
      );
      await WorkflowService.instance.markPendingApprovalSubmitted(
        confirmationId,
        selectedActionId: actionId,
      );
      setWorkflowPeerApprovalPending(null);
      _markActionConfirmationSelected(
        originalMessage.id,
        actionId: actionId,
        actionLabel: actionLabel,
      );
      return unblocked;
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
      return false;
    }
  }

  Future<void> handlePlanApprovalResponded(
    Message originalMessage,
    bool approved, {
    String? feedback,
    List<String>? skippedTaskIds,
  }) async {
    // Update UI immediately
    _updateGroupStreamingMetadata(
      originalMessage.id,
      'plan_approval_responded',
      WorkflowPlanApprovalSync.buildRespondedPatch(
        approved: approved,
        feedback: feedback,
      ),
    );
    // Merge _approved into the plan_approval data so the card badge updates
    final existing = messageIdMap[originalMessage.id];
    if (existing != null) {
      final existingPlanData = existing.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (existingPlanData != null) {
        _updateGroupStreamingMetadata(
          originalMessage.id,
          'plan_approval',
          WorkflowPlanApprovalSync.mergeApprovedFlag(existingPlanData, approved),
        );
      }
    }
    // Persist so channel reload / reconcile cannot revive the pending card.
    final meta = Map<String, dynamic>.from(
      messageIdMap[originalMessage.id]?.metadata ?? {},
    );
    localDatabaseService
        .updateMessageMetadata(originalMessage.id, meta)
        .ignore();

    // Submit result through ChatService Completer (survives channel switch)
    if (currentChannelId != null) {
      chatService.completePlanApproval(
        currentChannelId!,
        WorkflowPlanApprovalSync.buildCompleterPayload(
          approved: approved,
          feedback: feedback,
          skippedTaskIds: skippedTaskIds,
        ),
      );

      // If approved and has workflow ID, start execution immediately.
      if (approved) {
        final existingMsg = messageIdMap[originalMessage.id];
        final planMeta = existingMsg?.metadata?['plan_approval'] as Map<String, dynamic>?;
        final workflowId = planMeta?['_workflowId'] as String?;
        if (workflowId != null) {
          setActiveWorkflowId(workflowId);
          await handleWorkflowApproval(true);
        }
      }
    }
  }

  Future<void> handleActionSelected(
    Message originalMessage,
    String confirmationId,
    String actionId,
    String actionLabel, {
    String? confirmationContext,
  }) async {
    LoggerService().info(
      'handleActionSelected: confirmationId=$confirmationId, '
      'actionId=$actionId, label="$actionLabel", '
      'context=$confirmationContext, isProcessing=$isProcessing',
      tag: 'ChatController',
    );

    // Peer in-band approvals in group chat: the original P2P sendChat turn is
    // still live on GroupAgentExecutor. Submit via submitApproval instead of
    // starting a new group round through _handleGroupInteractionLocally.
    if (isGroupMode && confirmationContext == 'peer') {
      final workflowIdForResume = workflowPeerApprovalPending?.workflowId;
      final unblocked = await _handlePeerActionSelected(
        originalMessage,
        confirmationId,
        actionId,
        actionLabel,
      );
      if (!unblocked && workflowIdForResume != null) {
        await _resumeWorkflowExecutionIfNeeded(workflowIdForResume);
      }
      return;
    }

    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_action_id': actionId,
        'selected_action_label': actionLabel,
      });
      _markActionConfirmationSelected(
        originalMessage.id,
        actionId: actionId,
        actionLabel: actionLabel,
      );
      return;
    }

    // Check if this is a plan confirmation (agent used action_confirmation instead of
    // the system plan_approval UI). Use execution-trigger phrasing so the admin knows
    // to proceed with task delegation rather than re-plan.
    final isPlanConfirm = confirmationId.startsWith('plan_confirm');
    final responseTextForGroup = isPlanConfirm && actionId != 'modify'
        ? 'User selected action: $actionLabel. 请立即开始按计划执行，直接委派任务给各成员，不要重新输出计划。'
        : 'User selected action: $actionLabel';

    if (await _handleGroupInteractionLocally(originalMessage, 'action_confirmation', {
      'selected_action_id': actionId,
    }, responseText: responseTextForGroup)) return;

    // NOTE: intentionally NOT gated on `isProcessing`. An action-confirmation
    // tap is a reply to the in-flight task, not a fresh user turn — for ACP
    // agents (e.g. codebuddy-code's canUseTool), the reply is delivered as
    // a new `agent.chat` that the agent classifies as an allow/deny verdict,
    // and only THEN does the original task's `task.completed` fire. Guarding
    // on `isProcessing` here would drop the tap silently, stranding the user
    // (task hangs forever, UI spinner never clears).

    try {
      await interactiveResponseHandler.handleActionConfirmation(
        originalMessage: originalMessage,
        confirmationId: confirmationId,
        actionId: actionId,
        actionLabel: actionLabel,
        confirmationContext: confirmationContext,
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleSingleSelectSubmitted(
    Message originalMessage,
    String selectId,
    String optionId,
    String optionLabel,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_option_id': optionId,
        'selected_option_label': optionLabel,
      });
      _updateGroupStreamingMetadata(originalMessage.id, 'single_select_responded', {'option_id': optionId, 'option_label': optionLabel});
      return;
    }
    // See handleActionSelected for why `isProcessing` is not checked here.

    if (await _handleGroupInteractionLocally(originalMessage, 'single_select', {
      'selected_option_id': optionId,
    }, responseText: 'Selected: $optionLabel')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'single_select',
        selectedData: {'selected_option_id': optionId},
        responseText: 'Selected: $optionLabel',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleMultiSelectSubmitted(
    Message originalMessage,
    String selectId,
    List<String> optionIds,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'selected_option_ids': optionIds});
      _updateGroupStreamingMetadata(originalMessage.id, 'multi_select_responded', {'option_ids': optionIds});
      return;
    }
    // See handleActionSelected for why `isProcessing` is not checked here.

    if (await _handleGroupInteractionLocally(originalMessage, 'multi_select', {
      'selected_option_ids': optionIds,
    }, responseText: 'Selected: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'multi_select',
        selectedData: {'selected_option_ids': optionIds},
        responseText: 'Selected: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleFileUploadSubmitted(
    Message originalMessage,
    String uploadId,
    List<Map<String, dynamic>> files,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'uploaded_files': files});
      _updateGroupStreamingMetadata(originalMessage.id, 'file_upload_responded', {'files': files});
      return;
    }
    if (isProcessing && !isGroupMode) return;


    if (await _handleGroupInteractionLocally(originalMessage, 'file_upload', {
      'uploaded_files': files,
    }, responseText: 'Uploaded files: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'file_upload',
        selectedData: {'uploaded_files': files},
        responseText: 'Uploaded files: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleFormSubmitted(
    Message originalMessage,
    String formId,
    Map<String, dynamic> values,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'submitted_values': values});
      _updateGroupStreamingMetadata(originalMessage.id, 'form_responded', {'values': values});
      return;
    }
    if (isProcessing && !isGroupMode) return;

    if (await _handleGroupInteractionLocally(originalMessage, 'form', {
      'submitted_values': values,
    }, responseText: 'Form submitted: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'form',
        selectedData: {'submitted_values': values},
        responseText: 'Form submitted: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }
}
