part of 'chat_controller.dart';

// ---------------------------------------------------------------------------
// Group member management
//
// 群组成员的增删与成员信息刷新。这些方法仅被 UI 调用，内部仅相互调用
// （addGroupMember/removeGroupMember/saveMemberGroupBio → refreshGroupMembers），
// 不被控制器核心逻辑回调，因此拆分为挂载在 [_ChatControllerBase] 上的 mixin。
// ---------------------------------------------------------------------------

mixin _GroupMemberOps on _ChatControllerBase {
  Future<void> addGroupMember(RemoteAgent agent) async {
    if (currentChannelId == null) return;

    // She joins as admin by default when added to a group.
    final role = agent.isShe ? 'admin' : 'member';
    await localDatabaseService.addChannelMember(
      currentChannelId!,
      agent.id,
      role: role,
    );

    if (role == 'admin') {
      final parentGroupId =
          groupChannel?.groupFamilyId ?? currentChannelId!;
      final sessions =
          await localDatabaseService.getGroupSessions(parentGroupId);
      final previousAdminId = groupAdminAgentId;
      for (final session in sessions) {
        if (previousAdminId != null && previousAdminId != agent.id) {
          await localDatabaseService.updateChannelMemberRole(
            session.id,
            previousAdminId,
            'member',
          );
        }
        await localDatabaseService.updateChannelMemberRole(
          session.id,
          agent.id,
          'admin',
        );
      }
    }

    final channel = await localDatabaseService.getChannelById(currentChannelId!);
    if (channel != null) {
      await GroupMemberSessionService(localDatabaseService).ensureMemberSession(
        groupChannel: channel,
        agentId: agent.id,
        userId: getUserId(),
      );
    }

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: true,
    );
    // notifyGroupMembershipChange 内部已触发 notifyChannelUpdate → 群模式会
    // reconcile（messages 被 DB 列表整体替换）。若 reconcile 先于这里的
    // 手动插入完成，systemMsg 已在列表里，再 add 会多出重复气泡——按 id 去重。
    if (!messageIdMap.containsKey(systemMsg.id)) {
      messages.add(systemMsg);
      messageIdMap[systemMsg.id] = systemMsg;
    }
    _notify();
    _emit(RequestScrollToBottomEvent());

    await refreshGroupMembers();
  }

  Future<void> removeGroupMember(RemoteAgent agent) async {
    if (currentChannelId == null) return;

    await localDatabaseService.removeChannelMember(currentChannelId!, agent.id);
    await GroupMemberSessionService(localDatabaseService).deleteMemberSession(
      groupChannelId: currentChannelId!,
      agentId: agent.id,
    );

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: false,
    );
    // 与 addGroupMember 同理：notifyChannelUpdate 触发的 reconcile 可能已把
    // systemMsg 并入列表，按 id 去重避免重复气泡。
    if (!messageIdMap.containsKey(systemMsg.id)) {
      messages.add(systemMsg);
      messageIdMap[systemMsg.id] = systemMsg;
    }
    _notify();
    _emit(RequestScrollToBottomEvent());

    await refreshGroupMembers();
  }

  Future<void> refreshGroupMembers() async {
    if (currentChannelId == null) return;
    final userId = getUserId();

    final channel = await localDatabaseService.getChannelById(currentChannelId!);
    final memberIds = await localDatabaseService.getChannelMemberIds(currentChannelId!);
    final agentIdsList = memberIds.where((id) => id != userId && id != 'user').toList();
    final agents = <RemoteAgent>[];
    for (final aid in agentIdsList) {
      final agent = await localDatabaseService.getRemoteAgentById(aid);
      if (agent != null) agents.add(agent);
    }

    groupAgents = agents;
    groupChannel = channel;
    groupAdminAgentId = channel?.adminAgentId;
    await _refreshWorkspaceUris();
    _notify();
  }

  Future<List<ChannelMember>> saveMemberGroupBio(RemoteAgent agent, String? newGroupBio) async {
    if (currentChannelId == null) return groupChannel?.members ?? [];

    final parentGroupId = groupChannel?.groupFamilyId ?? currentChannelId!;
    final sessions = await localDatabaseService.getGroupSessions(parentGroupId);
    for (final session in sessions) {
      await localDatabaseService.updateChannelMemberGroupBio(session.id, agent.id, newGroupBio);
    }

    await refreshGroupMembers();
    return groupChannel?.members ?? [];
  }
}
