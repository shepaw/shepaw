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

      final loadedMessages =
          await chatService.loadChannelMessages(currentChannelId!);

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
      } else if (dmWorkflowEnabled) {
        // DM 工作流恢复：愈合孤儿步骤/续跑/重挂执行 UI（决策表频道无关）。
        // _reattachPendingPlanApproval 保持群聊专属——DM 审批卡片靠
        // 消息 metadata 持久化，无 Completer 需要重挂。
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
}
