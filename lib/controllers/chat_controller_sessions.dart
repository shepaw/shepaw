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
  /// 判定见 [SessionUtils.shouldPruneEmptySessionOnSwitch]。下面几种不算空：
  /// 输入框里还有没发出去的草稿、待发送队列里还有消息、本地已经落库的消息。
  /// 删除时与批量删除一致，级联清理群成员 DM / She 中转会话。
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

    // 输入框有未发送内容，或队列里还有没发出去的消息：留下这条会话。
    if (_hasUnsentComposerDraft(currentId) || messageQueue.isNotEmpty) return;

    // 已有消息：不算空会话，保留。
    final count = await localDatabaseService.countChannelMessages(currentId);
    if (count > 0) return;

    if (!isGroupMode && agentId != null) {
      final agent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (agent != null && agent.isPeerAgent) {
        final dropped = await PeerAgentClientService.instance.dropHostSession(
          agent: agent,
          channelId: currentId,
        );
        if (dropped == HostEmptySessionResult.notEmpty ||
            dropped == HostEmptySessionResult.failed) {
          return;
        }
      }
    }

    if (isGroupMode) {
      await GroupMemberSessionService(localDatabaseService)
          .deleteMemberSessionsForGroupChannel(currentId);
    } else {
      await SheRelaySessionService(localDatabaseService)
          .deleteRelaySessionsForSheChannel(currentId);
    }
    await localDatabaseService.deleteChannelMessages(currentId);
    await localDatabaseService.deleteChannel(currentId);
    await _forgetActivatedSession(currentId);
  }

  /// 这条会话的输入框草稿还在（按频道 id，不看列表别名）。
  ///
  /// 列表上的 `agent:` / `group:` 别名是最近一次编辑的镜像，不能拿来判断
  /// 当前会话有没有未发送内容，否则同一 agent 下任意会话都会被留下。
  bool _hasUnsentComposerDraft(String channelId) {
    if (channelId.isEmpty || !getIt.isRegistered<ComposerDraftService>()) {
      return false;
    }
    return getIt<ComposerDraftService>()
        .getDraft(channelId)
        .trimRight()
        .isNotEmpty;
  }

  /// 会话被删掉后清掉指向它的「最近人工激活」指针，免得同 id 的会话后来
  /// 又被主机同步回来时把对话入口带错地方。等它落地再返回，避免紧接着的
  /// 列表补刷（或立刻退进程）又读到盘上的旧值。
  Future<void> _forgetActivatedSession(String channelId) async {
    if (channelId.isEmpty) return;
    if (!getIt.isRegistered<LastActivatedSessionStore>()) return;
    await getIt<LastActivatedSessionStore>().forgetChannel(channelId);
  }

  /// [manualActivation] 为 false 时（批量删除后自动补一条空会话）不记人工
  /// 激活指针：那条频道是算出来的，不是用户挑的。
  Future<void> createNewSession({bool manualActivation = true}) async {
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

      unawaited(() async {
        try {
          final agent = await localDatabaseService.getRemoteAgentById(agentId!);
          if (agent == null) return;
          await PeerAgentClientService.instance.openHostSession(
            agent: agent,
            channelId: newChannelId,
          );
          await PeerAgentClientService.instance.warmSession(
            agent: agent,
            channelId: newChannelId,
          );
        } catch (_) {}
      }());

      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        agentId: agentId,
        agentName: agentName,
        agentAvatar: agentAvatar,
        embedded: embedded,
        manualActivation: manualActivation,
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

  /// 分叉会话：把 [session] 复制为一个新会话（消息 + 工具执行历史），并跳转过去。
  ///
  /// 达到「会话分叉」的目的：从该会话的历史继续一条新分支，原会话保持不变。
  Future<void> forkSession(Channel session, {required bool isGroup}) async {
    _emit(ShowLoadingOverlayEvent('chat_forkingSession'));
    try {
      final newChannelId = await chatService.forkSession(
        sourceChannelId: session.id,
        userId: getUserId(),
        userName: getUserName(),
        agentId: agentId,
        agentName: agentName,
        isGroup: isGroup,
      );

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);
      await pruneEmptySessionBeforeSwitch(nextChannelId: newChannelId);

      _emit(DismissOverlayEvent());
      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        agentId: isGroup ? null : agentId,
        agentName: isGroup ? null : agentName,
        agentAvatar: isGroup ? null : agentAvatar,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_forkSessionFailed:$e'));
    }
  }

  /// 复制会话到另一个 agent：在 [target] 下生成一份副本（消息 + 工具执行
  /// 历史），并跳转过去。源会话保持不变。
  Future<void> copySessionToAgent(Channel session, RemoteAgent target) async {
    _emit(ShowLoadingOverlayEvent('chat_copyingSession'));
    try {
      final newChannelId = await chatService.copySessionToAgent(
        sourceChannelId: session.id,
        userId: getUserId(),
        targetAgentId: target.id,
      );

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);
      await pruneEmptySessionBeforeSwitch(nextChannelId: newChannelId);

      _emit(DismissOverlayEvent());
      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        agentId: target.id,
        agentName: target.name,
        agentAvatar: target.avatar,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_copySessionFailed:$e'));
    }
  }

  Future<void> clearCurrentSessionHistory() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final sessionId = currentChannelId ??
        await chatService.getLatestActiveChannelId(userId, agentId!) ??
        chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingSession'));

    try {
      final remoteAgent =
          await localDatabaseService.getRemoteAgentById(agentId!);

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
        await _forgetActivatedSession(sessionId);

        final remaining = sessions.where((s) => s.id != sessionId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
          // 清掉当前会话后跳到「剩下第一条」是兜底，不是人工点选。
          manualActivation: false,
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
    final sessionId = currentChannelId ??
        await chatService.getLatestActiveChannelId(userId, agentId!) ??
        chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      final remoteAgent =
          await localDatabaseService.getRemoteAgentById(agentId!);

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
          await _forgetActivatedSession(session.id);
        }
      }

      final defaultChannel =
          await localDatabaseService.getChannelById(defaultChannelId);
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
          // 清空全部会话后回默认频道是兜底，不是人工点选。
          manualActivation: false,
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
      final sessions =
          await chatService.getGroupSessions(parentGroupId: parentGroupId);

      if (sessions.length > 1) {
        await chatService.clearGroupSessionHistory(
          channelId: currentChannelId!,
          agentIds: agentIds,
        );
        await GroupMemberSessionService(localDatabaseService)
            .deleteMemberSessionsForGroupChannel(currentChannelId!);
        await localDatabaseService.deleteChannel(currentChannelId!);
        await _forgetActivatedSession(currentChannelId!);

        final remaining =
            sessions.where((s) => s.id != currentChannelId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          embedded: embedded,
          manualActivation: false,
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
          manualActivation: false,
        ));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearAllGroupSessionsFailed:$e'));
    }
  }

  /// 某个频道自己的 mirror 状态。批量删除时每个被删的节点会话都要用它发
  /// 取消：只用 currentChannelId 的那份会让其它正在跑的 flow 回合在主机上
  /// 继续，下一条消息又把刚删掉的频道建回来（A8-6）。
  ({String? sessionKey, String? runtimeTurnId}) _runtimeCancelArgs(
      String channelId) {
    final exact = channelId == currentChannelId
        ? sessionRuntimeKey
        : (agentId == null || agentId!.isEmpty
            ? null
            : SessionRuntimeMirror.sessionKey(
                agentId: agentId!, channelId: channelId));
    final mirror = getIt.isRegistered<SessionRuntimeMirror>()
        ? getIt<SessionRuntimeMirror>()
        : null;
    final state = mirror == null
        ? null
        : ((exact == null ? null : mirror.peek(exact)) ??
                mirror.notifierForChannel(channelId))
            ?.value;
    final key = (state != null && state.sessionKey.isNotEmpty)
        ? state.sessionKey
        : exact;
    final turnId = state?.turnId.trim() ?? '';
    return (sessionKey: key, runtimeTurnId: turnId.isEmpty ? null : turnId);
  }

  Future<void> batchDeleteSessions(List<String> sessionIds,
      {required bool isGroup}) async {
    if (sessionIds.isEmpty) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      // Guard: never delete the parent group channel itself, only child sessions.
      // Use groupFamilyId so the parent is protected regardless of which session is currently open.
      final parentGroupId = groupChannel?.groupFamilyId;
      final idsToDelete = isGroup && parentGroupId != null
          ? sessionIds.where((id) => id != parentGroupId).toList()
          : sessionIds;
      if (idsToDelete.isEmpty) {
        _emit(DismissOverlayEvent());
        return;
      }

      // 先让主机按权威数据删／归档，再动本地镜像。主机连不上就整批失败，
      // 否则本地删掉后下一轮名单同步又会被主机建回来。
      if (!isGroup && agentId != null) {
        final hostAgent =
            await localDatabaseService.getRemoteAgentById(agentId!);
        if (hostAgent != null && hostAgent.isPeerAgent) {
          for (final id in idsToDelete) {
            final result = await PeerAgentClientService.instance
                .deleteHostSession(agent: hostAgent, channelId: id);
            if (result == HostSessionDeleteResult.failed) {
              _emit(DismissOverlayEvent());
              _emit(ShowErrorSnackBarEvent('chat_sessionDeleteFailed'));
              return;
            }
          }
        }
      }

      final deletingCurrent =
          currentChannelId != null && idsToDelete.contains(currentChannelId);
      // 先停掉**每一个**被删会话上还在跑的回复，再删库：主机发起的节点回合
      // 没有本地 _pending，必须按各频道 mirror 里的 sessionKey + turnId 逐个
      // 发 `flow-` 取消（A7-8 / A8-6）。只停当前频道会让其它节点回合继续跑，
      // 下一条 message.created 又把刚删的频道建回来。
      for (final id in idsToDelete) {
        if (isGroup) {
          chatService.cancelActiveGroupTasks(id);
          continue;
        }
        final args = _runtimeCancelArgs(id);
        await chatService.cancelActiveDmTask(
          id,
          sessionKey: args.sessionKey,
          runtimeTurnId: args.runtimeTurnId,
        );
      }

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
        await _forgetActivatedSession(id);
      }

      _emit(DismissOverlayEvent());

      if (deletingCurrent) {
        messages.clear();
        messageIdMap.clear();
        _notify();
        final fallback = await _channelToOpenAfterDelete(
          deletedIds: idsToDelete.toSet(),
          isGroup: isGroup,
        );
        if (fallback != null) {
          _emit(NavigateToSessionEvent(
            channelId: fallback,
            agentId: isGroup ? null : agentId,
            agentName: isGroup ? null : agentName,
            agentAvatar: isGroup ? null : agentAvatar,
            embedded: embedded,
            // 删完当前会话自动补位到剩下的某条，不是人工点选。
            manualActivation: false,
          ));
        } else if (!isGroup) {
          // 最后一个单聊会话：开一个空会话，避免停在已删除的 channel 上。
          await createNewSession(manualActivation: false);
        }
      }

      _emit(ShowSnackBarEvent('chat_batchDeleteSuccess:${idsToDelete.length}'));
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearSessionFailed:$e'));
    }
  }

  /// 删掉当前正在看的会话后，该打开哪一条。
  ///
  /// 单聊按最近活跃挑一条剩余会话；一条不剩则返回 null，由调用方新建。
  /// 群聊优先其余子会话，否则回到群本身（群根不会被删）。
  Future<String?> _channelToOpenAfterDelete({
    required Set<String> deletedIds,
    required bool isGroup,
  }) async {
    if (isGroup) {
      final parentGroupId = groupChannel?.groupFamilyId;
      if (parentGroupId == null || deletedIds.contains(parentGroupId)) {
        return null;
      }
      final sessions =
          await chatService.getGroupSessions(parentGroupId: parentGroupId);
      for (final session in sessions) {
        if (deletedIds.contains(session.id)) continue;
        if (session.parentGroupId == null) continue;
        return session.id;
      }
      return parentGroupId;
    }

    if (agentId == null) return null;
    final sessions = await chatService.getAgentSessions(agentId: agentId!);
    for (final session in sessions) {
      if (!deletedIds.contains(session.id)) return session.id;
    }
    return null;
  }
}
