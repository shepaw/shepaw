import 'package:uuid/uuid.dart';
import '../../models/channel.dart';
import '../local_database_service.dart';
import '../acp_agent_connection.dart';
import '../inference_log_service.dart';
import '../logger_service.dart';

/// Manages group chat sessions (create, list, clear, reset).
class GroupSessionService {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final Map<String, ACPAgentConnection> _acpConnections;
  final void Function(String channelId) notifyChannelUpdate;

  GroupSessionService({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, ACPAgentConnection> acpConnections,
    required this.notifyChannelUpdate,
  })  : _db = db,
        _uuid = uuid,
        _acpConnections = acpConnections;

  /// Create a new group session with the same members and name as the original group.
  Future<String> createNewGroupSession({
    required String channelId,
    required String userId,
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
      systemPrompt: currentChannel.systemPrompt,
      maxLoopRounds: currentChannel.maxLoopRounds,
      mentionMode: currentChannel.mentionMode,
      flowMode: currentChannel.flowMode,
    );
    await _db.createChannel(channel, userId);
    return newChannelId;
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
      final connection = _acpConnections[agentId];
      if (connection != null && connection.isConnected) {
        try {
          await connection.sendChatMessage(
            taskId: _uuid.v4(),
            sessionId: channelId,
            message: '/reset',
            userId: 'user',
            messageId: _uuid.v4(),
          );
        } catch (_) {}
      }
    }

    await _db.deleteChannelMessages(channelId);
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
      final connection = _acpConnections[agentId];
      if (connection != null && connection.isConnected) {
        try {
          await connection.sendChatMessage(
            taskId: _uuid.v4(),
            sessionId: currentChannelId,
            message: '/reset-all',
            userId: 'user',
            messageId: _uuid.v4(),
          );
        } catch (_) {}
      }
    }

    final sessions = await _db.getGroupSessions(parentGroupId);
    for (final session in sessions) {
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

    notifyChannelUpdate(parentGroupId);
  }
}
