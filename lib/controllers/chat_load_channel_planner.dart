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

/// 进页时怎么处理「主机那一页历史」（见 `ChatController.loadMessages`）。
enum ChatHostHistoryAction {
  /// 主机一定没有这条会话 —— 连读都不用读。
  skip,

  /// 本机已有内容：主机那一页回来再合并，不挡任何东西。
  pullInBackground,

  /// 本机是空的：等主机那一页回来再决定要不要显示「还没有消息」。
  ///
  /// 只压住空状态，**不**锁输入框——外网代理下这一趟能走好几秒。
  pullAndWait,
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

  /// 进页要不要回主机读这一页历史，以及要不要等它。
  ///
  /// [hostHasNoRecord] 由调用方判定：本机刚建、还没往主机发过东西的会话，
  /// 主机侧一定没有记录（见 `ChatService.isFreshLocalChannel`）。
  static ChatHostHistoryAction decideHostHistory({
    required bool hasLocalMessages,
    required bool hostHasNoRecord,
  }) {
    if (hostHasNoRecord) return ChatHostHistoryAction.skip;
    if (hasLocalMessages) return ChatHostHistoryAction.pullInBackground;
    return ChatHostHistoryAction.pullAndWait;
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
