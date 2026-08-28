part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Messaging / streaming send path
//
// DM + group send, stop, reattach, and in-band interaction host updates.
// Declared as a mixin so [_ChatControllerBase] can keep abstract hooks that
// workflow / loadMessages call, while the bulky implementations live here.
// ---------------------------------------------------------------------------

mixin _MessagingOps on _ChatControllerBase {
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

    var seeded = reusable != null
        ? ChatStreamingText.withUpdatedContent(
            reusable,
            streaming.content,
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
    // Same sticky-flag race as processMessage — clear before async force-scroll.
    isUserScrolledUp = false;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    acpCancellationToken = ACPCancellationToken();

    chatService.attachTaskUI(
      currentChannelId!,
        onStreamChunk: (chunk) {
        streaming.append(chunk);
        streaming.applyContentTo(messages, messageIdMap);
        scheduleStreamingRebuild();
        scheduleStreamingScrollToBottom();
      },
      onActionConfirmation: _handleStreamingActionConfirmation,
      onMessageMetadata: (metadata) {
        streaming.applyMetadataTo(messages, messageIdMap, metadata);
        scheduleStreamingRebuild();
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

  @override
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
    isUserScrolledUp = false;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    chatService.attachGroupTaskUI(
      currentChannelId!,
      onStreamChunk: (aid, agentNameVal, chunk) {
        if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
          return;
        }
        scheduleStreamingRebuild();
        scheduleStreamingScrollToBottom();
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
  @override
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

    var disposition = ChatSendPlanner.decide(
      content: content,
      hasAttachments: hasAttachments,
      isGroupMode: isGroupMode,
      hasAgent: agentId != null,
      isProcessing: isProcessing,
    );

    // 发送失败后队列处于暂停态（isProcessing=false 但队列非空）：此时手动
    // 再发一条不再直接发送，而是排到队尾并恢复排空，保持 FIFO（队首旧消息
    // 先出，新消息后发）。正常态下队列只在 isProcessing=true 时非空，故该
    // 分支不会误伤正常发送。
    if (!isProcessing && messageQueue.isNotEmpty) {
      if (disposition == ChatSendDisposition.sendDm ||
          disposition == ChatSendDisposition.sendGroup) {
        disposition = ChatSendDisposition.queueText;
      }
    }

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
        messageQueue.add(
          QueuedMessage(
            id: const Uuid().v4(),
            content: content,
            replyToId: capturedReplyToId,
            mentions: mentions,
            // 群聊附件未随 DM 分支立即发送，必须随队列项携带，出队时透传。
            attachments:
                (isGroupMode && hasAttachments) ? attachmentDataList : null,
          ),
        );
        _notify();
        // 失败暂停态恢复：入队后立即排空（正常态 isProcessing=true，由当前
        // 回合的 finally 负责排空，这里不触发）。
        if (!isProcessing) {
          unawaited(processNextInQueue());
        }
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

    if (currentChannelId != null) {
      unawaited(chatService.cancelActiveDmTask(
        currentChannelId!,
        contentOverride:
            streamingContent.isNotEmpty ? streamingContent : null,
      ));
    }

    acpCancellationToken?.cancel();
    // DO NOT clear messageQueue — let processNextInQueue() pick up the next one
    isProcessing = false;
    _notify();
  }

  /// Stop all active group streaming messages, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentGroupMessageOnly() {
    LoggerService().debug('Stopping current group messages only (queue preserved)', tag: 'ChatController');
    // Supersede the running orchestration turn: its abort-summarize keeps
    // running to completion by design, but its callbacks and finally-cleanup
    // must no longer touch the shared state of the next turn.
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
    // too — same contract as stopGroupStreaming.
    if (activeWorkflowId != null) {
      unawaited(cancelRunningWorkflow());
    }

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
        contentOverride:
            streamingContent.isNotEmpty ? streamingContent : null,
      ));
    }

    acpCancellationToken?.cancel();

    // Clear queued messages so they won't be sent after stopping
    messageQueue.clear();
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

  @override
  Future<void> processNextInQueue() async {
    // 页面已离开：不再于已销毁的 Controller 上后台排空——队列保留在
    // ChatService 侧，重进后由 loadMessages 恢复发送（避免死 Controller
    // 与重进的新 Controller 并发出队）。
    if (!isMounted) return;

    final channelId = currentChannelId;
    if (channelId == null) return;
    final queue = chatService.pendingSendQueue(channelId);
    if (queue.isEmpty) return;

    final next = queue.removeAt(0);
    _notify();
    if (isGroupMode) {
      await processGroupMessage(
        next.content,
        replyToId: next.replyToId,
        attachments: next.attachments,
        mentions: next.mentions,
      );
    } else {
      await processMessage(
        next.content,
        replyToId: next.replyToId,
        // DM 附件的附件消息在入队前已随 sendAttachmentToAgent 立即发送，
        // 队列项不携带 attachmentMessages。
        attachments: next.attachments,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Process DM message
  // ---------------------------------------------------------------------------

  @override
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
    // 发送失败标记：失败时保留 backlog 并暂停自动排空（由用户手动恢复），
    // 避免一条失败后级联自动发送下一条。PeerTurnInFlight 不视为失败。
    bool sendFailed = false;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = remoteAgent.isLocal;

      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      if (remoteAgent.isPeerAgent && currentChannelId != null) {
        final liveTask = chatService.getActiveTask(currentChannelId!);
        final hydrated = PeerAgentClientService.instance
            .hasInflightForChannel(currentChannelId!);
        if ((liveTask != null && !liveTask.isComplete) || hydrated) {
          reattachToActiveTask();
          awaitingAsyncTask = liveTask != null && !liveTask.isComplete;
          _emit(ShowSnackBarEvent('chat_peerTurnStillRunning'));
          return;
        }
      }

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
        replyToId: replyToId,
      );
      streaming.begin(optimistic.streaming.id, fromId: remoteAgent.id);
      messages.add(optimistic.user);
      messages.add(optimistic.streaming);
      messageIdMap[optimistic.user.id] = optimistic.user;
      messageIdMap[optimistic.streaming.id] = optimistic.streaming;
      // Resume live follow before the async scroll event is delivered — a
      // sticky scrolled-up flag from a prior turn would otherwise suppress
      // streaming rebuilds and follow-scrolls for this turn.
      isUserScrolledUp = false;
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
          scheduleStreamingScrollToBottom();
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
          scheduleStreamingRebuild();
        },
        onWorkflowPlanCreated: _handleDmWorkflowPlanCreated,
        onRequestHistory: (historyData) {
          pendingHistoryRequest = Map<String, dynamic>.from(historyData);
        },
      );

      // Phase 2-A: async-confirmation fast path.
      // When the agent supports async_confirmation, `sendMessageToAgent`
      // returns `null` as soon as the agent has ACK'd the request — the
      // streaming chunks, action_confirmation metadata, and eventual
      // task.completed all flow through TaskCallbacks asynchronously.
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
        } else {
          // Fast async completion: task finished (and was removed) before we
          // could hook onTaskFinished — reload from DB so the reply appears
          // without leaving the chat.
          await loadMessages();
        }
      }

      final handledHistorySupplement = await _handleHistorySupplementIfNeeded(
        remoteAgent: remoteAgent,
        userId: userId,
        userName: userName,
        agentResponse: agentResponse,
      );

      final turn = DmSendTurnPlanner.afterAgentSend(
        supportsAsyncConfirmation: supportsAsync,
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
      LoggerService().error('Send message failed', tag: 'ChatController', error: e, stackTrace: stackTrace);
      await loadMessages();
      final err = e.toString();
      if (e is PeerTurnInFlightException) {
        // 对方回合仍在进行：非失败，交由 reattach / onTaskFinished 的
        // processNextInQueue 继续排空。
        reattachToActiveTask();
        awaitingAsyncTask =
            chatService.getActiveTask(currentChannelId ?? '') != null;
        _emit(ShowSnackBarEvent('chat_peerTurnStillRunning'));
      } else {
        // 发送失败：保留 backlog（不清队列），暂停自动排空，等待用户手动
        // 恢复（编辑/删除/重发）。
        sendFailed = true;
        if (err.contains('not reachable after')) {
          _emit(ShowErrorSnackBarEvent('chat_reconnectFailed'));
        } else {
          _emit(ShowErrorSnackBarEvent('$e'));
        }
      }
    } finally {
      if (sendFailed) {
        if (awaitingAsyncTask) {
          // 异步确认路径：task 仍在后台跑，流式状态交给 onTaskFinished 清理，
          // 这里只暂停队列排空（避免级联）。
          _notify();
        } else {
          // 失败路径：清理当前回合状态但不调用 processNextInQueue——
          // 队列保留且停住，避免级联自动发送。
          acpCancellationToken = null;
          streaming.clear();
          pendingHistoryRequest = null;
          isProcessing = false;
          _notify();
        }
      } else if (awaitingAsyncTask) {
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
      from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
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
            scheduleStreamingScrollToBottom();
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

  @override
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
      if (url != null && url.startsWith('store://') &&
          (rawSize == null || rawSize == 0)) {
        // Agent 产物只给 store:// 引用时，向储物袋取真实大小用于展示。
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
  Future<void> processGroupMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<MentionEntry> mentions = const []}) async {
    if (currentChannelId == null || groupAgents.isEmpty) {
      LoggerService().debug('processGroupMessage ABORTED: channelId=$currentChannelId, groupAgents=${groupAgents.length}', tag: 'ChatController');
      return;
    }
    if (isProcessing) {
      LoggerService().debug(
        'processGroupMessage queued (already processing): ${content.length} chars',
        tag: 'ChatController',
      );
      messageQueue.add(
        QueuedMessage(
          id: const Uuid().v4(),
          content: content,
          replyToId: replyToId,
          mentions: mentions,
          attachments: attachments,
        ),
      );
      _notify();
      return;
    }
    LoggerService().debug('processGroupMessage: channelId=$currentChannelId, agents=${groupAgents.map((a) => a.name).toList()}, adminId=$groupAdminAgentId', tag: 'ChatController');

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    acpCancellationToken = ACPCancellationToken();
    final epoch = groupTurnGate.beginTurn();
    // 群回合失败标记：失败时保留 backlog 并暂停自动排空。
    bool groupFailed = false;
    _notify();

    final userMessage = GroupInteractionPlanner.buildOptimisticUserMessage(
      content: content,
      userId: userId,
      userName: userName,
      replyToId: replyToId,
    );
    messages.add(userMessage);
    messageIdMap[userMessage.id] = userMessage;
    isUserScrolledUp = false;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    final turn = ChatGroupStreamingTracker();

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final mentionedAgentIds = GroupMentionResolver.resolveAgentIds(
        content: content,
        mentions: mentions,
        agents: [
          for (final a in groupAgents) (id: a.id, name: a.name),
        ],
      );
      final userMsgMetadata =
          GroupInteractionPlanner.userMessageMentionsMetadata(mentions);

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
          _emit(RequestScrollToBottomEvent(force: true));
        },
        onStreamChunk: (aid, anm, chunk) {
          if (!groupTurnGate.isCurrent(epoch)) return;
          if (turn.appendAndApply(aid, chunk, messages, messageIdMap) == null) {
            return;
          }
          scheduleStreamingRebuild();
          scheduleStreamingScrollToBottom();
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
        onInteractionRequest: (agentId, agentName, interactionType, data) async {
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
      LoggerService().error('processGroupMessage error: $e', tag: 'ChatController', error: e, stackTrace: stackTrace);
      groupFailed = true;
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
        if (!groupFailed) processNextInQueue();
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
    final workflowId = GroupInteractionPlanner.workflowIdFromPlanApproval(
      interactionType,
      data,
    );
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

    // 附件消息发送失败标记：失败时暂停自动排空，保留 backlog。
    bool fileFailed = false;

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
          scheduleStreamingScrollToBottom();
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
      fileFailed = true;
      _emit(ShowErrorSnackBarEvent('chat_fileMessageFailed:$e'));
    } finally {
      streaming.clear();
      isProcessing = false;
      _notify();
      // 失败时保留 backlog 并暂停自动排空，等待用户手动恢复。
      if (!fileFailed) processNextInQueue();
    }
  }

  @override
  void scheduleStreamingRebuild() {
    if (_pendingStreamingRebuild) return;
    _pendingStreamingRebuild = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStreamingRebuild = false;
      _notify();
    });
  }

  @override
  void scheduleStreamingScrollToBottom() {
    // Do not gate on isUserScrolledUp at schedule time — a sticky false
    // positive (common with long lists after jumpTo) would drop every chunk's
    // follow-scroll for the rest of the turn. Check at emit time instead;
    // ChatScreen also resumes live-follow after force sends.
    if (_pendingStreamingScroll) return;
    _pendingStreamingScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStreamingScroll = false;
      if (isUserScrolledUp) return;
      _emit(RequestScrollToBottomEvent());
    });
  }

}
