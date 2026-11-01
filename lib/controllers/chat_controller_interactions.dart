part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Interactive response handlers (delegates to InteractiveResponseHandler)
//
// 处理消息内交互组件（动作确认 / 单选 / 多选 / 文件上传 / 表单 / 计划审批）
// 的用户响应。除内部互调的 [_handleGroupInteractionLocally] 外，均为 UI 回调，
// 不被控制器核心逻辑反向调用，因此拆分为挂载在 [_ChatControllerBase] 上的 mixin。
// ---------------------------------------------------------------------------

mixin _InteractionOps on _ChatControllerBase {
  static const _cliExpiredActionId = 'expired';

  @override
  Future<bool> requestCliApproval(
    String toolName,
    Map<String, dynamic> flags,
    os_exec.RiskLevel risk, {
    required String? channelId,
    required String? agentId,
  }) async {
    if (CliApprovalCoordinator.instance.isGrantedForSession(toolName)) {
      return true;
    }
    final owner = channelId?.trim() ?? '';
    if (owner.isEmpty) {
      // 调用链漏了归属会话 —— 属于 bug。宁可拒绝也不把卡扔进当前页面。
      LoggerService().warning(
        'CLI approval for $toolName arrived without an owning channel — '
        'denied',
        tag: 'CliApproval',
      );
      return false;
    }

    final aid = (agentId != null && agentId.trim().isNotEmpty)
        ? agentId.trim()
        : _cliApprovalAgentId;
    final confirmationId = CliApprovalCard.confirmationIdFor(toolName);

    // 归属不是当前会话：卡不进当前列表，落进归属频道 + 顶部提醒。
    if (owner != currentChannelId) {
      final approved = await CliApprovalCard.awaitOffscreen(
        confirmationId: confirmationId,
        toolName: toolName,
        flags: flags,
        risk: risk,
        channelId: owner,
        agentId: aid,
        agentName: agentName,
        db: localDatabaseService,
      );
      // 超时 / 回合取消：卡片不在本页，直接撤掉全局提醒。
      if (!approved) {
        PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);
      }
      return approved;
    }

    final actionData = CliApprovalCard.buildActionData(
      confirmationId: confirmationId,
      toolName: toolName,
      flags: flags,
      risk: risk,
    );
    _insertCliApprovalCard(actionData, agentId: aid);
    final approved = await CliApprovalService.instance.awaitApproval(
      confirmationId: confirmationId,
      toolName: toolName,
      channelId: owner,
    );
    // Timeout / channel cancel complete the waiter as denied without a tap.
    // Expire the card immediately so Allow/Deny cannot look still live.
    if (!approved) {
      _expireCliCardByConfirmationId(confirmationId);
    }
    return approved;
  }

  String? _messageIdForCliConfirmation(String confirmationId) {
    if (confirmationId.isEmpty) return null;
    for (final msg in messages) {
      final ac = msg.metadata?['action_confirmation'];
      if (ac is! Map) continue;
      if (ac['confirmation_id'] == confirmationId) return msg.id;
    }
    return null;
  }

  /// 卡片落在哪条消息上：审批卡看 `confirmation_id`，表单卡看 `form_id`。
  /// 主机发的「卡片作废」帧只带 id，DM / 群聊 / 孤儿卡都靠这里反查 ——
  /// 三条路径落到的都是消息 metadata 里的同一张卡。
  String? _messageIdForInteraction(String interactionId) {
    if (interactionId.isEmpty) return null;
    for (final msg in messages) {
      final ac = msg.metadata?['action_confirmation'];
      if (ac is Map && ac['confirmation_id'] == interactionId) return msg.id;
      final form = msg.metadata?['form'];
      if (form is Map && form['form_id'] == interactionId) return msg.id;
    }
    return null;
  }

  /// 主机不再等这张卡了：等不到回答（`timeout`，按默认继续）或回合被停止
  /// （`cancelled`），本地兜底时用 `turn_ended`。
  ///
  /// 卡片留在对话里（「问过但没答」这个事实值得留着），只是收起可点态：不作废
  /// 的话，用户点下去只会撞上 PeerApprovalExpiredException 弹一句「已失效」，
  /// 而这本来是可以预知的。
  void _handleInteractionClosed(({String approvalId, String reason}) event) {
    // 横幅提醒可能指向别的会话（本页根本没有这张卡的消息行）：先按 id
    // 清掉全局提醒，再处理本页的可点态。
    PendingApprovalHub.instance.resolveByConfirmationId(event.approvalId);
    final messageId = _messageIdForInteraction(event.approvalId);
    if (messageId == null) return;
    final meta = messageIdMap[messageId]?.metadata;
    final ac = meta?['action_confirmation'];
    if (ac is Map) {
      // 已经作答（或已作废）的卡不动：用户的裁决/先到的作废帧都更可信。
      if (ac['selected_action_id'] != null || ac['closed'] != null) return;
      _markActionConfirmationClosed(messageId, reason: event.reason);
      return;
    }
    final form = meta?['form'];
    if (form is Map) {
      if (form['submitted_values'] != null || form['closed'] != null) return;
      _markFormClosed(messageId, reason: event.reason);
    }
  }

  /// 提问在回合内等超时：这一轮结束了，卡片留着等用户以后回答。
  ///
  /// 不能标成 `closed` —— 那会让「不回答」和「还能答」看起来一样。
  ///
  /// `reopened`：本机在回合内提交过，但引擎没拿到这份答案。卡片还在这一页
  /// 上时不让用户再点一次，交给界面用同一份答案续上（[ResubmitLostFormAnswerEvent]
  /// → [resubmitLostFormAnswer]）。
  void _handleFormDeferred(
    ({String approvalId, String requestId, bool reopened}) event,
  ) {
    final messageId = _messageIdForInteraction(event.approvalId);
    if (messageId == null) return;
    final message = messageIdMap[messageId];
    final form = message?.metadata?['form'];
    final values = form is Map ? form['submitted_values'] : null;
    if (event.reopened && message != null && values is Map) {
      _emit(ResubmitLostFormAnswerEvent(
        message: message,
        approvalId: event.approvalId,
        values: Map<String, dynamic>.from(values),
      ));
      return;
    }
    _markFormDeferred(messageId, event.approvalId, reopen: event.reopened);
  }

  /// 把内存里的卡标成 deferred；[reopen] 时连「已提交」一起退回可答（预填）。
  void _markFormDeferred(
    String messageId,
    String approvalId, {
    required bool reopen,
  }) {
    final metadata = messageIdMap[messageId]?.metadata;
    if (metadata == null) return;
    // 旧回合的 turn_ended 可能先到并写了 closed；deferred 它不是作废。
    final next = metadataMarkingFormDeferred(
      Map<String, dynamic>.from(metadata),
      interactionId: approvalId,
      reopen: reopen,
    );
    final merged = next?['form'];
    if (merged is! Map<String, dynamic>) return;
    _updateGroupStreamingMetadata(messageId, 'form', merged);
    if (reopen) {
      // `_markPeerFormSubmitted` 也往活动任务上抄了一份；不清掉的话任务
      // metadata 合并回消息时又把它变回「已提交」。
      final channelId = currentChannelId;
      final task =
          channelId == null ? null : chatService.getActiveTask(channelId);
      final taskForm = task?.metadata?['form'];
      if (task != null && taskForm is Map) {
        task.metadata = Map<String, dynamic>.from(task.metadata!)
          ..['form'] = (Map<String, dynamic>.from(taskForm)
            ..remove('submitted_values'));
      }
    }
    final meta =
        Map<String, dynamic>.from(messageIdMap[messageId]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(messageId, meta).ignore();
  }

  /// 回合内交过、引擎却没拿到的答案：用同一份答案按回合外作答再交一次，
  /// 并另开一轮。主机只在没收到回答时才 defer，所以引擎那边不会重复。
  ///
  /// 卡片已经被主机收掉（答案和超时擦肩而过，主机按回合外作答收了卡但
  /// 不代开回合）时，答案同样没进引擎，照样另开一轮。再交也送不出去时
  /// 把卡退回可答、预填答案，交给用户。
  Future<void> resubmitLostFormAnswer(
    Message message,
    String approvalId,
    Map<String, dynamic> values, {
    String? instructionName,
  }) async {
    final formMeta = message.metadata?['form'];
    final peerForm = formMeta is Map ? formMeta['peer_form'] : null;
    final peerId = peerForm is Map ? peerForm['peer_id']?.toString() ?? '' : '';
    var continueTurn = true;
    try {
      if (peerId.isEmpty) throw StateError('form card has no peer');
      continueTurn = await PeerAgentClientService.instance.submitForm(
        peerId: peerId,
        approvalId: approvalId,
        values: values,
      );
    } on PeerApprovalExpiredException {
      // 卡已在主机那边收场：那份答案没进引擎，照样续上。
    } catch (e) {
      _markFormDeferred(message.id, approvalId, reopen: true);
      _emit(ShowErrorSnackBarEvent('$e'));
      return;
    }
    if (!continueTurn) return;
    await sendDeferredFormFollowUp(
      _deferredFormFollowUpText(approvalId, values),
      instructionName: instructionName,
    );
  }

  /// 这张审批卡此刻还有人在等。停靠卡只接这些：历史里没收场的旧卡（进程
  /// 重启前没等到作废帧、旧协议的卡）点下去只会报「已失效」，停在输入框
  /// 上方反而挡路。
  bool isApprovalCardLive(Message message) {
    if (message.metadata?['hub_interaction'] is Map) return true;
    final card = message.metadata?['action_confirmation'];
    if (card is! Map) return false;
    final id = card['confirmation_id']?.toString() ?? '';
    if (id.isEmpty) return false;
    switch (card['confirmation_context']) {
      case 'cli':
        return CliApprovalService.instance.hasLive(id);
      case 'peer':
        return PeerAgentClientService.instance.isApprovalTracked(id);
      default:
        return false;
    }
  }

  /// 审批卡作废：复用 cli 审批卡的 `expired` 约定收起可点态（那套渲染与对账
  /// 已经按「不是用户选的」处理），再记下原因给 UI 显示。
  ///
  /// 不写 `action_confirmation_responded` —— 那是「用户答过了」，会牵动工作流
  /// 续跑与对账，作废不是回答。
  void _markActionConfirmationClosed(
    String messageId, {
    required String reason,
  }) {
    final existing = messageIdMap[messageId]?.metadata?['action_confirmation'];
    final merged = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    PeerApprovalSelection.applySelection(merged, {
      'selected_action_id': _cliExpiredActionId,
      'selected_action_label': _cliExpiredActionId,
    });
    merged['closed'] = reason;
    if (merged['confirmation_context'] == 'cli') {
      final base = Map<String, dynamic>.from(
        messageIdMap[messageId]?.metadata ?? {},
      );
      base['action_confirmation'] = merged;
      _setMessageMetadata(messageId, CliAuditFold.foldDecided(base));
      return;
    }
    _updateGroupStreamingMetadata(messageId, 'action_confirmation', merged);
    // 落库：否则下一次 loadMessages 会把卡片又画成「等你点」。
    final meta =
        Map<String, dynamic>.from(messageIdMap[messageId]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(messageId, meta).ignore();
  }

  /// 表单卡作废。不能借 `submitted_values` 表达 —— 那会谎称用户提交过。
  void _markFormClosed(String messageId, {required String reason}) {
    final existing = messageIdMap[messageId]?.metadata?['form'];
    final merged = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    merged['closed'] = reason;
    _updateGroupStreamingMetadata(messageId, 'form', merged);
    final meta =
        Map<String, dynamic>.from(messageIdMap[messageId]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(messageId, meta).ignore();
  }

  void _expireCliCardByConfirmationId(String confirmationId) {
    final messageId = _messageIdForCliConfirmation(confirmationId);
    if (messageId == null) return;
    final ac = messageIdMap[messageId]?.metadata?['action_confirmation'];
    if (ac is Map && ac['selected_action_id'] != null) return;
    _markActionConfirmationSelected(
      messageId,
      actionId: _cliExpiredActionId,
      actionLabel: _cliExpiredActionId,
    );
    PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);
  }

  void _insertCliApprovalCard(
    Map<String, dynamic> actionData, {
    String? agentId,
  }) {
    final aid = agentId?.trim().isNotEmpty == true
        ? agentId!.trim()
        : _cliApprovalAgentId;
    // 同一回合的确认收进一条审计气泡。上一张还没答时不能盖掉，另起一条。
    final host = CliAuditFold.findHost(messages, aid);
    if (host != null) {
      final next = CliAuditFold.attachPending(
        metadata: host.metadata,
        actionData: actionData,
      );
      if (next != null) {
        _setMessageMetadata(host.id, next);
        _surfaceCliAuditHost(host.id);
        _publishCliApprovalHub(
          messageId: host.id,
          agentId: aid,
          actionData: actionData,
        );
        return;
      }
    }
    final messageId = _insertCliAuditBubble(actionData, agentId: aid);
    if (messageId == null) return;
    _publishCliApprovalHub(
      messageId: messageId,
      agentId: aid,
      actionData: actionData,
    );
  }

  void _publishCliApprovalHub({
    required String messageId,
    required String agentId,
    required Map<String, dynamic> actionData,
  }) {
    if (currentChannelId == null) return;
    final hubItem = PendingApprovalItem.fromInteraction(
      channelId: currentChannelId!,
      agentId: agentId,
      agentName: agentName ?? 'Agent',
      interactionType: 'action_confirmation',
      data: actionData,
      messageId: messageId,
    );
    if (hubItem != null) {
      PendingApprovalHub.instance.upsert(hubItem);
    }
    _emit(RequestScrollToBottomEvent(force: true));
  }

  /// 复用审计气泡时把它挪到列表末尾，待审按钮跟着当前回合走。
  void _surfaceCliAuditHost(String messageId) {
    final existing = messageIdMap[messageId];
    if (existing == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = Message(
      id: existing.id,
      content: existing.content,
      timestampMs: now,
      from: existing.from,
      to: existing.to,
      channelId: existing.channelId,
      type: existing.type,
      replyTo: existing.replyTo,
      metadata: existing.metadata,
    );
    messages.removeWhere((m) => m.id == messageId);
    messages.add(updated);
    messageIdMap[messageId] = updated;
    sortMessagesByTime(messages);
    _notify();
    localDatabaseService.touchMessageCreatedAt(messageId).ignore();
  }

  void _setMessageMetadata(String messageId, Map<String, dynamic> metadata) {
    final existing = messageIdMap[messageId];
    if (existing == null) return;
    final updated = Message(
      id: existing.id,
      content: existing.content,
      timestampMs: existing.timestampMs,
      from: existing.from,
      to: existing.to,
      channelId: existing.channelId,
      type: existing.type,
      replyTo: existing.replyTo,
      metadata: metadata,
    );
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) messages[idx] = updated;
    messageIdMap[messageId] = updated;
    _notify();
    localDatabaseService.updateMessageMetadata(messageId, metadata).ignore();
  }

  void _catchUpGroupUiAfterCliApproval(String messageId) {
    groupStreamingMessageIds.remove(messageId);
    if (!isGroupMode || currentChannelId == null) return;
    _scheduleGroupReconcile();
    if (chatService.isGroupChannelOrchestrating(currentChannelId!) &&
        !isProcessing) {
      reattachToGroupActiveTasks();
    }
    _emit(RequestScrollToBottomEvent(force: true));
  }

  String get _cliApprovalAgentId {
    final id = agentId;
    if (id != null && id.isNotEmpty) return id;
    for (final sid in groupStreamingMessageIds.toList().reversed) {
      final m = messageIdMap[sid];
      if (m != null && m.from.isAgent) return m.from.id;
    }
    for (final m in messages.reversed) {
      if (m.from.isAgent) return m.from.id;
    }
    return 'shepaw-cli';
  }

  /// 本回合第一条 CLI 确认：单独一条审计气泡，不挂进正在流式的正文。
  String? _insertCliAuditBubble(
    Map<String, dynamic> actionData, {
    String? agentId,
  }) {
    final aid = agentId?.trim().isNotEmpty == true
        ? agentId!.trim()
        : _cliApprovalAgentId;
    final displayName = agentName ?? 'Agent';
    final userId = getUserId();
    final userName = getUserName();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sid = CliAuditFold.messageIdFor(aid, nowMs);
    final metadata = CliAuditFold.attachPending(
      metadata: const {},
      actionData: actionData,
    );
    if (metadata == null) return null;
    final sm = Message(
      id: sid,
      content: '',
      timestampMs: nowMs + 1,
      from: MessageFrom(id: aid, type: 'agent', name: displayName),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      metadata: metadata,
    );
    messages.add(sm);
    messageIdMap[sid] = sm;
    _notify();
    if (currentChannelId == null) return sid;
    localDatabaseService
        .createMessage(
          id: sid,
          channelId: currentChannelId!,
          senderId: aid,
          senderType: 'agent',
          senderName: displayName,
          content: '',
          messageType: 'text',
          metadata: metadata,
        )
        .ignore();
    return sid;
  }

  @override
  void _cancelCliApprovalsForCurrentChannel() {
    final cid = currentChannelId;
    if (cid == null) return;
    for (final msg in List<Message>.from(messages)) {
      final ac = msg.metadata?['action_confirmation'];
      if (ac is! Map) continue;
      if (ac['confirmation_context'] != 'cli') continue;
      if (ac['selected_action_id'] != null) continue;
      _markActionConfirmationSelected(
        msg.id,
        actionId: _cliExpiredActionId,
        actionLabel: _cliExpiredActionId,
      );
      final confirmationId = ac['confirmation_id'] as String? ?? '';
      if (confirmationId.isNotEmpty) {
        PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);
      }
    }
    CliApprovalService.instance.cancelForChannel(cid);
  }

  @override
  void _expireStaleCliApprovalCards() {
    final stale = CliApprovalService.instance.expireStaleCards(messages);
    for (final messageId in stale) {
      final ac = messageIdMap[messageId]?.metadata?['action_confirmation'];
      final confirmationId =
          ac is Map ? (ac['confirmation_id'] as String? ?? '') : '';
      _markActionConfirmationSelected(
        messageId,
        actionId: _cliExpiredActionId,
        actionLabel: _cliExpiredActionId,
      );
      if (confirmationId.isNotEmpty) {
        PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);
      }
    }
  }

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
      final groupId = groupChannel?.groupFamilyId ?? currentChannelId ?? '';
      Future.microtask(() async {
        final continued = await GroupOrchestrationContinuation
            .resolveForInteractionResponse(groupId: groupId);
        await processGroupMessage(
          '@$agentName $responseText',
          continueOrchestrationId: continued,
        );
      });
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
    if (merged['confirmation_context'] == 'cli') {
      final base = Map<String, dynamic>.from(existing?.metadata ?? {});
      base['action_confirmation'] = merged;
      _setMessageMetadata(messageId, CliAuditFold.foldDecided(base));
      return;
    }
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

  /// 群聊里成员在等的卡被答了：`*_responded` 只是给对账看的，卡片本身也要
  /// 记成已答，停靠卡才会收起，气泡也不再可点。
  void _markGroupCardAnswered(
    String messageId,
    String key,
    Map<String, dynamic> answer,
  ) {
    final card = messageIdMap[messageId]?.metadata?[key];
    if (card is Map) {
      _updateGroupStreamingMetadata(messageId, key, {
        ...Map<String, dynamic>.from(card),
        ...answer,
      });
    }
    _notify();
  }

  /// 把用户选的选项并进卡片的元数据并落盘（单选 / 多选共用）。
  ///
  /// hub 那条路以前漏了这一步：`_answerHubInteraction` 成功就直接 return，
  /// 只把回包发给主机，本地什么都没记。于是卡片看着还是「没答」，而且随后到的
  /// 作废帧会把它当成没人答过 —— 用户刚点的选择会被说成作废。
  void _markSelectAnswered(
    String messageId,
    String key,
    Map<String, dynamic> selected,
  ) {
    final existing = messageIdMap[messageId]?.metadata?[key];
    final merged = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    merged.addAll(selected);
    // 和直连那条路（`_optimisticUpdate` / `_handleGroupInteractionLocally`）
    // 一样记个时间，两条路的答案记录长得一样，对账时不用分辨是哪条路写的。
    merged['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    _updateGroupStreamingMetadata(messageId, key, merged);
    final meta = Map<String, dynamic>.from(messageIdMap[messageId]?.metadata ?? {});
    localDatabaseService.updateMessageMetadata(messageId, meta).ignore();
  }

  /// Handle peer tool approval from the workflow progress panel (or detail).
  Future<void> handleWorkflowPeerApprovalAction(
    String confirmationId,
    String actionId,
    String actionLabel,
  ) async {
    PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);
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
      if (PeerApprovalExpiredException.matches(e)) {
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
      }
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
      if (PeerApprovalExpiredException.matches(e)) {
        // Expired: keep the tapped button state so restart does not revive
        // a dead pending card (InteractiveResponseHandler also skips rollback).
        _markActionConfirmationSelected(
          originalMessage.id,
          actionId: actionId,
          actionLabel: actionLabel,
        );
        await WorkflowService.instance.markPendingApprovalSubmitted(
          confirmationId,
          selectedActionId: actionId,
        );
        setWorkflowPeerApprovalPending(null);
      }
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
    final existing = messageIdMap[originalMessage.id] ?? originalMessage;
    final planMeta =
        existing.metadata?['plan_approval'] as Map<String, dynamic>?;
    final workflowId = planMeta?['_workflowId'] as String?;

    if (workflowId != null) {
      // Shared path with the floating panel: stash + update all hosts for
      // this workflow (covers She DM streaming_* → UUID handoff).
      _markPlanApprovalRespondedForWorkflow(
        workflowId,
        approved,
        feedback: feedback,
        completeCompleter: false,
      );
    } else {
      // Update UI immediately on the source bubble when workflow id is absent.
      _updateGroupStreamingMetadata(
        originalMessage.id,
        'plan_approval_responded',
        WorkflowPlanApprovalSync.buildRespondedPatch(
          approved: approved,
          feedback: feedback,
        ),
      );
      final existingPlanData =
          messageIdMap[originalMessage.id]?.metadata?['plan_approval']
              as Map<String, dynamic>?;
      if (existingPlanData != null) {
        _updateGroupStreamingMetadata(
          originalMessage.id,
          'plan_approval',
          WorkflowPlanApprovalSync.mergeApprovedFlag(
            existingPlanData,
            approved,
          ),
        );
      }
      final meta = Map<String, dynamic>.from(
        messageIdMap[originalMessage.id]?.metadata ?? {},
      );
      localDatabaseService
          .updateMessageMetadata(originalMessage.id, meta)
          .ignore();
    }

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

      if (workflowId != null) {
        PendingApprovalHub.instance.resolveByWorkflowId(workflowId);
      } else {
        PendingApprovalHub.instance.resolve(
          PendingApprovalItem.fallbackId(
            kind: PendingApprovalKind.plan,
            channelId: currentChannelId!,
            messageId: originalMessage.id,
            agentId: agentId,
          ),
        );
      }

      // If approved and has workflow ID, start execution immediately.
      if (approved && workflowId != null) {
        setActiveWorkflowId(workflowId);
        await handleWorkflowApproval(true);
      } else if (workflowId != null) {
        // Reject from the in-chat card: persist onto the durable row so a
        // concurrent DM loadMessages cannot revive the pending badge.
        await _flushPlanApprovalResponseToDb(
          workflowId,
          approved,
          feedback: feedback,
        );
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

    if (await _answerHubInteraction(originalMessage, {
      'selected_action_id': actionId,
      'selected_action_label': actionLabel,
    })) {
      _markActionConfirmationSelected(
        originalMessage.id,
        actionId: actionId,
        actionLabel: actionLabel,
      );
      return;
    }

    PendingApprovalHub.instance.resolveByConfirmationId(confirmationId);

    if (confirmationContext == 'cli') {
      if (!CliApprovalService.instance.hasLive(confirmationId)) {
        LoggerService().info(
          'CLI approval tap after waiter gone: confirmationId=$confirmationId',
          tag: 'ChatController',
        );
        _expireCliCardByConfirmationId(confirmationId);
        _emit(ShowSnackBarEvent('osTool_approvalExpired'));
        _catchUpGroupUiAfterCliApproval(originalMessage.id);
        return;
      }
      final approved = actionId == 'allow' || actionId == 'allow_session';
      final rememberSession = actionId == 'allow_session';
      _markActionConfirmationSelected(
        originalMessage.id,
        actionId: approved ? 'allow' : actionId,
        actionLabel: actionLabel,
      );
      CliApprovalService.instance.complete(
        confirmationId,
        approved: approved,
        rememberSession: rememberSession,
      );
      _catchUpGroupUiAfterCliApproval(originalMessage.id);
      return;
    }

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
    if (await _answerHubInteraction(originalMessage, {
      'selected': [optionId],
      'selected_option_id': optionId,
      'selected_option_label': optionLabel,
    })) {
      _markSelectAnswered(originalMessage.id, 'single_select', {
        'selected_option_id': optionId,
        'selected_option_label': optionLabel,
      });
      return;
    }
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_option_id': optionId,
        'selected_option_label': optionLabel,
      });
      _updateGroupStreamingMetadata(originalMessage.id, 'single_select_responded', {'option_id': optionId, 'option_label': optionLabel});
      _markGroupCardAnswered(originalMessage.id, 'single_select', {
        'selected_option_id': optionId,
        'selected_option_label': optionLabel,
      });
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
    if (await _answerHubInteraction(originalMessage, {
      'selected': optionIds,
    })) {
      _markSelectAnswered(originalMessage.id, 'multi_select', {
        'selected_option_ids': optionIds,
      });
      return;
    }
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'selected_option_ids': optionIds});
      _updateGroupStreamingMetadata(originalMessage.id, 'multi_select_responded', {'option_ids': optionIds});
      _markGroupCardAnswered(originalMessage.id, 'multi_select', {
        'selected_option_ids': optionIds,
      });
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
      _markGroupCardAnswered(originalMessage.id, 'file_upload', {
        'uploaded_files': files,
      });
      return;
    }
    if (isProcessing && !isGroupMode) {
      _emit(ShowSnackBarEvent('chat_answerAfterReply'));
      return;
    }

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
    String summary, {
    String? instructionName,
  }) async {
    final formMeta = originalMessage.metadata?['form'];
    final peerForm = formMeta is Map ? formMeta['peer_form'] : null;
    if (peerForm is Map) {
      final peerId = peerForm['peer_id']?.toString() ?? '';
      final approvalId = peerForm['approval_id']?.toString() ?? formId;
      if (peerId.isEmpty || approvalId.isEmpty) {
        return;
      }
      try {
        final wasDeferred = await PeerAgentClientService.instance.submitForm(
          peerId: peerId,
          approvalId: approvalId,
          values: values,
        );
        PendingApprovalHub.instance.resolveByConfirmationId(approvalId);
        _markPeerFormSubmitted(originalMessage, values);
        if (wasDeferred) {
          // 旧回合已经收束，答案回不到那次工具调用：用卡片内容正常发一条
          // 消息，开新的一轮接着做。正文是给模型看的内部指令，气泡改用
          // 卡片提交标题展示，别把指令原文当成用户说的话。
          await sendDeferredFormFollowUp(
            _deferredFormFollowUpText(approvalId, values),
            instructionName: instructionName,
          );
        }
      } catch (e) {
        _emit(ShowErrorSnackBarEvent('$e'));
      }
      return;
    }
    if (await _answerHubInteraction(originalMessage, {
      'values': values,
    })) {
      _markPeerFormSubmitted(originalMessage, values);
      return;
    }
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'submitted_values': values});
      _updateGroupStreamingMetadata(originalMessage.id, 'form_responded', {'values': values});
      _markGroupCardAnswered(originalMessage.id, 'form', {
        'submitted_values': values,
      });
      return;
    }
    if (isProcessing && !isGroupMode) {
      // 卡片常驻在输入框上方，回复还在输出时也点得到：说一声，卡片和已填
      // 的内容都留着，等这一轮结束再交。
      _emit(ShowSnackBarEvent('chat_answerAfterReply'));
      return;
    }

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

  /// 用户明确不回答一张 deferred 卡。只关卡，不开新回合。
  Future<void> handleFormDeclined(
    Message originalMessage,
    String formId,
  ) async {
    final formMeta = originalMessage.metadata?['form'];
    final peerForm = formMeta is Map ? formMeta['peer_form'] : null;
    if (peerForm is! Map) return;
    final peerId = peerForm['peer_id']?.toString() ?? '';
    final approvalId = peerForm['approval_id']?.toString() ?? formId;
    if (peerId.isEmpty || approvalId.isEmpty) return;
    try {
      await PeerAgentClientService.instance.declineForm(
        peerId: peerId,
        approvalId: approvalId,
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  /// 回合外作答时发给模型的新一轮正文。
  ///
  /// 带上 `approval_id` 和原问题的键值，模型才知道这是对哪一张卡的答复；
  /// 明确要求它不要再用 `ask_user` 问同一件事。
  String _deferredFormFollowUpText(
    String approvalId,
    Map<String, dynamic> values,
  ) {
    final lines = <String>[
      '用户回答了上一轮挂起的提问（approval_id: $approvalId）。'
          '沿那一轮没做完的任务继续。不要再次调用 ask_user 来问同一件事。',
    ];
    for (final entry in values.entries) {
      final value = entry.value;
      final text = value is List
          ? value.join(', ')
          : value is bool
              ? (value ? 'true' : 'false')
              : '$value';
      lines.add('${entry.key}: $text');
    }
    return lines.join('\n');
  }

  void _markPeerFormSubmitted(
    Message original,
    Map<String, dynamic> values,
  ) {
    final idx = messages.indexWhere((message) => message.id == original.id);
    if (idx != -1) {
      final form = Map<String, dynamic>.from(
        (messages[idx].metadata?['form'] as Map?) ?? const {},
      );
      form['submitted_values'] = values;
      final updated = ChatStreamingText.withMergedMetadata(
        messages[idx],
        {'form': form},
      );
      messages[idx] = updated;
      messageIdMap[updated.id] = updated;
    }
    final channelId = currentChannelId;
    final task = channelId == null ? null : chatService.getActiveTask(channelId);
    if (task != null) {
      final meta = Map<String, dynamic>.from(task.metadata ?? {});
      final form = Map<String, dynamic>.from((meta['form'] as Map?) ?? const {});
      form['submitted_values'] = values;
      meta['form'] = form;
      task.metadata = meta;
    }
    _notify();
  }

  Future<bool> _answerHubInteraction(
    Message message,
    Map<String, dynamic> result,
  ) async {
    final hub = message.metadata?['hub_interaction'];
    if (hub is! Map) return false;
    final peerId = hub['host_peer_id']?.toString() ?? '';
    final interactionId = hub['interaction_id']?.toString() ?? '';
    if (peerId.isEmpty || interactionId.isEmpty) return false;
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'pouch_interaction_resp',
      'interaction_id': interactionId,
      'result': result,
    });
    return true;
  }
}
