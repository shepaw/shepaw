import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';

/// 管理 She 与 agent 往来（agents.chat / agents.dispatch）的绑定 DM 会话。
///
/// 与 [GroupMemberSessionService] 同一思路：She 发起的对话不得复用用户与
/// 该 agent 的普通单聊（peer/ACP 的 session_id 与本地上下文都会被污染）。
/// 每个 She↔用户 会话与目标 agent 对应一个独立绑定 DM（`source_she_channel_id`
/// 指向 She 会话），用户侧只读展示（类似群成员绑定会话）。
class SheRelaySessionService {
  final LocalDatabaseService _db;

  SheRelaySessionService([LocalDatabaseService? db])
      : _db = db ?? LocalDatabaseService();

  static const _tag = 'SheRelaySession';

  /// 确定性的会话 id：（She↔用户 频道, agent）→ 绑定 DM。
  static String relaySessionId(String sheChannelId, String agentId) =>
      'shed_${sheChannelId}__$agentId';

  /// 会话标题，让用户在该 agent 的会话列表里一眼认出这是 She 的中转会话。
  static String relaySessionTitle(String agentName) => 'She · $agentName';

  /// 确保（并返回）She↔用户 频道 [sheChannelId] 与 [agent] 的绑定 DM 会话。
  Future<String> ensureRelaySession({
    required String sheChannelId,
    required RemoteAgent agent,
  }) async {
    final sessionId = relaySessionId(sheChannelId, agent.id);
    final title = relaySessionTitle(agent.name);

    final existing = await _db.getChannelById(sessionId);
    if (existing != null) {
      if (existing.name != title ||
          existing.sourceSheChannelId != sheChannelId) {
        await _db.updateChannel(
          existing.copyWith(
            name: title,
            sourceSheChannelId: sheChannelId,
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
          id: LocalUserIdentity.id,
          type: 'user',
          role: 'member',
          joinedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ChannelMember(
          id: agent.id,
          type: 'agent',
          role: 'member',
          joinedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      isPrivate: true,
      sourceSheChannelId: sheChannelId,
      description: '来自 She 的会话',
    );

    try {
      await _db.createChannel(channel, LocalUserIdentity.id);
      await _db.createMessage(
        id: 'sys_shed_${sessionId}_${DateTime.now().millisecondsSinceEpoch}',
        channelId: sessionId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: '本会话由 She 自动创建，用于 She 与 ${agent.name} 的对话与任务派发，'
            '与你的普通单聊互不影响。此处为只读记录，不能直接对话。',
        messageType: 'system',
      );
      LoggerService().debug(
        'Created She-bound relay session $sessionId for agent ${agent.id}',
        tag: _tag,
      );
    } catch (e) {
      // Concurrent ensure: another caller may have created it.
      final raced = await _db.getChannelById(sessionId);
      if (raced == null) {
        LoggerService().warning(
          'Failed to create She-bound relay session $sessionId: $e',
          tag: _tag,
        );
        rethrow;
      }
    }

    return sessionId;
  }

  /// 删除绑定到指定 She↔用户 会话的所有中转 DM（She 会话被删除时级联）。
  Future<void> deleteRelaySessionsForSheChannel(String sheChannelId) async {
    final sessions = await _db.getSheBoundSessions(sheChannelId);
    for (final session in sessions) {
      await _db.deleteChannelMessages(session.id);
      await _db.deleteChannel(session.id);
    }
  }
}
