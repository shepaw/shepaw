import 'package:uuid/uuid.dart';
import '../../models/channel.dart';
import '../../storage/group_workspace_service.dart';
import '../local_database_service.dart';
import '../acp_agent_connection.dart';
import '../inference_log_service.dart';
import 'group_member_session_service.dart';

/// Manages group chat sessions (create, list, clear, reset).
class GroupSessionService {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final Map<String, ACPAgentConnection> _acpConnections;
  final void Function(String channelId) notifyChannelUpdate;
  late final GroupMemberSessionService _memberSessions =
      GroupMemberSessionService(_db);

  GroupSessionService({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, ACPAgentConnection> acpConnections,
    required this.notifyChannelUpdate,
  })  : _db = db,
        _uuid = uuid,
        _acpConnections = acpConnections;

  /// Create a new group session with the same members and name as the original group.
  ///
  /// When [sourceSheChannelId] is set, the new session is bound to that She↔user
  /// DM so She-triggered work does not land in the group's current open chat.
  Future<String> createNewGroupSession({
    required String channelId,
    required String userId,
    String? sourceSheChannelId,
  }) async {
    final currentChannel = await _db.getChannelById(channelId);
    if (currentChannel == null) throw Exception('Channel not found');

    final parentGroupId = currentChannel.groupFamilyId;
    final newChannelId = 'group_${_uuid.v4()}';

    final channel = Channel(
      id: newChannelId,
      name: currentChannel.name,
      type: 'group',
      members: currentChannel.members,
      description: currentChannel.description,
      isPrivate: currentChannel.isPrivate,
      parentGroupId: parentGroupId,
      sourceSheChannelId: sourceSheChannelId,
      systemPrompt: currentChannel.systemPrompt,
      maxLoopRounds: currentChannel.maxLoopRounds,
      mentionMode: currentChannel.mentionMode,
      flowMode: currentChannel.flowMode,
      enableStageGate: currentChannel.enableStageGate,
    );
    await _db.createChannel(channel, userId);
    // Each member gets a fresh bound DM for this new group session.
    await _memberSessions.ensureMemberSessionsForGroup(
      groupChannel: channel,
      userId: userId,
    );
    // 群工作空间按群家族归属（幂等补缺：父群已建则复用，子会话共享同一空间根）。
    await GroupWorkspaceService.instance.ensureGroupWorkspace(
      groupId: parentGroupId,
      members: [
        for (final m in channel.members)
          if (m.isAgent) (agentId: m.id, role: m.role),
      ],
    );
    notifyChannelUpdate(newChannelId);
    return newChannelId;
  }

  /// Ensure a group session bound to [sheChannelId] for the family of [channelId].
  ///
  /// Reuses an existing bound session when present; otherwise creates a new
  /// child session so She-triggered sends do not affect the group's current chat.
  Future<String> ensureSheBoundGroupSession({
    required String channelId,
    required String sheChannelId,
    required String userId,
  }) async {
    final current = await _db.getChannelById(channelId);
    if (current == null || !current.isGroup) {
      throw Exception('Group channel not found: $channelId');
    }
    final familyId = current.groupFamilyId;
    final existing = await _db.findSheBoundGroupSession(
      sheChannelId: sheChannelId,
      groupFamilyId: familyId,
    );
    if (existing != null) return existing.id;

    return createNewGroupSession(
      channelId: familyId,
      userId: userId,
      sourceSheChannelId: sheChannelId,
    );
  }

  /// When She opens a new DM session, fork a new bound group session for each
  /// group family that was linked to [oldSheChannelId].
  Future<List<String>> cascadeSheBoundGroupSessions({
    required String oldSheChannelId,
    required String newSheChannelId,
    required String userId,
  }) async {
    final bound = await _db.getSheBoundGroupSessions(oldSheChannelId);
    final seenFamilies = <String>{};
    final created = <String>[];
    for (final session in bound) {
      final familyId = session.groupFamilyId;
      if (!seenFamilies.add(familyId)) continue;
      final already = await _db.findSheBoundGroupSession(
        sheChannelId: newSheChannelId,
        groupFamilyId: familyId,
      );
      if (already != null) continue;
      final id = await createNewGroupSession(
        channelId: familyId,
        userId: userId,
        sourceSheChannelId: newSheChannelId,
      );
      created.add(id);
    }
    return created;
  }

  /// Get all sessions for a group (by parentGroupId).
  Future<List<Channel>> getGroupSessions({required String parentGroupId}) async {
    return await _db.getGroupSessions(parentGroupId);
  }

  /// Clear current group session history: send /reset to all connected agents, delete messages.
  Future<void> clearGroupSessionHistory({
    required String channelId,
    required List<String> agentIds,
  }) async {
    for (final agentId in agentIds) {
      final memberSessionId = GroupMemberSessionService.memberSessionId(
        channelId,
        agentId,
      );
      final connection = _acpConnections[agentId];
      if (connection != null && connection.isConnected) {
        try {
          await connection.sendChatMessage(
            taskId: _uuid.v4(),
            sessionId: memberSessionId,
            message: '/reset',
            userId: 'user',
            messageId: _uuid.v4(),
          );
        } catch (_) {}
      }
    }

    await _db.deleteChannelMessages(channelId);
    await _memberSessions.clearMemberSessionMessagesForGroupChannel(channelId);
    InferenceLogService.instance.removeByChannel(channelId);
    notifyChannelUpdate(channelId);
  }

  /// Clear all group sessions: send /reset to all connected agents, delete all session messages.
  Future<void> clearAllGroupSessions({
    required String parentGroupId,
    required String currentChannelId,
    required List<String> agentIds,
  }) async {
    for (final agentId in agentIds) {
      final memberSessionId = GroupMemberSessionService.memberSessionId(
        currentChannelId,
        agentId,
      );
      final connection = _acpConnections[agentId];
      if (connection != null && connection.isConnected) {
        try {
          await connection.sendChatMessage(
            taskId: _uuid.v4(),
            sessionId: memberSessionId,
            message: '/reset-all',
            userId: 'user',
            messageId: _uuid.v4(),
          );
        } catch (_) {}
      }
    }

    final sessions = await _db.getGroupSessions(parentGroupId);
    for (final session in sessions) {
      await _memberSessions.deleteMemberSessionsForGroupChannel(session.id);
      await _db.deleteChannelMessages(session.id);
      if (session.id != parentGroupId) {
        await _db.deleteChannel(session.id);
      }
    }

    // Ensure parent channel still exists
    final parentChannel = await _db.getChannelById(parentGroupId);
    if (parentChannel == null && sessions.isNotEmpty) {
      final firstSession = sessions.first;
      final channel = Channel(
        id: parentGroupId,
        name: firstSession.name,
        type: 'group',
        members: firstSession.members,
        description: firstSession.description,
        isPrivate: firstSession.isPrivate,
        systemPrompt: firstSession.systemPrompt,
        maxLoopRounds: firstSession.maxLoopRounds,
      );
      await _db.createChannel(channel, 'user');
    }

    // Recreate bound member sessions for the surviving parent session.
    final surviving = await _db.getChannelById(parentGroupId);
    if (surviving != null) {
      await _memberSessions.ensureMemberSessionsForGroup(
        groupChannel: surviving,
        userId: 'user',
      );
    }

    notifyChannelUpdate(parentGroupId);
  }
}
