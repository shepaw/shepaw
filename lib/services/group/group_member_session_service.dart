import 'dart:convert';

import '../../models/channel.dart';
import '../local_database_service.dart';
import '../logger_service.dart';

/// Manages per-member DM sessions that bind 1:1 to a group chat session.
///
/// Group participation must not reuse an agent's personal DM session (peer/ACP
/// `session_id` would otherwise pollute 1:1 context). Each group channel gets a
/// dedicated member DM per agent; creating a new group session creates a new
/// bound member session for every member.
class GroupMemberSessionService {
  final LocalDatabaseService _db;

  GroupMemberSessionService(this._db);

  static const _tag = 'GroupMemberSession';

  /// Deterministic channel id for the (group session, agent) pair.
  static String memberSessionId(String groupChannelId, String agentId) =>
      'gmd_${groupChannelId}__$agentId';

  /// Display title so the session is recognizable in the agent's session list.
  static String memberSessionTitle({
    required String groupName,
    required String groupChannelId,
    String? parentGroupId,
  }) {
    final safeName = groupName.trim().isEmpty ? 'Group' : groupName.trim();
    if (parentGroupId == null || parentGroupId.isEmpty) {
      return 'Group · $safeName';
    }
    final short = groupChannelId.length > 6
        ? groupChannelId.substring(groupChannelId.length - 6)
        : groupChannelId;
    return 'Group · $safeName (#$short)';
  }

  /// Ensure every agent member of [groupChannel] has a bound DM session.
  Future<void> ensureMemberSessionsForGroup({
    required Channel groupChannel,
    required String userId,
  }) async {
    for (final member in groupChannel.members) {
      if (!member.isAgent) continue;
      await ensureMemberSession(
        groupChannel: groupChannel,
        agentId: member.id,
        userId: userId,
      );
    }
  }

