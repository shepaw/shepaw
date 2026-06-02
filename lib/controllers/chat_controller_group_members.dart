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

    await localDatabaseService.addChannelMember(currentChannelId!, agent.id);

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: true,
    );
    messages.add(systemMsg);
    messageIdMap[systemMsg.id] = systemMsg;
    _notify();
    _emit(RequestScrollToBottomEvent());

    await refreshGroupMembers();
  }

  Future<void> removeGroupMember(RemoteAgent agent) async {
    if (currentChannelId == null) return;

    await localDatabaseService.removeChannelMember(currentChannelId!, agent.id);

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: false,
    );
    messages.add(systemMsg);
    messageIdMap[systemMsg.id] = systemMsg;
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
