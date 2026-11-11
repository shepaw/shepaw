part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Messaging / streaming send path
//
// DM + group send, stop, reattach, and in-band interaction host updates.
// Declared as a mixin so [_ChatControllerBase] can keep abstract hooks that
// workflow / loadMessages call, while the bulky implementations live here.
// ---------------------------------------------------------------------------

mixin _MessagingOps on _ChatControllerBase {
  /// Held from the start of [sendMessage] until the composer is cleared, so a
  /// second tap during the attachment lookup cannot send the same text twice.
  bool _composerSendLocked = false;

  // ---------------------------------------------------------------------------
  // Reattach to background tasks
  // ---------------------------------------------------------------------------

  @override
  void reattachToActiveTask() {
    if (currentChannelId == null) return;

    final activeTask = chatService.getActiveTask(currentChannelId!);
    if (activeTask == null) return;

    // Prefer the flushed partial already loaded from DB so switch-back does
    // not stack a second near-duplicate streaming bubble.
    final reusable = ChatMessageReconciler.findReusableDmStreamingHost(
      messages: messages,
      agentId: activeTask.agentId,
      partialMessageId: activeTask.partialMessageId,
    );
    final hostId = reusable?.id ??
        'streaming_reattach_${DateTime.now().millisecondsSinceEpoch}';

    streaming.begin(hostId, fromId: activeTask.agentId);
    streaming.content = activeTask.accumulatedContent;

    // 复用的占位可能带着上一回合的旧时间戳（flush 行可能几分钟前就落库），
    // 沿用它会让「正在回复」的气泡被排序顶到列表上方——抬到当前最新消息之后。
    int? seedTs;
    if (reusable != null) {
      var maxOther = 0;
      for (final m in messages) {
        if (m.id == reusable.id) continue;
        if (m.timestampMs > maxOther) maxOther = m.timestampMs;
      }
      if (reusable.timestampMs <= maxOther) seedTs = maxOther + 1;
    }
    var seeded = reusable != null
        ? ChatStreamingText.withUpdatedContent(
            reusable,
            streaming.content,
            timestampMs: seedTs,
          )
        : ChatStreamingText.withUpdatedContent(
            ChatStreamingText.placeholder(
              id: hostId,
              from: MessageFrom(
                id: activeTask.agentId,
                type: 'agent',
                name: activeTask.agentName,
              ),
              to: MessageFrom(
                id: activeTask.userId,
                type: 'user',
                name: activeTask.userName,
              ),
              timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
            ),
            streaming.content,
          );
    final liveMeta = activeTask.metadata;
    if (liveMeta != null && liveMeta.isNotEmpty) {
      seeded = ChatStreamingText.withMergedMetadata(seeded, liveMeta);
    }

    isProcessing = true;
    if (reusable != null) {
      final idx = messages.indexWhere((m) => m.id == reusable.id);
      if (idx >= 0) {
        messages[idx] = seeded;
      } else {
        messages.add(seeded);
      }
    } else {
      messages.add(seeded);
    }
    messageIdMap[seeded.id] = seeded;
    _notify();
    _emit(RequestScrollToBottomEvent(force: !isUserScrolledUp));

    acpCancellationToken = ACPCancellationToken();

    chatService.attachTaskUI(
      currentChannelId!,
      onStreamChunk: (chunk) {
        streaming.append(chunk);
        streaming.applyContentTo(messages, messageIdMap);
        scheduleStreamingRebuild();
      },
      onActionConfirmation: _handleStreamingActionConfirmation,
      onMessageMetadata: (metadata) {
        streaming.applyMetadataTo(messages, messageIdMap, metadata);
        scheduleStreamingRebuild();
      },
      // 主机 `agent_done` 帧的兜底：终态清理由 SessionRuntimeMirror 的
      // running→idle 跃迁主导（见 _onSessionRuntimeChanged），这里保证落库
      // 刷新和本地队列排空仍会发生。两条路径都只由主机帧触发，App 不猜终态。
      onTaskFinished: () async {
        await activeTask.waitForSave();
        acpCancellationToken = null;
        streaming.clear();
        isProcessing = false;
        await loadMessages();
        _notify();
      },
    );
  }

  @override
  void reattachToGroupActiveTasks() {
    if (currentChannelId == null) return;

    final activeTasks = chatService.getActiveGroupTasks(currentChannelId!);
    if (activeTasks.isEmpty) return;

    groupTurn.clear();
    final turn = groupTurn;

    for (final entry in activeTasks.entries) {
      final aid = entry.key;
      final task = entry.value;
      final host = ChatStreamingText.findStreamingHost(
        messages,
        fromId: aid,
        group: true,
      );
      final sid = host?.id ??
          (task.partialMessageId != null &&
                  messageIdMap.containsKey(task.partialMessageId)
              ? task.partialMessageId!
              : GroupInteractionPlanner.groupStreamingId(aid));
      turn.begin(aid, sid, initialContent: task.accumulatedContent);

      isProcessing = true;
      respondingAgentNames.add(task.agentName);
      groupStreamingMessageIds.add(sid);

      if (host != null || messageIdMap.containsKey(sid)) {
        ChatGroupStreamingTracker.applyContentById(
          sid,
          task.accumulatedContent.isNotEmpty
              ? task.accumulatedContent
              : (messageIdMap[sid]?.content ?? ''),
          messages,
          messageIdMap,
        );
        continue;
      }

      final streamingMessage = ChatStreamingText.withUpdatedContent(
        ChatStreamingText.placeholder(
          id: sid,
          from: MessageFrom(id: aid, type: 'agent', name: task.agentName),
          timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
        ),
        task.accumulatedContent,
      );
      messages.add(streamingMessage);
      messageIdMap[streamingMessage.id] = streamingMessage;
    }
    _notify();
    _emit(RequestScrollToBottomEvent(force: !isUserScrolledUp));

    chatService.attachGroupTaskUI(
      currentChannelId!,
      onStreamChunk: (aid, agentNameVal, chunk) {
        if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
          return;
        }
        scheduleStreamingRebuild();
      },
      onMessageMetadata: (aid, agentNameVal, metadata) {
        if (turn.applyMetadata(aid, metadata, messages, messageIdMap) == null) {
          return;
        }
        scheduleStreamingRebuild();
      },
      onTaskFinished: (aid, agentNameVal) {
        final sid = turn.finish(aid);
        if (sid != null) groupStreamingMessageIds.remove(sid);
        respondingAgentNames.remove(agentNameVal);
        _notify();

        if (turn.isEmpty) {
          reconcileGroupMessages().then((_) {
            final cid = currentChannelId;
            if (cid != null && chatService.isGroupChannelOrchestrating(cid)) {
              // This member finished; the group loop is still dispatching.
              _syncGroupStreamingHostsFromActiveTasks();
              return;
            }
            isProcessing = false;
            respondingAgentNames.clear();
            groupStreamingMessageIds.clear();
            _notify();
          });
        }
      },
    );
  }

  /// After mid-turn reconcile (or CLI approval), create hosts for group
  /// members that started while the UI was parked on the previous bubble.
  @override
  void _syncGroupStreamingHostsFromActiveTasks() {
    if (!isGroupMode || currentChannelId == null) return;
    final activeTasks = chatService.getActiveGroupTasks(currentChannelId!);
    if (activeTasks.isEmpty) return;

    var added = false;
    for (final entry in activeTasks.entries) {
      final aid = entry.key;
      final task = entry.value;
      final existingSid = groupTurn.idFor(aid);
      if (existingSid != null && messageIdMap.containsKey(existingSid)) {
        continue;
      }
      final host = ChatStreamingText.findStreamingHost(
        messages,
        fromId: aid,
        group: true,
      );
      final sid = host?.id ??
          (task.partialMessageId != null &&
                  messageIdMap.containsKey(task.partialMessageId)
              ? task.partialMessageId!
              : GroupInteractionPlanner.groupStreamingId(aid));
      groupTurn.begin(aid, sid, initialContent: task.accumulatedContent);
      groupStreamingMessageIds.add(sid);
      respondingAgentNames.add(task.agentName);
      if (host == null && !messageIdMap.containsKey(sid)) {
        final streamingMessage = ChatStreamingText.withUpdatedContent(
          ChatStreamingText.placeholder(
            id: sid,
            from: MessageFrom(id: aid, type: 'agent', name: task.agentName),
            timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
          ),
          task.accumulatedContent,
        );
        messages.add(streamingMessage);
        messageIdMap[streamingMessage.id] = streamingMessage;
        added = true;
      }
    }

    // Original send callbacks are gone (isProcessing already false) but
    // ChatService is still orchestrating — bind live chunk hooks.
    if (!isProcessing) {
      isProcessing = true;
      reattachToGroupActiveTasks();
      return;
    }
    if (added) {
      _notify();
      _emit(RequestScrollToBottomEvent(force: !isUserScrolledUp));
    }
  }

  /// Re-emit a GroupInteractionRequestEvent for any pending plan_approval
  /// that survived a channel switch. Called from loadMessages() so the UI
  /// can re-render the approve/reject card after navigating back.
  @override
  void _reattachPendingPlanApproval() {
    if (currentChannelId == null) return;
    final pendingApproval =
        chatService.getPendingPlanApproval(currentChannelId!);
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

  /// 用户回答了一张已经转入回合外等待的提问。
  ///
  /// 旧回合已经结束，主机不会把答案送回那个工具调用；用正常的发送路径开
  /// 新的一轮，流式、排队、落库和停止按钮全部复用。
  @override
  Future<void> sendDeferredFormFollowUp(
    String content, {
    String? instructionName,
  }) =>
      sendMessage(
        content: content,
        pendingAttachments: <PendingAttachment>[],
        clearMessageController: () {},
        instructionName: instructionName,
      );

  Future<void> sendMessage({
    required String content,
    required List<PendingAttachment> pendingAttachments,
    required VoidCallback clearMessageController,
    String? replyToId,

    /// 引用回复时选中的部分文字（可选）；为空表示引用整条消息。
    String? replyQuoteText,
    List<MentionEntry> mentions = const [],

    /// 指令集预填标记：发送指令时携带指令标题，写入消息 metadata，
    /// 气泡只展示标题、完整内容作为隐式消息投递给 agent。
    String? instructionName,
  }) async {
    if (isViewingGroupBoundMemberSession) {
      _emit(ShowSnackBarEvent('chat_groupBoundInputDisabled'));
      return;
    }

    final hasPendingAttachments = pendingAttachments.isNotEmpty;
    LoggerService().debug('User sending message', tag: 'ChatController');

    final early = ChatSendPlanner.decide(
      content: content,
      hasAttachments: hasPendingAttachments,
      isGroupMode: isGroupMode,
      hasAgent: agentId != null,
    );
    if (early == ChatSendDisposition.empty) return;
    if (early == ChatSendDisposition.noAgent) {
      _emit(ShowSnackBarEvent('chat_noAgentSelected'));
      return;
    }

    if (_composerSendLocked) return;
    _composerSendLocked = true;
    late final List<PendingAttachment> attachmentsToSend;
    try {
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

      attachmentsToSend = List<PendingAttachment>.from(pendingAttachments);
      pendingAttachments.clear();
      clearMessageController();
    } finally {
      _composerSendLocked = false;
    }

    // Capture reply state
    final capturedReplyToId = replyToId ?? replyingToMessage?.id;
    final capturedReplyQuoteText = replyQuoteText ?? this.replyQuoteText;
    cancelReply();

    // Save all pending attachments and build AttachmentData list
    final persisted = await attachmentCoordinator.persistPending(
      pending: attachmentsToSend,
      channelId: currentChannelId ?? '',
      userId: getUserId(),
      userName: getUserName(),
      agentId: agentId ?? '',
      channelType: isGroupMode ? 'group' : null,
      parentGroupId: isGroupMode
          ? (groupChannel?.groupFamilyId ?? currentChannelId)
          : null,
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

    // 「这条立刻发还是排队」由主机 SessionRuntime 裁决，App 一律把消息交出去。
    // 旧代码用本地 isProcessing + 静默秒数猜上一轮有没有结束，正是气泡提前
    // 停下、新消息又被主机判成排队的根源。
    var disposition = ChatSendPlanner.decide(
      content: content,
      hasAttachments: hasAttachments,
      isGroupMode: isGroupMode,
      hasAgent: agentId != null,
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
        // 防御性分支：主机是唯一裁决者，正常路径不该再命中这里。真到了也
        // 一律直接交出去，绝不往本机塞第二份待发列表。
        if (hasAttachments && !isGroupMode) {
          for (final msg in savedAttachmentMessages) {
            await sendAttachmentToAgent(msg);
          }
        }
        await processMessage(
          content,
          replyToId: capturedReplyToId,
          replyQuoteText: capturedReplyQuoteText,
          attachments: hasAttachments ? attachmentDataList : null,
          attachmentMessages: hasAttachments ? savedAttachmentMessages : null,
          instructionName: instructionName,
        );
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
          replyQuoteText: capturedReplyQuoteText,
          attachments: hasAttachments ? attachmentDataList : null,
          mentions: mentions,
          instructionName: instructionName,
        );
        return;
      case ChatSendDisposition.sendDm:
        await processMessage(
          content,
          replyToId: capturedReplyToId,
          replyQuoteText: capturedReplyQuoteText,
          attachments: hasAttachments ? attachmentDataList : null,
          attachmentMessages: hasAttachments ? savedAttachmentMessages : null,
          instructionName: instructionName,
        );
        return;
    }
  }

  /// Stop only the current message being streamed, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentMessageOnly() {
    LoggerService().debug('Stopping current message only (queue preserved)',
        tag: 'ChatController');

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

    if (currentChannelId != null) {
      unawaited(chatService.cancelActiveDmTask(
        currentChannelId!,
        contentOverride: streamingContent.isNotEmpty ? streamingContent : null,
        sessionKey: sessionRuntimeKey,
        runtimeTurnId: currentChannelRuntimeTurnId,
      ));
    }

    acpCancellationToken?.cancel();
    // 不碰主机队列：后续排队消息由 SessionRuntime 自己出队。
    isProcessing = false;
    _notify();
  }

  /// 群聊：只停止 [messageId] 对应单个 agent 的流式回合，其他 agent 继续。
  /// 队列决策推迟到最后一条在途消息结束：停止的恰是最后一条 → 倒回输入框；
  /// 否则队列不动，剩余 agent 自然结束后由既有路径排空。
  void stopGroupAgentMessage(String messageId) {
    if (!groupStreamingMessageIds.contains(messageId)) return;

    final existing = messageIdMap[messageId];
    if (existing == null) return;

    // 工作流流式气泡：停单步 = 终止整个工作流，沿用既有排空语义
    // （_onWorkflowExecutionFinished 会清空剩余流式状态并排空队列）。
    if (_workflowStreamingIds.containsValue(messageId)) {
      final idx = messages.indexOf(existing);
      if (idx != -1) {
        final updated = ChatStreamingText.markMessageStopped(messages[idx]);
        messages[idx] = updated;
        messageIdMap[updated.id] = updated;
      }
      groupStreamingMessageIds.remove(messageId);
      respondingAgentNames.remove(existing.from.name);
      unawaited(cancelRunningWorkflow());
      _notify();
      return;
    }

    // —— 普通群 agent 回合：只停这一个 agent ——
    final agentId = existing.from.id;
    final idx = messages.indexOf(existing);
    if (idx != -1) {
      final updated = ChatStreamingText.markMessageStopped(messages[idx]);
      messages[idx] = updated;
      messageIdMap[updated.id] = updated;
    }
    groupStreamingMessageIds.remove(messageId);
    respondingAgentNames.remove(existing.from.name);

    // 完成该 agent 挂起的交互 Completer，避免取消后悬空。
    for (final key in pendingGroupInteractions.keys.toList()) {
      final e = pendingGroupInteractions[key]!;
      if (e.agentId == agentId && !e.result.isCompleted) {
        e.result.complete(null);
        pendingGroupInteractions.remove(key);
      }
    }

    // 只取消这一个 agent 的底层传输，不碰共享 token（否则会停掉全体）。
    final channelId = currentChannelId;
    if (channelId != null) {
      chatService.cancelGroupAgentTask(channelId, agentId);
    }

    // 队列决策：若已无任何在途消息（含尚未 start 流式的任务），说明停掉的
    // 正是最后一条 → 倒回输入框；否则队列不动，等剩余 agent 自然结束排空。
    final hasOtherInFlight = channelId != null &&
        chatService.getActiveGroupTasks(channelId).isNotEmpty;
    final wasLast = groupStreamingMessageIds.isEmpty && !hasOtherInFlight;
    if (wasLast) {
      _restoreQueueToComposer();
      isProcessing = false;
    }
    _notify();
  }

  void stopStreaming() {
    LoggerService().debug('Stopping streaming', tag: 'ChatController');
    // Defensive: UI routes this to DM mode today, but cancelling the shared
    // token without superseding the group epoch would revive the overlap bug.
    groupTurnGate.invalidate();

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

    if (currentChannelId != null) {
      unawaited(chatService.cancelActiveDmTask(
        currentChannelId!,
        contentOverride: streamingContent.isNotEmpty ? streamingContent : null,
        sessionKey: sessionRuntimeKey,
        runtimeTurnId: currentChannelRuntimeTurnId,
      ));
    }

    acpCancellationToken?.cancel();
    _cancelCliApprovalsForCurrentChannel();

    // 手动停止：把队列内容倒回输入框，由用户决定是否重发（队列清空）。
    // 队列为空时 _restoreQueueToComposer 直接返回，不影响输入框。
    _restoreQueueToComposer();
    isProcessing = false;
    _notify();
  }

  void stopGroupStreaming() {
    LoggerService().debug('Stopping group streaming', tag: 'ChatController');
    groupTurnGate.invalidate();

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

    // If a workflow is executing for this channel, cancel its execution loop
    // too — otherwise the workflow keeps running (and keeps auto-denying
    // pending approvals on timeout) after the user pressed stop.
    if (activeWorkflowId != null) {
      unawaited(cancelRunningWorkflow());
    }

    // Force-complete all group tasks in ChatService so typing indicators
    // are cleared and reattach won't resume cancelled tasks.
    if (currentChannelId != null) {
      chatService.cancelActiveGroupTasks(currentChannelId!);
    }

    // Cancel any pending plan_approval so the orchestration loop terminates.
    if (currentChannelId != null) {
      chatService.cancelPlanApproval(currentChannelId!);
    }
    _cancelCliApprovalsForCurrentChannel();

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
    groupTurn.clear();
    // 手动停止：把队列内容倒回输入框，由用户决定是否重发（队列清空）。
    _restoreQueueToComposer();
    isProcessing = false;
    _notify();
  }

  // 「正文停了一会儿、没有工具、没有审批」曾经被用来强行结束在途回合、
  // 放行下一条。现在回合终态只由主机宣布，这几个本地猜测已全部删除：
  // App 不再有权 `_finishPending`。

  // 本地入队 / 主机托管排队已删除：消息一律直接发出，由主机
  // SessionRuntime 裁决 started / queued；ChatQueuePanel 只镜像 mirror.queue。

  // 本地排空循环（processNextInQueue）已删除：队列由主机 SessionRuntime
  // 自己出队，App 不再从本地列表逐条派发。

  /// 流式占位贴在对应的用户消息后面，再按时间稳定排序。
  void _placeStreamingBubble(Message user, Message streaming) {
    DmSendTurnPlanner.placeStreamingAfterUser(
      messages: messages,
      user: user,
      streaming: streaming,
    );
    messageIdMap[streaming.id] = streaming;
    sortMessagesByTime(messages);
  }

  // ---------------------------------------------------------------------------
  // Process DM message
  // ---------------------------------------------------------------------------

  @override
  Future<void> processMessage(String content,
      {String? replyToId,
      String? replyQuoteText,
      List<AttachmentData>? attachments,
      List<Message>? attachmentMessages,
      String? instructionName,
      bool? deferredTurn}) async {
    final userId = getUserId();
    final userName = getUserName();
    // 排队回合可能几分钟后才开跑，期间用户会切会话；激活 ActiveTask 必须用
    // 发送时的频道，不能用当时的 currentChannelId。
    final sendChannelId = currentChannelId;

    // 「上一轮还在跑」不再拦截发送：主机 SessionRuntime 会把这条排进队列。
    // 这里只决定本机 UI 何时接管 —— 排队回合共用的 streaming / isProcessing /
    // ActiveTask 仍属于上一轮，不能现在就抢过来。
    // 主机事后回 queued 时要改成「先别占流式 UI」，所以不是 final。
    var deferUi = deferredTurn ??
        ChatSendPlanner.deferTurnUi(
          hostRunning: sessionState?.value.isRunning ?? false,
          localProcessing: isProcessing,
          localStreaming: streaming.isActive,
          hasInflightTurn: PeerAgentClientService.instance
              .hasInflightForChannel(currentChannelId ?? ''),
        );
    // 每条回合自带取消令牌，排队期间不覆盖正在跑那一轮的 token。
    final turnToken = ACPCancellationToken();
    var myEpoch = deferUi ? 0 : ++_dmTurnEpoch;
    // 排队回合是否已经接管 UI。声明在 try 外，finally 才能判断共用状态
    // 是不是我们的；没接管就一个字段都不能碰。
    var uiActivated = false;
    if (!deferUi) {
      isProcessing = true;
      acpCancellationToken = turnToken;
    }
    _notify();

    lastUserQuestion = content;

    // Set to true when the agent supports async-confirmation: the task lives
    // on past this method's return, and the finally block must NOT clear
    // `streamingMessageId` / `isProcessing` — those belong to the task's
    // onTaskFinished callback, which fires later when task.completed arrives.
    bool awaitingAsyncTask = false;
    // 发送失败标记：失败时保留 backlog 并暂停自动排空（由用户手动恢复），
    // 避免一条失败后级联自动发送下一条。排队回合在未开跑前失败也不能碰
    // 上一轮的共用状态（见 finally 里的 ownsTurnUi）。
    bool sendFailed = false;

    try {
      final remoteAgent =
          await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = remoteAgent.isLocal;

      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      // 旧的「本会话有在途回合 → 弹『上一轮回复仍在继续』并 return」已删除。
      // 主机是唯一裁决者：忙时它按 request_id 入队并回 session_ack{queued}，
      // 出队后仍用原 request_id 推 chunk。App 只需要为排队回合延迟接管 UI。

      // 注意：不再在此做前置的 checkAgentHealth 探测。
      // AgentMessagingService 内部在建连阶段已带 3 次指数退避重试 +
      // checkAgentHealth 兜底，并通过 onReconnecting 回调把进度推给 UI。
      // 移除这里可以避免"一次失败就抛出"的体验，并减少一次冗余 ping。

      final optimistic = DmSendTurnPlanner.buildOptimisticPair(
        content: content,
        userId: userId,
        userName: userName,
        agentId: remoteAgent.id,
        agentName: remoteAgent.name,
        userMessageId: localUserMessageIdFor(remoteAgent, const Uuid().v4()),
        replyToId: replyToId,
        replyQuoteText: replyQuoteText,
        instructionName: instructionName,
      );
      // 先落用户气泡，流式占位紧跟在它后面。排队回合先不建占位，
      // 免得和上一轮抢同一份 streaming / isProcessing / ActiveTask，
      // 也免得空的「...」和排队条同时出现。
      messages.add(optimistic.user);
      messageIdMap[optimistic.user.id] = optimistic.user;
      if (!deferUi) {
        streaming.begin(optimistic.streaming.id, fromId: remoteAgent.id);
        _placeStreamingBubble(optimistic.user, optimistic.streaming);
      }

      /// 返回 true 表示本回合的帧可以写进当前频道共用的 streaming / 气泡 /
      /// token。排队回合可能几分钟后才开跑，期间用户切到了别的会话；这时
      /// `messages` / `streaming` / `isProcessing` / `acpCancellationToken`
      /// 全都属于新频道，绝不能把旧频道的占位、spinner 和取消令牌塞进去
      ///（停止按钮会因此停掉另一个频道的回合）。只跳过 UI 接管、不置
      /// `uiActivated`：用户切回原频道后下一帧仍会正常激活。
      bool activateTurnUi() {
        if (!deferUi) return true;
        if (currentChannelId != sendChannelId) return false;
        if (uiActivated) return true;
        uiActivated = true;
        myEpoch = ++_dmTurnEpoch;
        if (!messageIdMap.containsKey(optimistic.streaming.id)) {
          _placeStreamingBubble(optimistic.user, optimistic.streaming);
        }
        streaming.begin(optimistic.streaming.id, fromId: remoteAgent.id);
        isProcessing = true;
        acpCancellationToken = turnToken;
        if (sendChannelId != null && sendChannelId.isNotEmpty) {
          chatService.activateDeferredDmTask(
            sendChannelId,
            userMessageId: optimistic.user.id,
          );
        }
        _notify();
        // 排队期间用户可能已经上翻阅读历史；出队别强行把视图拽到底部。
        _emit(RequestScrollToBottomEvent(force: !isUserScrolledUp));
        return true;
      }

      // Resume live follow before the async scroll event is delivered — a
      // sticky scrolled-up flag from a prior turn would otherwise suppress
      // streaming rebuilds and follow-scrolls for this turn.
      isUserScrolledUp = false;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));

      if (currentChannelId != null &&
          !remoteAgent.isPeerAgent &&
          !relaysHostSheTurn(remoteAgent)) {
        final currentMessages = await chatService.loadChannelMessages(
          currentChannelId!,
          limit: 40,
        );
        historySentCount =
            currentMessages.where((m) => m.type == MessageType.text).length;
      }

      final agentResponse = await chatService.sendMessageToAgent(
        content: content,
        agent: remoteAgent,
        userId: userId,
        userName: userName,
        channelId: currentChannelId,
        userMessageId: optimistic.user.id,
        replyToId: replyToId,
        replyQuoteText: replyQuoteText,
        dmSystemPrompt: dmSystemPrompt,
        acpCancellationToken: turnToken,
        attachments: attachments,
        instructionName: instructionName,
        deferredTurn: deferUi,
        onHostQueued: () {
          // 本机以为能马上开跑，主机却收进了队列：撤掉空的「...」，
          // 停止按钮交还给上一轮。真正开跑时 activateTurnUi 再把占位
          // 插回这条用户消息后面。已经写出正文的不撤，避免迟到的
          // queued 把正在输出的回合清掉。
          if (deferUi) return;
          final removed = DmSendTurnPlanner.dropEmptyStreamingPlaceholder(
            messages: messages,
            streamingId: optimistic.streaming.id,
          );
          if (!removed) return;
          deferUi = true;
          messageIdMap.remove(optimistic.streaming.id);
          if (streaming.messageId == optimistic.streaming.id) {
            streaming.clear();
          }
          if (identical(acpCancellationToken, turnToken)) {
            acpCancellationToken = null;
          }
          isProcessing = false;
          uiActivated = false;
          _notify();
        },
        onReconnecting: (attempt, total) {
          if (attempt == 0) {
            _emit(HideReconnectingSnackBarEvent());
          } else {
            _emit(ShowReconnectingSnackBarEvent(attempt, total));
          }
        },
        onOsToolConfirmation: requestCliApproval,
        onStreamChunk: (chunk) {
          if (!activateTurnUi()) return;
          streaming.append(chunk);
          streaming.applyContentTo(messages, messageIdMap);
          scheduleStreamingRebuild();
        },
        onActionConfirmation: (actionData) {
          if (!activateTurnUi()) return;
          _handleStreamingActionConfirmation(actionData);
        },
        onSingleSelect: (selectData) {
          if (!activateTurnUi()) return;
          _updateStreamingMetadata(
              {'single_select': Map<String, dynamic>.from(selectData)});
        },
        onMultiSelect: (selectData) {
          if (!activateTurnUi()) return;
          _updateStreamingMetadata(
              {'multi_select': Map<String, dynamic>.from(selectData)});
        },
        onFileUpload: (uploadData) {
          if (!activateTurnUi()) return;
          _updateStreamingMetadata(
              {'file_upload': Map<String, dynamic>.from(uploadData)});
        },
        onForm: (formData) {
          if (!activateTurnUi()) return;
          _showPeerFormCard(formData);
        },
        onFileMessage: (fileData) async {
          if (!activateTurnUi()) return;
          await _handleFileMessage(fileData);
        },
        onMessageMetadata: (metadata) {
          if (!activateTurnUi()) return;
          streaming.applyMetadataTo(messages, messageIdMap, metadata);
          scheduleStreamingRebuild();
        },
        onWorkflowPlanCreated: (workflowId, planData) {
          if (!activateTurnUi()) return;
          _handleDmWorkflowPlanCreated(workflowId, planData);
        },
        onRequestHistory: (historyData) {
          pendingHistoryRequest = Map<String, dynamic>.from(historyData);
        },
      );

      final handledHistorySupplement = await _handleHistorySupplementIfNeeded(
        remoteAgent: remoteAgent,
        userId: userId,
        userName: userName,
        agentResponse: agentResponse,
      );

      final turn = DmSendTurnPlanner.afterAgentSend(
        // 异步确认（async_confirmation）是 ACP 独有的能力，peer 侧没有，
        // 主机也未实现 —— 随 ACP 一起退役，恒为 false。
        supportsAsyncConfirmation: false,
        hasChannel: currentChannelId != null,
        hasActiveTask: awaitingAsyncTask,
        handledHistorySupplement: handledHistorySupplement,
        agentResponseIsNull: agentResponse == null,
      );
      // awaitingAsyncTask already set when hooking ActiveTask; keep in sync.
      awaitingAsyncTask = turn.awaitingAsyncTask || awaitingAsyncTask;

      if (turn.showNullResponseError) {
        _emit(ShowSnackBarEvent('chat_responseError:${remoteAgent.name}'));
      }

      isAgentOnline = true;
      _notify();
      // In async mode, skip loadMessages() here — the DB save happens later
      // (in onTaskCompleted), so reloading now would overwrite the in-memory
      // streaming content with a stale DB snapshot. The onTaskFinished
      // callback does its own loadMessages() when the task actually ends.
      if (turn.loadMessagesNow) {
        await loadMessages();
      }
    } catch (e, stackTrace) {
      LoggerService().error('Send message failed',
          tag: 'ChatController', error: e, stackTrace: stackTrace);
      await loadMessages();
      final err = e.toString();
      // 发送失败：把当前失败消息（含附件）+ 队列剩余消息倒回输入框
      //（队列清空），供用户重新编辑后手动重发。
      sendFailed = true;
      _restoreQueueToComposer(
        failedContent: content,
        failedAttachments: attachments,
      );
      if (err.contains('not reachable after')) {
        _emit(ShowErrorSnackBarEvent('chat_reconnectFailed'));
      } else {
        _emit(ShowErrorSnackBarEvent('$e'));
      }
    } finally {
      // 排队回合没等到自己开跑就收尾（如主机队列已满 / 发送失败）时，共用
      // 的 streaming / isProcessing / token 仍属于上一轮，这里一个都不能碰。
      final ownsTurnUi =
          (!deferUi || uiActivated) && myEpoch == _dmTurnEpoch;
      // 已经换回合时别把新回合的 token 一起清掉。
      void clearOwnedToken() {
        if (identical(acpCancellationToken, turnToken)) {
          acpCancellationToken = null;
        }
      }

      if (sendFailed) {
        if (awaitingAsyncTask) {
          // 异步确认路径：task 仍在后台跑，流式状态交给 onTaskFinished 清理，
          // 这里只暂停队列排空（避免级联）。
          _notify();
        } else if (ownsTurnUi) {
          // 失败路径：清理当前回合状态，但不碰主机队列，避免级联自动发送。
          clearOwnedToken();
          streaming.clear();
          pendingHistoryRequest = null;
          isProcessing = false;
          _notify();
        }
      } else if (awaitingAsyncTask) {
        // 异步确认路径：本轮任务仍在后台跑，isProcessing / 流式状态交给
        // activeTask.onTaskFinished 清理——回合真正结束时它负责置
        // isProcessing=false；后续排队消息由主机自己出队，App 不并发派发。
      } else if (ownsTurnUi) {
        clearOwnedToken();
        streaming.clear();
        pendingHistoryRequest = null;
        isProcessing = false;
        _notify();
      }
    }
  }

  /// Run the optional history-supplement / re-answer loop after a DM send.
  /// Returns true when a supplement path was entered (approved by the user).
  Future<bool> _handleHistorySupplementIfNeeded({
    required RemoteAgent remoteAgent,
    required String userId,
    required String userName,
    required Message? agentResponse,
  }) async {
    if (pendingHistoryRequest == null) return false;

    final historyData = pendingHistoryRequest!;
    pendingHistoryRequest = null;
    final request = HistoryRequestInfo.fromMap(historyData);

    if (agentResponse != null) {
      try {
        await chatService.deleteMessage(agentResponse.id);
      } catch (_) {}
    }

    // Reason is already shown in the approval dialog — do not also insert a
    // duplicate system message into the chat the user is currently viewing.
    final dialogEvent = ShowHistoryRequestDialogEvent(request.reason);
    _emit(dialogEvent);
    final approved = await dialogEvent.result.future;
    if (!approved) {
      return false;
    }

    streaming.begin(
      'streaming_reanswer_${DateTime.now().millisecondsSinceEpoch}',
      fromId: remoteAgent.id,
    );
    acpCancellationToken = ACPCancellationToken();

    final reanswer = ChatStreamingText.placeholder(
      id: streaming.messageId!,
      from: MessageFrom(
          id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
    );
    messages.add(reanswer);
    messageIdMap[reanswer.id] = reanswer;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    var currentRequestedCount = request.requestedCount;
    try {
      for (var round = 0;
          round < DmSendTurnPlanner.maxHistorySupplementRounds;
          round++) {
        final supplementResult = await chatService.sendHistorySupplement(
          agent: remoteAgent,
          sessionId: currentChannelId!,
          requestId: request.requestId,
          originalQuestion: lastUserQuestion ?? '',
          offset: historySentCount,
          batchSize: currentRequestedCount,
          onStreamChunk: (chunk) {
            streaming.append(chunk);
            streaming.applyContentTo(messages, messageIdMap);
            scheduleStreamingRebuild();
          },
          acpCancellationToken: acpCancellationToken,
        );

        final decision = DmSendTurnPlanner.evaluateSupplementRound(
          supplementIsNull: supplementResult == null,
          actualSentCount: supplementResult?.actualSentCount ?? 0,
          messageContent: supplementResult?.message.content ?? '',
          pendingHistoryRequest: supplementResult?.pendingHistoryRequest,
        );

        switch (decision.action) {
          case HistorySupplementRoundAction.noMoreHistory:
            addSystemHint('No more history records available');
            messages.removeWhere((m) => m.id == streamingMessageId);
            messageIdMap.remove(streamingMessageId);
            _notify();
            return true;
          case HistorySupplementRoundAction.needMoreHistory:
            historySentCount += decision.actualSentCount;
            if (decision.deleteEmptySupplementMessage &&
                supplementResult != null) {
              try {
                await chatService.deleteMessage(supplementResult.message.id);
              } catch (_) {}
            }
            // Already approved once; continue quietly without more system spam.
            streamingContent = '';
            acpCancellationToken = ACPCancellationToken();
            currentRequestedCount =
                decision.nextRequestedCount ?? currentRequestedCount;
            continue;
          case HistorySupplementRoundAction.reanswerReady:
            historySentCount += decision.actualSentCount;
            return true;
        }
      }
    } catch (e) {
      messages.removeWhere((m) => m.id == streamingMessageId);
      messageIdMap.remove(streamingMessageId);
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_historyLoadFailed:$e'));
    }
    return true;
  }

  @override
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
    // 路由字段不进卡片数据，但归属本身要落到消息顶层：孤儿 / 补投卡在
    // submitApproval 时靠它带 channel_id，轮询靠它对齐会话与主机。
    final cardChannel = (actionData['card_channel_id'] ??
            actionData['channel_id'])
        ?.toString()
        .trim() ??
        '';
    final cardPeer = (actionData['card_peer_id'] ?? actionData['peer_id'])
            ?.toString()
            .trim() ??
        '';
    final routing = <String, dynamic>{
      if (cardChannel.isNotEmpty) 'card_channel_id': cardChannel,
      if (cardPeer.isNotEmpty) 'card_peer_id': cardPeer,
    };
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
      // 孤儿卡用 `approval_id` 派生确定性 id：补投 / 重开页面落到同一行，
      // 不会每打开一次就多一张一样的卡。
      final sid = actionData['orphan'] == true && confirmationId.isNotEmpty
          ? PeerApprovalPayload.approvalCardMessageId(confirmationId)
          : StreamingActionConfirmation.dmFallbackId(agentId!);
      if (messages.any((m) => m.id == sid)) {
        return;
      }
      final sm = StreamingActionConfirmation.buildFallbackBubble(
        id: sid,
        agentId: agentId!,
        agentName: displayName,
        userId: userId,
        userName: userName,
        actionData: actionData,
      );
      // 会话归属落在消息顶层（和表单卡一致）：重启后仍能校验这张审批卡
      // 是不是本会话的卡，有效性轮询也靠它对齐。
      final cardMessage = routing.isEmpty
          ? sm
          : ChatStreamingText.withMergedMetadata(sm, routing);
      messages.add(cardMessage);
      messageIdMap[sid] = cardMessage;
      streamingMessageId = sid;
      streamingContent = cardMessage.content;
      // Orphan cards (hub restarted mid-approval) have no live turn behind
      // them — showing a spinner would never clear.
      if (actionData['orphan'] != true) {
        isProcessing = true;
      }
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
              content: cardMessage.content,
              messageType: 'text',
              metadata: cardMessage.metadata,
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
    final cardMessage = routing.isEmpty
        ? updated
        : ChatStreamingText.withMergedMetadata(updated, routing);
    messages[idx] = cardMessage;
    messageIdMap[cardMessage.id] = cardMessage;
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
        .updateMessageMetadata(streamingId, cardMessage.metadata ?? {})
        .ignore();
  }

  /// 把表单卡显示成一条独立消息行，**不贴到正在流式的宿主气泡上**。
  ///
  /// 宿主气泡会在回合结束时删除/重建；卡片贴在上面时，重开页面或 reconcile
  /// 又会从 SQLite 载入确定性卡片行，屏幕上就同时出现两张都能提交的表单。
  /// 卡片本身是一条普通消息，回合结束时随流式气泡一起消失的只有回复正文。
  ///
  /// 同一个 `approval_id` 只对应一条行：重复投递（重连补发、跨设备广播）
  /// 更新原行的 metadata，不新增消息。
  void _showPeerFormCard(Map<String, dynamic> formData) {
    final formId = formData['form_id']?.toString() ?? '';
    if (formId.isEmpty) return;
    // 卡片属于别的会话时不进当前列表；服务层已按发起回合的频道落库，
    // 切回那个会话会从 DB 载入。
    // P6：帧里的 `channel_id` 是裸主机会话 id（`flow_<rid8>_she`），本机
    // 打开的却是 `psess_flow_<rid8>_she`。两者是同一条会话，别因为字符串
    // 不相等就把已经打开的工作流会话里的卡丢掉（否则要退出重进才看得见）。
    final frameChannel = formData['channel_id']?.toString().trim() ?? '';
    final current = currentChannelId;
    // 无归属卡不能再进当前列表：多会话并发时「谁打开就归谁」会把同一张卡
    // 挂进任意会话，用户就在错的会话里把它答了。它们只由服务层的固定频道
    // 落库 + 全局横幅呈现。
    final belongsHere = frameChannel.isNotEmpty &&
        (frameChannel == current ||
            (current != null && frameChannel == hostSessionIdForChannel(current)));
    if (!belongsHere) {
      return;
    }
    // 先落库：卡片的重开可见性靠这条确定性行，而不是随时会被 reconcile
    // 掉的流式气泡。重复投递由 id 冲突忽略。
    _persistPeerFormCard(formData);
    final messageId = PeerApprovalPayload.formCardMessageId(formId);
    // 路由字段只用来定位会话；写进消息 metadata 会混进卡片数据里。
    final data = Map<String, dynamic>.from(formData)
      ..remove('peer_id')
      ..remove('remote_agent_id')
      ..remove('channel_id')
      ..remove('orphan');
    final existing = messageIdMap[messageId];
    if (existing != null) {
      // 保留本地已经填好/提交/作废的状态。`{...existing, ...data}` 在
      // `existing is Map` 之后运行时类型是 `Map<dynamic, dynamic>`，
      // 列表里 `as Map<String, dynamic>` 会抛，release 上整段消息区变成灰屏。
      final form = FormFieldShape.mergeCard(existing.metadata?['form'], data);
      // 归属是服务层落库时写进 DB 的，内存气泡里可能没有。整份回写会把这一列
      // 抹掉，reload 之后 dock / 提交校验就都跳过了；这里只 patch form，其它
      // 字段（card_channel_id / card_peer_id / 附件…）留给 merge 语义保留。
      final patch = <String, dynamic>{
        'form': form,
        if (frameChannel.isNotEmpty) 'card_channel_id': frameChannel,
      };
      final updated = ChatStreamingText.withMergedMetadata(existing, patch);
      final idx = messages.indexWhere((m) => m.id == messageId);
      if (idx != -1) messages[idx] = updated;
      messageIdMap[messageId] = updated;
      _notify();
      localDatabaseService.mergeMessageMetadata(messageId, patch).ignore();
      return;
    }
    final aid = agentId;
    final channel = currentChannelId;
    if (aid == null || channel == null) {
      LoggerService().warning(
        'onForm: no agent/channel for formId=$formId — UI not attached',
        tag: 'PeerApproval',
      );
      return;
    }
    final sm = StreamingActionConfirmation.buildFallbackBubble(
      id: messageId,
      agentId: aid,
      agentName: agentName ?? 'Agent',
      userId: getUserId(),
      userName: getUserName(),
      actionData: {...data, 'prompt': data['title'] ?? ''},
      metadataKey: 'form',
    );
    messages.add(sm);
    messageIdMap[messageId] = sm;
    LoggerService().info(
      'onForm: formId=$formId rendered as messageId=$messageId',
      tag: 'PeerApproval',
    );
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));
  }

  /// 把表单卡落成一条确定性 id 的消息行。
  ///
  /// 卡片以前只挂在流式气泡的内存 metadata 上：聊天页重开、控制器重建、
  /// DB reconcile 都会让它消失，而主机还在等回答。落库之后重开页面，
  /// FormBubble 仍能从消息 metadata 里渲染出来并继续提交。
  void _persistPeerFormCard(Map<String, dynamic> formData) {
    // 能走到这里，_showPeerFormCard 已经确认卡属于当前会话。帧里的
    // `channel_id` 可能是裸主机会话 id（`flow_…`），直接拿它当本机频道会写出
    // 一条没有会话行的幽灵消息；一律用本机频道 id。
    final channelId = currentChannelId;
    if (channelId == null) return;
    final senderId = agentId;
    if (senderId == null) return;
    unawaited(PeerAgentClientService.instance.persistFormCard(
      formData: formData,
      channelId: channelId,
      senderId: senderId,
      senderName: agentName ?? '',
    ));
  }

  /// 渲染一张孤儿 AskUserQuestion 表单：hub 在手机重连后补发，但本地已经没有
  /// 活动 turn 能挂 `onForm` 了。和回合内收到的卡走同一条路：落到确定性
  /// 消息行上，FormBubble 和 `handleFormSubmitted` 都不用改 —— 提交只需要
  /// metadata 里的 `form.peer_form`。
  @override
  void _handleStreamingForm(Map<String, dynamic> formData) {
    final formId = formData['form_id'] as String? ?? '';
    LoggerService().info(
      'onForm(orphan): formId=$formId channelId=$currentChannelId',
      tag: 'PeerApproval',
    );
    _showPeerFormCard(formData);
  }

  /// Resolve (or create) the group message bubble that should host an interactive
  /// component. For peer-relayed tool approvals, ensures a visible card even when
  /// the streaming placeholder was already reconciled away.
  @override
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

    if (!GroupInteractionPlanner.needsPeerApprovalFallback(
      preferredSid: preferredSid,
      preferredExists:
          preferredSid != null && messageIdMap.containsKey(preferredSid),
      interactionType: interactionType,
      data: data,
      hasChannel: currentChannelId != null,
    )) {
      return preferredSid;
    }

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

  /// Surface a peer `agent_approval_req` that arrived after group `sendChat`
  /// already completed (orphan). Without this, the card never appears in the
  /// group and the remote agent stays blocked on the hub.
  @override
  void _handleGroupOrphanPeerApproval({
    required String agentId,
    required String agentName,
    required Map<String, dynamic> actionData,
  }) {
    if (currentChannelId == null) return;

    final data = Map<String, dynamic>.from(actionData);
    data['confirmation_context'] ??= 'peer';
    // Strip routing-only fields so message metadata stays card-shaped.
    data.remove('peer_id');
    data.remove('remote_agent_id');
    data.remove('channel_id');

    final confirmationId = data['confirmation_id'] as String? ?? '';
    LoggerService().info(
      'group orphan peer approval: agent=$agentName '
      'confirmationId=$confirmationId channel=$currentChannelId',
      tag: 'PeerApproval',
    );

    // Prefer an existing same-agent bubble (latest), else create fallback host.
    String? preferredSid;
    for (final m in messages.reversed) {
      if (m.from.isAgent && m.from.id == agentId) {
        preferredSid = m.id;
        break;
      }
    }

    final sid = _resolveGroupInteractionMessageId(
      agentId: agentId,
      agentName: agentName,
      interactionType: 'action_confirmation',
      data: data,
      preferredSid: preferredSid,
    );
    if (sid == null) return;

    _updateGroupStreamingMetadata(sid, 'action_confirmation', data);
    localDatabaseService
        .updateMessageMetadata(
          sid,
          GroupInteractionPlanner.metadataForPersist(
            existing: messageIdMap[sid]?.metadata,
            interactionType: 'action_confirmation',
            data: data,
          ),
        )
        .ignore();

    final hubItem = PendingApprovalItem.fromInteraction(
      channelId: currentChannelId!,
      agentId: agentId,
      agentName: agentName,
      interactionType: 'action_confirmation',
      data: data,
      messageId: sid,
    );
    if (hubItem != null) {
      PendingApprovalHub.instance.upsert(hubItem);
    }

    _notify();
    _emit(RequestScrollToBottomEvent(force: true));
  }

  /// 群聊版孤儿表单：卡片属于群里的某个 peer 成员，不属于 `agentId`。
  /// 与 [_handleGroupOrphanPeerApproval] 同构，只是挂到 `form` 键上。
  @override
  void _handleGroupOrphanPeerForm({
    required String agentId,
    required String agentName,
    required Map<String, dynamic> formData,
  }) {
    if (currentChannelId == null) return;

    final data = Map<String, dynamic>.from(formData)
      ..remove('peer_id')
      ..remove('remote_agent_id')
      ..remove('channel_id')
      ..remove('orphan');
    final formId = data['form_id'] as String? ?? '';
    LoggerService().info(
      'group orphan peer form: agent=$agentName formId=$formId '
      'channelId=$currentChannelId',
      tag: 'PeerApproval',
    );

    String? preferredSid;
    for (final m in messages.reversed) {
      if (m.from.isAgent && m.from.id == agentId) {
        preferredSid = m.id;
        break;
      }
    }

    final sid = _resolveGroupInteractionMessageId(
      agentId: agentId,
      agentName: agentName,
      interactionType: 'form',
      data: data,
      preferredSid: preferredSid,
    );
    if (sid == null) return;

    _updateGroupStreamingMetadata(sid, 'form', data);
    localDatabaseService
        .updateMessageMetadata(
          sid,
          GroupInteractionPlanner.metadataForPersist(
            existing: messageIdMap[sid]?.metadata,
            interactionType: 'form',
            data: data,
          ),
        )
        .ignore();

    _notify();
    _emit(RequestScrollToBottomEvent(force: true));
  }

  @override
  void _updateGroupStreamingMetadata(
      String streamingId, String key, Map<String, dynamic> data) {
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
      if (url != null && isPouchUri(url) && (rawSize == null || rawSize == 0)) {
        // Agent 产物只给 pouch:// 引用时，向储物袋取真实大小用于展示。
        try {
          resolvedSize = await StoreUriReader.instance.sizeOf(url);
        } catch (_) {}
      } else if (InboundFileMessageParser.needsLocalSizeProbe(url, rawSize) &&
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

  @override
  Future<void> processGroupMessage(String content,
      {String? replyToId,
      String? replyQuoteText,
      List<AttachmentData>? attachments,
      List<MentionEntry> mentions = const [],
      String? instructionName,
      String? continueOrchestrationId}) async {
    if (currentChannelId == null || groupAgents.isEmpty) {
      LoggerService().debug(
          'processGroupMessage ABORTED: channelId=$currentChannelId, groupAgents=${groupAgents.length}',
          tag: 'ChatController');
      return;
    }
    // 不再因为本地 isProcessing 把消息塞进本机队列：群回合也一律交给主机
    // SessionRuntime 裁决 started / queued，App 不维护第二份待发列表。
    LoggerService().debug(
        'processGroupMessage: channelId=$currentChannelId, agents=${groupAgents.map((a) => a.name).toList()}, adminId=$groupAdminAgentId',
        tag: 'ChatController');

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    acpCancellationToken = ACPCancellationToken();
    final epoch = groupTurnGate.beginTurn();
    _notify();

    final userMessage = GroupInteractionPlanner.buildOptimisticUserMessage(
      content: content,
      userId: userId,
      userName: userName,
      userMessageId: const Uuid().v4(),
      replyToId: replyToId,
      replyQuoteText: replyQuoteText,
      instructionName: instructionName,
    );
    messages.add(userMessage);
    messageIdMap[userMessage.id] = userMessage;
    isUserScrolledUp = false;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    groupTurn.clear();
    final turn = groupTurn;

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final mentionedAgentIds = GroupMentionResolver.resolveAgentIds(
        content: content,
        mentions: mentions,
        agents: [
          for (final a in groupAgents) (id: a.id, name: a.name),
        ],
      );
      var userMsgMetadata =
          GroupInteractionPlanner.userMessageMentionsMetadata(mentions);
      // 指令集消息：合并指令标题到落库 metadata，气泡只展示标题。
      if (instructionName != null && instructionName.isNotEmpty) {
        userMsgMetadata ??= <String, dynamic>{};
        userMsgMetadata['instruction'] = instructionName;
      }
      // 引用回复：选中部分文字随落库 metadata 持久化，气泡引用块优先展示。
      if (replyQuoteText != null && replyQuoteText.isNotEmpty) {
        userMsgMetadata ??= <String, dynamic>{};
        userMsgMetadata['reply_quote'] = replyQuoteText;
      }

      // 投射 chat.message.mention（poll_only，仅记录 + 供显式订阅）。
      // 群聊里 @ 已由编排 / 提及处理直接消费，这里不做 active 唤醒，避免重复回复。
      if (mentionedAgentIds.isNotEmpty) {
        try {
          final snippet =
              content.length > 80 ? content.substring(0, 80) : content;
          for (final mentionedId in mentionedAgentIds) {
            EventBus.instance.emitSystem(
              systemDomain: 'chat',
              type: 'chat.message.mention',
              payload: {
                'summary': '用户在群中 @了你',
                'message_id': userMessage.id,
                'channel_id': currentChannelId,
                'snippet': snippet,
              },
              scope: EventScope(
                channelId: currentChannelId,
                agentId: mentionedId,
              ),
            );
          }
        } catch (_) {
          // 事件系统不可用时不影响发消息
        }
      }

      await chatService.sendMessageToGroup(
        channelId: currentChannelId!,
        content: content,
        userId: userId,
        userName: userName,
        agentIds: agentIds,
        mentionedAgentIds: mentionedAgentIds,
        mentionOnlyMode: mentionOnlyMode,
        adminAgentId: groupAdminAgentId,
        userMessageId: userMessage.id,
        replyToId: replyToId,
        replyQuoteText: replyQuoteText,
        flowMode: groupChannel?.flowMode ?? false,
        acpCancellationToken: acpCancellationToken,
        userMessageMetadata: userMsgMetadata,
        continueOrchestrationId: continueOrchestrationId,
        attachments: attachments,
        onAgentStart: (aid, anm) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          final sid = GroupInteractionPlanner.groupStreamingId(aid);
          turn.begin(aid, sid);
          final sm = GroupInteractionPlanner.buildAgentStreamingPlaceholder(
            sid: sid,
            agentId: aid,
            agentName: anm,
            userId: userId,
            userName: userName,
          );
          respondingAgentNames.add(anm);
          groupStreamingMessageIds.add(sid);
          messages.add(sm);
          messageIdMap[sm.id] = sm;
          _notify();
          _emit(RequestScrollToBottomEvent(force: !isUserScrolledUp));
        },
        onStreamChunk: (aid, anm, chunk) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
            return;
          }
          scheduleStreamingRebuild();
        },
        onMessageMetadata: (aid, anm, metadata) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          // thinking/进度增量：直接合并到该 agent 的群流式气泡 metadata
          // （与 DM 的 applyMetadataTo 同款），折叠块随 thinking 流式展开。
          if (turn.applyMetadata(aid, metadata, messages, messageIdMap) ==
              null) {
            return;
          }
          scheduleStreamingRebuild();
        },
        onAgentDone: (aid, anm, skipped) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          final sid = turn.idFor(aid);
          if (GroupInteractionPlanner.shouldDropSkippedPlaceholder(
            skipped: skipped,
            sid: sid,
          )) {
            messages.removeWhere((m) => m.id == sid);
            messageIdMap.remove(sid);
            groupStreamingMessageIds.remove(sid!);
          } else if (sid != null) {
            groupStreamingMessageIds.remove(sid);
          }
          turn.finish(aid);
          respondingAgentNames.remove(anm);
          _notify();
        },
        onAllDone: () {},
        onActiveWorkflowChanged: (workflowId) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          setActiveWorkflowId(workflowId);
        },
        onInteractionRequest:
            (agentId, agentName, interactionType, data) async {
          if (!groupTurnGate.isCurrent(epoch)) return null;
          return _handleProcessGroupInteractionRequest(
            turn: turn,
            agentId: agentId,
            agentName: agentName,
            interactionType: interactionType,
            data: data,
          );
        },
      );

      if (groupTurnGate.isCurrent(epoch)) {
        await reconcileGroupMessages();
        markMessagesAsReadIfAtBottom();
      }
    } catch (e, stackTrace) {
      LoggerService().error('processGroupMessage error: $e',
          tag: 'ChatController', error: e, stackTrace: stackTrace);
      // 失败后把当前群消息（含附件）+ 队列剩余消息倒回输入框。
      _restoreQueueToComposer(
        failedContent: content,
        failedAttachments: attachments,
      );
      if (groupTurnGate.isCurrent(epoch)) {
        _emit(ShowErrorSnackBarEvent('chat_groupChatError:$e'));
      }
    } finally {
      turn.clear();
      if (groupTurnGate.isCurrent(epoch)) {
        acpCancellationToken = null;
        streaming.clear();
        for (final e in pendingGroupInteractions.values) {
          if (!e.result.isCompleted) e.result.complete(null);
        }
        pendingGroupInteractions.clear();
        isProcessing = false;
        respondingAgentNames.clear();
        groupStreamingMessageIds.clear();
        _notify();
        // 失败时保留 backlog 并暂停自动排空，等待用户手动恢复。
      }
    }
  }

  /// Attach an interactive card during [processGroupMessage] and await (or
  /// immediately complete) the user's response.
  Future<Map<String, dynamic>?> _handleProcessGroupInteractionRequest({
    required ChatGroupStreamingTracker turn,
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
  }) async {
    final hubInteractionRaw = data.remove('_hub_interaction');
    final hubInteraction = hubInteractionRaw is Map
        ? Map<String, dynamic>.from(hubInteractionRaw.cast<String, dynamic>())
        : null;
    final workflowId = GroupInteractionPlanner.workflowIdFromPlanApproval(
      interactionType,
      data,
    );
    if (interactionType == 'workflow_auto_start') {
      if (workflowId != null) _handleWorkflowAutoStart(workflowId);
      return GroupInteractionPlanner.nonBlockingResult();
    }
    if (workflowId != null) setActiveWorkflowId(workflowId);

    var sid = turn.idFor(agentId);
    if (sid == null) {
      await reconcileGroupMessages();
      final savedMsgId = GroupInteractionPlanner.takeSavedMessageId(data);
      sid = GroupInteractionPlanner.resolvePreferredSid(
        streamingSid: null,
        savedMessageId: savedMsgId,
        hasMessage: messageIdMap.containsKey,
      );
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
      if (hubInteraction != null) {
        _updateGroupStreamingMetadata(sid, 'hub_interaction', hubInteraction);
      }
      final persistedMeta = GroupInteractionPlanner.metadataForPersist(
        existing: messageIdMap[sid]?.metadata,
        interactionType: interactionType,
        data: data,
      );
      if (hubInteraction != null) {
        persistedMeta['hub_interaction'] = hubInteraction;
      }
      localDatabaseService.updateMessageMetadata(sid, persistedMeta).ignore();
    }

    final event = GroupInteractionRequestEvent(
      agentId: agentId,
      agentName: agentName,
      interactionType: interactionType,
      data: data,
      groupStreamingMessageId: sid ?? agentId,
    );
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

    if (GroupInteractionPlanner.isNonBlocking(interactionType)) {
      if (!event.result.isCompleted) {
        event.result.complete(GroupInteractionPlanner.nonBlockingResult());
      }
      pendingGroupInteractions.remove(pendingKey);
      _notify();
      return GroupInteractionPlanner.nonBlockingResult();
    }

    try {
      // 审批等待不设超时：用户何时处理审批卡片由用户决定。
      return await event.result.future;
    } finally {
      pendingGroupInteractions.remove(pendingKey);
      _notify();
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
    final attachmentData =
        await attachmentService.buildAttachmentData(attachmentMessage);
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
      final remoteAgent =
          await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = remoteAgent.isLocal;
      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      streaming.begin('streaming_${DateTime.now().millisecondsSinceEpoch}');
      final sm = ChatStreamingText.placeholder(
        id: streaming.messageId!,
        from: MessageFrom(
            id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      );

      messages.add(sm);
      messageIdMap[sm.id] = sm;
      isUserScrolledUp = false;
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
      // 失败后把附件消息文本 + 附件本体 + 队列剩余消息倒回输入框。
      _restoreQueueToComposer(
        failedContent: attachmentMessage.content,
        failedAttachments: [attachmentData],
      );
      _emit(ShowErrorSnackBarEvent('chat_fileMessageFailed:$e'));
    } finally {
      streaming.clear();
      isProcessing = false;
      _notify();
      // 失败时保留 backlog 并暂停自动排空，等待用户手动恢复。
    }
  }

  @override
  void scheduleStreamingRebuild({bool refreshList = false}) {
    if (refreshList) _pendingListRefresh = true;
    if (_pendingStreamingRebuild) return;
    _pendingStreamingRebuild = true;
    // addPostFrameCallback 不会主动请求帧：没有别的产帧源（转圈动画只在
    // showAvatar 为真时渲染、用户上滑后连 follow-scroll 也会被跳过）时，
    // 通知会一直滞留，攒到回合末 _notify() 才一次性刷出。这里显式请求帧。
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStreamingRebuild = false;
      // dispose 竞态：已销毁的 listenable 不可再通知。
      if (_contentListenableDisposed) return;
      final refreshListNow = _pendingListRefresh;
      _pendingListRefresh = false;
      // chunk 只通知正在输出的气泡。交互卡 / reconcile 才重建整列。
      streamingListenable.notifyListeners();
      if (refreshListNow) contentListenable.notifyListeners();
    });
  }
}
