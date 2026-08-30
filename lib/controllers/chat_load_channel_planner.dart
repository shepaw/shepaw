import '../models/channel.dart';

/// How [ChatController.loadMessages] should obtain `currentChannelId`.
enum ChatLoadChannelAction {
  /// Already set — keep it.
  keepCurrent,

  /// Use [ChatController.initialChannelId].
  useInitial,

  /// Look up latest active channel for (user, agent) or generate one.
  resolveFromAgent,

  /// No channel and no agent — abort load.
  abort,
}

/// Pure bootstrap decisions for chat message loading.
class ChatLoadChannelPlanner {
  ChatLoadChannelPlanner._();

  static ChatLoadChannelAction decideChannel({
    required String? currentChannelId,
    required String? initialChannelId,
    required String? agentId,
  }) {
    if (currentChannelId != null) return ChatLoadChannelAction.keepCurrent;
    if (initialChannelId != null) return ChatLoadChannelAction.useInitial;
    if (agentId != null) return ChatLoadChannelAction.resolveFromAgent;
    return ChatLoadChannelAction.abort;
  }

  /// 会话面板 family key：群频道用 `group:{groupFamilyId}`，DM 用
  /// `dm:{agentId}`。[agentId] 是 DM 频道无 agent 成员行时的回退。
  /// 同一 key 的会话才允许在停靠面板里原位切换（见
  /// ChatScreen._switchPinnedSessionInPlace）。
  static String? sessionPanelKey(Channel channel, {String? agentId}) {
    if (channel.isGroup) {
      return 'group:${channel.groupFamilyId}';
    }
    final memberAgentId = firstAgentMemberId(channel) ?? agentId;
    return memberAgentId == null ? null : 'dm:$memberAgentId';
  }

  /// Agent member ids in a group channel (excludes the local user).
  static List<String> groupAgentMemberIds(Channel channel, String userId) {
    return channel.memberIds
        .where((id) => id != userId && id != 'user')
        .toList();
  }

  /// First agent member id, if any.
  static String? firstAgentMemberId(Channel channel) {
    for (final m in channel.members) {
      if (m.isAgent) return m.id;
    }
    return null;
  }
}
