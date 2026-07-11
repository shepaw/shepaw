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
