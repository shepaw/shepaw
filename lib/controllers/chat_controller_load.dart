part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Message loading + peer device label resolution
// ---------------------------------------------------------------------------

mixin _LoadOps on _ChatControllerBase {
  // ---------------------------------------------------------------------------
  // Message loading
  // ---------------------------------------------------------------------------

  @override
  Future<void> loadMessages() async {
    isLoading = true;
    _notify();

    try {
      final userId = getUserId();

      switch (ChatLoadChannelPlanner.decideChannel(
        currentChannelId: currentChannelId,
        initialChannelId: initialChannelId,
        agentId: agentId,
      )) {
        case ChatLoadChannelAction.keepCurrent:
          break;
        case ChatLoadChannelAction.useInitial:
          currentChannelId = initialChannelId;
        case ChatLoadChannelAction.resolveFromAgent:
          final latestChannelId =
              await chatService.getLatestActiveChannelId(userId, agentId!);
          currentChannelId =
              latestChannelId ?? chatService.generateChannelId(userId, agentId!);
        case ChatLoadChannelAction.abort:
          isLoading = false;
          _notify();
          return;
      }

      // Mark this channel as the most recently opened for this agent so
      // re-entry from the conversation list restores the same session.
      await localDatabaseService.touchChannelUpdatedAt(currentChannelId!);

      AppLifecycleService().setActiveChannel(currentChannelId);
      NotificationService().cancelNotification(currentChannelId.hashCode);

      // Surface service-side DB writes (member failure notices, orchestration
      // system messages) in the chat immediately.
      _subscribeChannelUpdates();

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
      // Reset group-bound DM markers; re-set below when applicable.
      sourceGroupChannelId = null;
      sourceGroupName = null;
      sourceSheChannelId = null;

      if (channel != null && channel.isGroup) {
        isGroupMode = true;
        groupChannel = channel;
        mentionOnlyMode = channel.isAllMembersMentionMode;
        final agentIds =
            ChatLoadChannelPlanner.groupAgentMemberIds(channel, userId);
        final agents = <RemoteAgent>[];
        for (final aid in agentIds) {
          final agent = await localDatabaseService.getRemoteAgentById(aid);
          if (agent != null) agents.add(agent);
        }
        groupAgents = agents;
        groupAdminAgentId = channel.adminAgentId;
      } else if (channel != null && channel.isDM) {
        isGroupMode = false;
        groupChannel = null;
        groupAgents = [];
        groupAdminAgentId = null;
        // She 私聊启用 DM 工作流（自规划自执行）；其他 DM（普通 agent、
        // 绑定中继会话）不启用。
        dmWorkflowEnabled = channel.agentIds.contains(SheService.sheId);
        // Load DM channel's custom system prompt
        dmSystemPrompt = channel.systemPrompt;
        if (channel.isGroupBoundMemberSession) {
          sourceGroupChannelId = channel.sourceGroupChannelId;
          final sourceGroup = await localDatabaseService
              .getChannelById(channel.sourceGroupChannelId!);
          sourceGroupName = sourceGroup?.name ?? channel.name;
          // One-time backfill: copy this agent's prior group replies into the
          // bound session so older groups still show session history.
          await GroupMemberSessionService(localDatabaseService)
              .backfillAgentMessagesFromGroupIfNeeded(
            memberSessionId: channel.id,
            groupChannelId: channel.sourceGroupChannelId!,
            agentId: agentId ??
                ChatLoadChannelPlanner.firstAgentMemberId(channel) ??
                '',
          );
        }
        if (channel.isSheBoundSession) {
          sourceSheChannelId = channel.sourceSheChannelId;
        }
        if (agentName == null) {
          // Resolve agent name/avatar from channel when not provided
          // (e.g. navigating from search results by channelId only)
          final agentMemberId = ChatLoadChannelPlanner.firstAgentMemberId(channel);
          if (agentMemberId != null) {
            final agent =
                await localDatabaseService.getRemoteAgentById(agentMemberId);
            if (agent != null) {
              agentName = agent.name;
              agentAvatar = agent.avatar;
            }
          }
        }
      } else if (channel != null && !channel.isGroup && agentName == null) {
        isGroupMode = false;
        // Non-group, non-DM typed channel — resolve agent name from channel
        final agentMemberId = ChatLoadChannelPlanner.firstAgentMemberId(channel);
        if (agentMemberId != null) {
          final agent =
              await localDatabaseService.getRemoteAgentById(agentMemberId);
          if (agent != null) {
            agentName = agent.name;
            agentAvatar = agent.avatar;
          }
        }
      }

      await _refreshWorkspaceUris();

      var loadedMessages = List<Message>.from(await chatService.loadChannelMessages(
        currentChannelId!,
        limit: ChatMessageWindow.initialLimit,
      ));

      // 进页收信：channel 中继 agent 拉信箱。群聊按成员拉取，按 group_id 路由回群；
      // 无 group_id 的回复才进 fallback DM，不会写进当前群。
      final inboxAgents = <RemoteAgent>[];
      if (isGroupMode) {
        inboxAgents.addAll(groupAgents);
      } else if (agentId != null) {
        final agent = await localDatabaseService.getRemoteAgentById(agentId!);
        if (agent != null) inboxAgents.add(agent);
      }
      var mailboxInserted = false;
      for (final agent in inboxAgents) {
        if (!ChannelMailboxService.agentHasChannelInbox(agent)) continue;
        final mailboxMsgs = await chatService.fetchMailboxReplies(
          channelId: isGroupMode ? null : currentChannelId,
          agentId: agent.id,
          userId: userId,
        );
        final forHere =
            mailboxMsgs.where((m) => m.channelId == currentChannelId);
        if (forHere.isEmpty) continue;
        loadedMessages.addAll(forHere);
        mailboxInserted = true;
      }
      if (mailboxInserted) {
        loadedMessages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      }
      await _setupInboxPush(agents: inboxAgents, userId: userId);

      _preserveInMemoryPlanApprovalResponses();
      if (isGroupMode) {
        messages = loadedMessages;
      } else {
        _mergeDmStreamingPlaceholders(loadedMessages);
      }
      rebuildMessageIdMap();
      // 占位若被 merge 折叠进 DB 行（id 改名），立即回指锚点，恢复
      // streaming 标记与后续 chunk 的应用目标。
      streaming.repointAnchor(messages);
      // 锚点已不在 messages（占位被替换且无宿主可回指）且没有存活任务 →
      // 孤儿 streaming 会话。留着会让 streaming.isActive 永远为 true，
      // 后续 reloadMessagesFromDB 全部被 defer（UI 卡「等待回复」，
      // 重进才恢复）。活回合由后面的 reattachToActiveTask 重新 begin。
      if (streaming.isOrphan(
        messages: messages,
        hasLiveTask: chatService.getActiveTask(currentChannelId!) != null,
      )) {
        streaming.clear();
      }
      await _refreshHasMoreOlderMessages();
      _reapplyStashedPlanApprovalResponses();
      await PendingApprovalHub.instance.reconcileForChannel(
        currentChannelId!,
        messages,
        workflowService: WorkflowService(db: localDatabaseService),
      );
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
        // 进程被杀后内存编排循环消亡：检查群工作空间最新编排状态，
        // 非终态时提示用户「发消息即可从断点继续」（幂等，同一轮次只提示一次）。
        await chatService.maybeNotifyInterruptedOrchestration(currentChannelId!);
        final interruptedInfo =
            chatService.getInterruptedTaskInfo(currentChannelId!);
        if (interruptedInfo != null) {
          chatService.clearInterruptedTaskInfo(currentChannelId!);
          await reloadMessagesFromDB();
          _emit(ShowRetrySnackBarEvent(
            'chat_connectionInterrupted',
            'chat_connectionInterruptedRetry',
            interruptedInfo,
          ));
        }
      } else if (dmWorkflowEnabled) {
        // DM 工作流恢复：愈合孤儿步骤/续跑/重挂执行 UI（决策表频道无关）。
        // _reattachPendingPlanApproval 保持群聊专属——DM 审批卡片靠
        // 消息 metadata 持久化，无 Completer 需要重挂。
        await _restoreWorkflowContext();
      }
      // 排队消息存活于 ChatService 侧（退出页面不丢）；重进时若无在途回合
      // 接管（reattach 置 isProcessing=true），立即恢复发送；有在途回合则
      // 由其 onTaskFinished 的 processNextInQueue 排空。
      if (messageQueue.isNotEmpty && !isProcessing) {
        unawaited(processNextInQueue());
      }
      await _flushAllStashedPlanApprovalResponses();
    } catch (e) {
      isLoading = false;
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_loadFailed:$e'));
    }
  }

  @override
  Future<int> loadOlderMessages() async {
    final channelId = currentChannelId;
    if (channelId == null) return 0;
    if (!hasMoreOlderMessages || isLoadingOlderMessages) return 0;
    if (messages.isEmpty) return 0;

    isLoadingOlderMessages = true;
    _notify();

    try {
      // Prefer the persisted created_at cursor so local/UTC formatting matches
      // the SQLite row exactly (avoids missing/duplicating the boundary row).
      final oldest = messages.first;
      final beforeCreatedAt =
          await localDatabaseService.getMessageCreatedAt(oldest.id) ??
              DateTime.fromMillisecondsSinceEpoch(oldest.timestampMs)
                  .toIso8601String();
      final older = await chatService.loadOlderChannelMessages(
        channelId,
        beforeCreatedAt: beforeCreatedAt,
        limit: ChatMessageWindow.pageSize,
      );

      final fresh = <Message>[];
      for (final m in older) {
        if (messageIdMap.containsKey(m.id)) continue;
        fresh.add(m);
      }

      if (fresh.isNotEmpty) {
        messages.insertAll(0, fresh);
        for (final m in fresh) {
          messageIdMap[m.id] = m;
        }
      }

      // Exhausted when the DB page was short, or everything was already present.
      hasMoreOlderMessages = older.length >= ChatMessageWindow.pageSize;
      return fresh.length;
    } catch (e) {
      LoggerService().warning(
        'loadOlderMessages failed: $e',
        tag: 'ChatController',
        error: e,
      );
      return 0;
    } finally {
      isLoadingOlderMessages = false;
      _notify();
    }
  }

  @override
  Future<void> _refreshHasMoreOlderMessages() async {
    final channelId = currentChannelId;
    if (channelId == null) {
      hasMoreOlderMessages = false;
      return;
    }
    try {
      final total = await chatService.countChannelMessages(channelId);
      // In-memory may include optimistic streaming placeholders not in DB.
      final persistedApprox = messages.where((m) {
        final id = m.id;
        return !id.startsWith('streaming_') &&
            !id.startsWith('group_streaming_') &&
            !id.startsWith('hint_');
      }).length;
      hasMoreOlderMessages = total > persistedApprox;
    } catch (_) {
      hasMoreOlderMessages =
          messages.length >= ChatMessageWindow.initialLimit;
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
    final peers = await _peerDeviceEntries();
    return PeerDeviceLabelResolver.hostInboundLabel(
      channel: channel,
      peers: peers,
    );
  }

  /// Client 侧：当前 DM 会话访问的是对端分享的 peer agent 时的来源设备名。
  Future<String?> _resolveClientPeerAgentDeviceLabel(Channel? channel) async {
    final targetAgentId = PeerDeviceLabelResolver.clientAgentId(
      channel: channel,
      fallbackAgentId: agentId,
    );
    if (targetAgentId == null) return null;

    try {
      final agent = await localDatabaseService.getRemoteAgentById(targetAgentId);
      if (agent == null) return null;
      final peers = await _peerDeviceEntries();
      return PeerDeviceLabelResolver.clientPeerAgentLabel(
        isPeerAgent: agent.isPeerAgent,
        sourcePeerId: agent.sourcePeerId,
        sourcePeerNameSnapshot: agent.sourcePeerName,
        peers: peers,
      );
    } catch (_) {}
    return null;
  }

  Future<List<({String id, String deviceName})>> _peerDeviceEntries() async {
    try {
      final peers = await PeerStorageService().loadAllPeers();
      return [
        for (final p in peers) (id: p.id, deviceName: p.deviceName),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _setupInboxPush({
    required List<RemoteAgent> agents,
    required String userId,
  }) async {
    _clearInboxPush();

    final inboxAgents =
        agents.where(ChannelMailboxService.agentHasChannelInbox).toList();
    if (inboxAgents.isEmpty) return;

    final identity = await NoiseIdentity.loadOrCreate();
    String? connectedBase;
    final acpIdToAgent = <String, RemoteAgent>{};

    for (final agent in inboxAgents) {
      final channelBase =
          ChannelMailboxService.channelBaseFromEndpoint(agent.endpoint);
      final acpAgentId = ChannelMailboxService.acpAgentIdFor(agent);
      if (channelBase == null || acpAgentId.isEmpty) continue;
      if (acpIdToAgent.containsKey(acpAgentId)) continue;

      if (connectedBase == null) {
        await InboxSubscribeService.instance.ensureConnected(
          channelBase: channelBase,
          callerFp: identity.fingerprintHex,
        );
        connectedBase = channelBase;
      } else if (channelBase != connectedBase) {
        continue;
      }

      InboxSubscribeService.instance.subscribe(acpAgentId);
      _inboxSubscribeTargetIds.add(acpAgentId);
      acpIdToAgent[acpAgentId] = agent;
    }

    if (acpIdToAgent.isEmpty) return;

    _inboxPushSub = InboxSubscribeService.instance.onMailReply.listen(
      (event) async {
        final toFetch = <RemoteAgent>[];
        if (event.targetId.isEmpty) {
          toFetch.addAll(acpIdToAgent.values);
        } else {
          final matched = acpIdToAgent[event.targetId];
          if (matched != null) toFetch.add(matched);
        }
        if (toFetch.isEmpty) return;
        final channelId = currentChannelId;
        if (channelId == null) return;
        final newMsgs = <Message>[];
        for (final agent in toFetch) {
          newMsgs.addAll(
            await chatService.fetchMailboxReplies(
              channelId: isGroupMode ? null : channelId,
              agentId: agent.id,
              userId: userId,
            ),
          );
        }
        final forHere =
            newMsgs.where((m) => m.channelId == channelId).toList();
        if (forHere.isEmpty) return;
        messages.addAll(forHere);
        messages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
        rebuildMessageIdMap();
        _notify();
      },
    );
  }
}
