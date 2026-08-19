part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Session management
//
// 会话生命周期相关操作（新建/清空/批量删除会话）。这些方法仅被 UI 调用，
// 不被控制器内部其他逻辑回调，因此安全地拆分为挂载在 [_ChatControllerBase]
// 上的 mixin；可直接访问基类的全部字段与核心辅助方法。
// ---------------------------------------------------------------------------

mixin _SessionOps on _ChatControllerBase {
  void resetSession(TextEditingController messageController) {
    messageController.text = '/reset';
    // The UI will call sendMessage
  }

  /// 切换/新建会话离开当前会话前，自动删除「新建会话」产生的空会话。
  ///
  /// 判定见 [SessionUtils.shouldPruneEmptySessionOnSwitch]；此处再补充两个
  /// 「非空」条件：有待发送队列（离线排队中的消息）或已有落库消息。删除时
  /// 与批量删除一致，级联清理群成员 DM / She 中转会话。
  Future<void> pruneEmptySessionBeforeSwitch({String? nextChannelId}) async {
    final currentId = currentChannelId;
    if (currentId == null) return;

    final shouldPrune = SessionUtils.shouldPruneEmptySessionOnSwitch(
      currentChannelId: currentId,
      nextChannelId: nextChannelId,
      isGroupMode: isGroupMode,
      groupFamilyId: groupChannel?.groupFamilyId,
      defaultDmChannelId: agentId == null
          ? null
          : chatService.generateChannelId(getUserId(), agentId!),
    );
    if (!shouldPrune) return;

    // 有待发送队列（离线排队中的消息）或已有消息：不算空会话，保留。
    if (chatService.pendingSendQueue(currentId).isNotEmpty) return;
    final count = await localDatabaseService.countChannelMessages(currentId);
    if (count > 0) return;

    if (isGroupMode) {
      await GroupMemberSessionService(localDatabaseService)
          .deleteMemberSessionsForGroupChannel(currentId);
    } else {
      await SheRelaySessionService(localDatabaseService)
          .deleteRelaySessionsForSheChannel(currentId);
    }
    await localDatabaseService.deleteChannelMessages(currentId);
    await localDatabaseService.deleteChannel(currentId);
  }

  Future<void> createNewSession() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final previousChannelId = currentChannelId;

    try {
      final newChannelId = await chatService.createNewSession(
        userId: userId,
        userName: userName,
        agentId: agentId!,
        agentName: agentName ?? 'Agent',
      );

      // She DM ↔ bound group sessions: opening a new She session also forks
      // a fresh bound group session for each previously linked group family.
      if (SheService.isSheIdentity(agentId!) &&
          previousChannelId != null &&
          previousChannelId.isNotEmpty) {
        try {
          await chatService.cascadeSheBoundGroupSessions(
            oldSheChannelId: previousChannelId,
            newSheChannelId: newChannelId,
            userId: userId,
          );
        } catch (e) {
          LoggerService().warning(
            'Failed to cascade She-bound group sessions: $e',
            tag: 'ChatController',
          );
        }
      }

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);

      // 离开当前会话：若它是「新建会话」留下的空会话，自动删除。
      await pruneEmptySessionBeforeSwitch(nextChannelId: newChannelId);

      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        agentId: agentId,
        agentName: agentName,
        agentAvatar: agentAvatar,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_newSessionFailed:$e'));
    }
  }

  Future<void> createNewGroupSession() async {
    if (groupChannel == null || currentChannelId == null) return;

    final userId = getUserId();

    try {
      final newChannelId = await chatService.createNewGroupSession(
        channelId: currentChannelId!,
        userId: userId,
      );

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);

      // 离开当前会话：若它是「新建会话」留下的空会话，自动删除。
      await pruneEmptySessionBeforeSwitch(nextChannelId: newChannelId);

      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_newGroupSessionFailed:$e'));
    }
  }

  Future<void> clearCurrentSessionHistory() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final sessionId = currentChannelId
        ?? await chatService.getLatestActiveChannelId(userId, agentId!)
        ?? chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingSession'));

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);

      if (remoteAgent != null && remoteAgent.isOnline) {
        try {
          await chatService.sendMessageToAgent(
            content: '/reset',
            agent: remoteAgent,
            userId: userId,
            userName: userName,
            channelId: sessionId,
          );
        } catch (_) {}
      }

      final sessions = await chatService.getAgentSessions(agentId: agentId!);

      if (sessions.length > 1) {
        await localDatabaseService.deleteChannelMessages(sessionId);
        await localDatabaseService.deleteChannel(sessionId);

        final remaining = sessions.where((s) => s.id != sessionId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
        ));
      } else {
        await localDatabaseService.deleteChannelMessages(sessionId);

        _emit(DismissOverlayEvent());
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_sessionCleared'));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearSessionFailed:$e'));
    }
  }

  Future<void> clearAllSessionsHistory() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final sessionId = currentChannelId
        ?? await chatService.getLatestActiveChannelId(userId, agentId!)
        ?? chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);

      if (remoteAgent != null && remoteAgent.isOnline) {
        try {
          await chatService.sendMessageToAgent(
            content: '/reset-all',
            agent: remoteAgent,
            userId: userId,
            userName: userName,
            channelId: sessionId,
          );
        } catch (_) {}
      }

      final sessions = await chatService.getAgentSessions(agentId: agentId!);
      final defaultChannelId = chatService.generateChannelId(userId, agentId!);

      for (final session in sessions) {
        await localDatabaseService.deleteChannelMessages(session.id);
        if (session.id != defaultChannelId) {
          await localDatabaseService.deleteChannel(session.id);
        }
      }

      final defaultChannel = await localDatabaseService.getChannelById(defaultChannelId);
      if (defaultChannel == null) {
        final channel = Channel.withMemberIds(
          id: defaultChannelId,
          name: 'Chat with ${agentName ?? 'Agent'}',
          type: 'dm',
          memberIds: [userId, agentId!],
          isPrivate: true,
        );
        await localDatabaseService.createChannel(channel, userId);
      }

      _emit(DismissOverlayEvent());
      final isAlreadyDefault = currentChannelId == defaultChannelId;

      if (isAlreadyDefault) {
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_allSessionsCleared'));
      } else {
        _emit(NavigateToSessionEvent(
          channelId: defaultChannelId,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
        ));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearAllSessionsFailed:$e'));
    }
  }

  Future<void> clearGroupSessionHistory() async {
    if (groupChannel == null || currentChannelId == null) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingGroupSession'));

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final parentGroupId = groupChannel!.groupFamilyId;
      final sessions = await chatService.getGroupSessions(parentGroupId: parentGroupId);

      if (sessions.length > 1) {
        await chatService.clearGroupSessionHistory(
          channelId: currentChannelId!,
          agentIds: agentIds,
        );
        await GroupMemberSessionService(localDatabaseService)
            .deleteMemberSessionsForGroupChannel(currentChannelId!);
        await localDatabaseService.deleteChannel(currentChannelId!);

        final remaining = sessions.where((s) => s.id != currentChannelId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          embedded: embedded,
        ));
      } else {
        await chatService.clearGroupSessionHistory(
          channelId: currentChannelId!,
          agentIds: agentIds,
        );

        _emit(DismissOverlayEvent());
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_groupSessionCleared'));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearGroupSessionFailed:$e'));
    }
  }

  Future<void> clearAllGroupSessionsHistory() async {
    if (groupChannel == null || currentChannelId == null) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingAllGroupSessions'));

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final parentGroupId = groupChannel!.groupFamilyId;

      await chatService.clearAllGroupSessions(
        parentGroupId: parentGroupId,
        currentChannelId: currentChannelId!,
        agentIds: agentIds,
      );

      _emit(DismissOverlayEvent());
      final isAlreadyParent = currentChannelId == parentGroupId;

      if (isAlreadyParent) {
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_allGroupSessionsCleared'));
      } else {
        _emit(NavigateToSessionEvent(
          channelId: parentGroupId,
          embedded: embedded,
        ));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearAllGroupSessionsFailed:$e'));
    }
  }

  Future<void> batchDeleteSessions(List<String> sessionIds, {required bool isGroup}) async {
    if (sessionIds.isEmpty) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      // Guard: never delete the parent group channel itself, only child sessions.
      // Use groupFamilyId so the parent is protected regardless of which session is currently open.
      final parentGroupId = groupChannel?.groupFamilyId;
      final idsToDelete = isGroup && parentGroupId != null
          ? sessionIds.where((id) => id != parentGroupId).toList()
          : sessionIds;

      for (final id in idsToDelete) {
        if (isGroup) {
          await GroupMemberSessionService(localDatabaseService)
              .deleteMemberSessionsForGroupChannel(id);
        } else {
          // She↔用户 会话被删除时，级联删除其绑定的 She 中转会话
          await SheRelaySessionService(localDatabaseService)
              .deleteRelaySessionsForSheChannel(id);
        }
        await localDatabaseService.deleteChannelMessages(id);
        await localDatabaseService.deleteChannel(id);
      }

      _emit(DismissOverlayEvent());
      _emit(ShowSnackBarEvent('chat_batchDeleteSuccess:${idsToDelete.length}'));
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearSessionFailed:$e'));
    }
  }
}
