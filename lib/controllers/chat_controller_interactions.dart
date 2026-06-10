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
      {'approved': approved},
    );
    // Merge _approved into the plan_approval data so the card badge updates
    final existing = messageIdMap[originalMessage.id];
    if (existing != null) {
      final existingPlanData = existing.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (existingPlanData != null) {
        final merged = Map<String, dynamic>.from(existingPlanData);
        merged['_approved'] = approved;
        _updateGroupStreamingMetadata(originalMessage.id, 'plan_approval', merged);
      }
    }

    // Submit result through ChatService Completer (survives channel switch)
    if (currentChannelId != null) {
      chatService.completePlanApproval(currentChannelId!, {
        'approved': approved,
        if (feedback != null && feedback.isNotEmpty) 'feedback': feedback,
        if (skippedTaskIds != null && skippedTaskIds.isNotEmpty)
          'skipped_task_ids': skippedTaskIds,
      });

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
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_action_id': actionId,
        'selected_action_label': actionLabel,
      });
      _updateGroupStreamingMetadata(originalMessage.id, 'action_confirmation_responded', {'action_id': actionId, 'action_label': actionLabel});
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