  /// Ensure (and return) the bound member DM for one agent in a group session.
  Future<String> ensureMemberSession({
    required Channel groupChannel,
    required String agentId,
    required String userId,
  }) async {
    final groupChannelId = groupChannel.id;
    final sessionId = memberSessionId(groupChannelId, agentId);
    final title = memberSessionTitle(
      groupName: groupChannel.name,
      groupChannelId: groupChannelId,
      parentGroupId: groupChannel.parentGroupId,
    );

    final existing = await _db.getChannelById(sessionId);
    if (existing != null) {
      if (existing.name != title ||
          existing.sourceGroupChannelId != groupChannelId) {
        await _db.updateChannel(
          existing.copyWith(
            name: title,
            sourceGroupChannelId: groupChannelId,
          ),
        );
      }
      return sessionId;
    }

    final channel = Channel(
      id: sessionId,
      name: title,
      type: 'dm',
      members: [
        ChannelMember(
          id: userId,
          type: 'user',
          role: 'member',
          joinedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ChannelMember(
          id: agentId,
          type: 'agent',
          role: 'member',
          joinedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      isPrivate: true,
      sourceGroupChannelId: groupChannelId,
      description: '来自群聊「${groupChannel.name}」',
    );

    try {
      await _db.createChannel(channel, userId);
      await _db.createMessage(
        id: 'sys_gmd_${sessionId}_${DateTime.now().millisecondsSinceEpoch}',
        channelId: sessionId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content:
            '本会话由群聊「${groupChannel.name}」自动创建，与该群会话一一对应。'
            '此处记录对该成员的每次调用（请求与回复），不会影响普通单聊上下文。',
        messageType: 'system',
      );
      LoggerService().debug(
        'Created group-bound member session $sessionId for agent $agentId',
        tag: _tag,
      );
    } catch (e) {
      // Concurrent ensure: another caller may have created it.
      final raced = await _db.getChannelById(sessionId);
      if (raced == null) {
        LoggerService().warning(
          'Failed to create group-bound member session $sessionId: $e',
          tag: _tag,
        );
        rethrow;
      }
    }

    return sessionId;
  }

  /// Resolve the bound session id for an agent in a group channel (create if missing).
  Future<String> resolveMemberSessionId({
    required String groupChannelId,
    required String agentId,
    required String userId,
  }) async {
    final groupChannel = await _db.getChannelById(groupChannelId);
    if (groupChannel == null || !groupChannel.isGroup) {
      // Fallback: still use a deterministic id so peer/ACP stay isolated.
      return memberSessionId(groupChannelId, agentId);
    }
    return ensureMemberSession(
      groupChannel: groupChannel,
      agentId: agentId,
      userId: userId,
    );
  }

  /// Delete all member DMs bound to a specific group session.
  Future<void> deleteMemberSessionsForGroupChannel(String groupChannelId) async {
    final sessions = await _db.getMemberSessionsForGroupChannel(groupChannelId);
    for (final session in sessions) {
      await _db.deleteChannel(session.id);
    }
  }

  /// Delete the bound member DM for one agent in a group session.
  Future<void> deleteMemberSession({
    required String groupChannelId,
    required String agentId,
  }) async {
    final sessionId = memberSessionId(groupChannelId, agentId);
    final existing = await _db.getChannelById(sessionId);
    if (existing != null) {
      await _db.deleteChannel(sessionId);
    }
  }

  /// Refresh titles when a group is renamed (all sessions in the family).
  Future<void> syncTitlesForGroupFamily({
    required String parentGroupId,
    required String groupName,
  }) async {
    final groupSessions = await _db.getGroupSessions(parentGroupId);
    for (final groupSession in groupSessions) {
      final memberSessions =
          await _db.getMemberSessionsForGroupChannel(groupSession.id);
      for (final memberSession in memberSessions) {
        final title = memberSessionTitle(
          groupName: groupName,
          groupChannelId: groupSession.id,
          parentGroupId: groupSession.parentGroupId,
        );
        if (memberSession.name != title) {
          await _db.updateChannel(memberSession.copyWith(name: title));
        }
      }
    }
  }

  /// Append one group turn into the bound member session: the inbound request
  /// (what was sent to this agent) plus the agent's reply — matching the
  /// remote peer/ACP session shape (request + response), without other members.
  Future<void> mirrorTurn({
    required String memberSessionId,
    required String groupChannelId,
    required String userId,
    required String userName,
    required String inboundContent,
    required String agentId,
    required String agentName,
    required String replyContent,
    Map<String, dynamic>? replyMetadata,
    String? sourceMessageId,
  }) async {
    final existing = await _db.getChannelById(memberSessionId);
    if (existing == null) return;

    final turnKey = sourceMessageId ??
        '${DateTime.now().microsecondsSinceEpoch}';
    final baseMeta = <String, dynamic>{
      'mirrored_from_group': groupChannelId,
      if (sourceMessageId != null) 'source_message_id': sourceMessageId,
    };

    try {
      final inbound = inboundContent.trim();
      if (inbound.isNotEmpty) {
        await _db.createMessage(
          id: 'gmdreq_$turnKey',
          channelId: memberSessionId,
          senderId: userId,
          senderType: 'user',
          senderName: userName,
          content: inbound,
          messageType: 'text',
          metadata: {
            ...baseMeta,
            'group_turn_role': 'request',
          },
        );
      }

      final reply = replyContent.trim();
      if (reply.isNotEmpty) {
        await _db.createMessage(
          id: 'gmdmsg_$turnKey',
          channelId: memberSessionId,
          senderId: agentId,
          senderType: 'agent',
          senderName: agentName,
          content: reply,
          messageType: 'text',
          metadata: {
            if (replyMetadata != null) ...replyMetadata,
            ...baseMeta,
            'group_turn_role': 'reply',
          },
        );
      }

      await _db.touchChannelUpdatedAt(memberSessionId);
    } catch (e) {
      LoggerService().warning(
        'Failed to mirror group turn into $memberSessionId: $e',
        tag: _tag,
      );
    }
  }

  /// If the bound session has no agent messages yet, copy this agent's prior
  /// replies from the linked group session (legacy groups created before mirror).
  /// Request-side text is not recoverable from group history alone.
  Future<void> backfillAgentMessagesFromGroupIfNeeded({
    required String memberSessionId,
    required String groupChannelId,
    required String agentId,
  }) async {
    if (agentId.isEmpty) return;

    final existing = await _db.getChannelMessages(memberSessionId, limit: 100);
    final hasAgentMsg = existing.any((m) => m['sender_type'] == 'agent');
    if (hasAgentMsg) return;

    final groupMsgs =
        await _db.getChannelMessages(groupChannelId, limit: 500);
    // DAO returns newest-first; iterate oldest-first when copying.
    final agentMsgs = groupMsgs
        .where(
          (m) =>
              m['sender_id'] == agentId &&
              m['sender_type'] == 'agent' &&
              (m['message_type'] as String? ?? 'text') == 'text',
        )
        .toList()
        .reversed;

    for (final m in agentMsgs) {
      final sourceId = m['id'] as String?;
      final content = m['content'] as String? ?? '';
      if (content.isEmpty) continue;

      Map<String, dynamic>? metadata;
      final rawMeta = m['metadata'] as String?;
      if (rawMeta != null && rawMeta.isNotEmpty) {
        try {
          metadata = Map<String, dynamic>.from(jsonDecode(rawMeta) as Map);
        } catch (_) {}
      }

      await mirrorTurn(
        memberSessionId: memberSessionId,
        groupChannelId: groupChannelId,
        userId: 'user',
        userName: 'User',
        inboundContent: '',
        agentId: agentId,
        agentName: m['sender_name'] as String? ?? agentId,
        replyContent: content,
        replyMetadata: metadata,
        sourceMessageId: sourceId,
      );
    }
  }

  /// Clear mirrored history in every member session bound to [groupChannelId].
  Future<void> clearMemberSessionMessagesForGroupChannel(
    String groupChannelId,
  ) async {
    final sessions = await _db.getMemberSessionsForGroupChannel(groupChannelId);
    for (final session in sessions) {
      await _db.deleteChannelMessages(session.id);
    }
  }
}
