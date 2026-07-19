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

      final optimistic = DmSendTurnPlanner.buildOptimisticPair(
        content: content,
        userId: userId,
        userName: userName,
        agentId: remoteAgent.id,
        agentName: remoteAgent.name,
        replyToId: replyToId,
      );
      streaming.begin(optimistic.streaming.id);
      messages.add(optimistic.user);
      messages.add(optimistic.streaming);
      messageIdMap[optimistic.user.id] = optimistic.user;
      messageIdMap[optimistic.streaming.id] = optimistic.streaming;
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
      messageQueue.clear();
      await loadMessages();
      final err = e.toString();
      if (err.contains('not reachable after')) {
        _emit(ShowErrorSnackBarEvent('chat_reconnectFailed'));
      } else {
        _emit(ShowErrorSnackBarEvent('$e'));
      }
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
            if (!isUserScrolledUp) {
              _emit(RequestScrollToBottomEvent());
            }
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

  @override
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

    final userMessage = GroupInteractionPlanner.buildOptimisticUserMessage(
      content: content,
      userId: userId,
      userName: userName,
      replyToId: replyToId,
    );
    messages.add(userMessage);
    messageIdMap[userMessage.id] = userMessage;
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
        onActiveWorkflowChanged: (workflowId) => setActiveWorkflowId(workflowId),
        onInteractionRequest: (agentId, agentName, interactionType, data) =>
            _handleProcessGroupInteractionRequest(
          turn: turn,
          agentId: agentId,
          agentName: agentName,
          interactionType: interactionType,
          data: data,
        ),
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

    if (GroupInteractionPlanner.isNonBlocking(interactionType)) {
      if (!event.result.isCompleted) {
        event.result.complete(GroupInteractionPlanner.nonBlockingResult());
      }
      pendingGroupInteractions.remove(pendingKey);
      _notify();
      return GroupInteractionPlanner.nonBlockingResult();
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
      _emit(ShowErrorSnackBarEvent('chat_fileMessageFailed:$e'));
    } finally {
      streaming.clear();
      isProcessing = false;
      _notify();
      processNextInQueue();
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

}
