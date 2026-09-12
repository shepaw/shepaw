import '../models/channel.dart';

/// Utility functions for session/channel ID display.
class SessionUtils {
  SessionUtils._();

  /// 把消息内容拆成「第一句」与「剩余部分」，供会话列表两行同尺寸展示。
  ///
  /// 按中/英文句末标点（。！？…!?）或换行切分，[first] 含句末标点；
  /// 无句末标点时整段归 [first]，[rest] 为空。
  static ({String first, String rest}) splitFirstSentence(String text) {
    final trimmed = text.trim();
    final match = RegExp(r'[。！？…!?\n]').firstMatch(trimmed);
    if (match == null) return (first: trimmed, rest: '');
    final end = match.end;
    return (
      first: trimmed.substring(0, end).trim(),
      rest: trimmed.substring(end).trim(),
    );
  }

  /// 判断离开当前会话时是否需要自动删除（切换前调用）。
  ///
  /// 目标：清理「新建会话」误点击产生的空会话。仅当离开的会话满足：
  /// - 不是要切换到的目标会话（[nextChannelId]）；
  /// - 群聊下不是父群会话（家族根，[groupFamilyId]）；
  /// - DM 下不是默认会话（无时间戳的 `dm_userId_agentId`，
  ///   [defaultDmChannelId]），且是 `dm_` 形态的普通会话——不碰
  ///   `gmd_` 群成员会话、`psess_` 同步会话、`peer__` 入站会话等派生会话。
  static bool shouldPruneEmptySessionOnSwitch({
    required String currentChannelId,
    String? nextChannelId,
    required bool isGroupMode,
    String? groupFamilyId,
    String? defaultDmChannelId,
  }) {
    if (currentChannelId == nextChannelId) return false;
    if (isGroupMode) {
      // 父群会话是家族的根，即使为空也保留。
      if (groupFamilyId == null || currentChannelId == groupFamilyId) {
        return false;
      }
      return true;
    }
    // 默认会话是 agent 的兜底入口，即使为空也保留。
    if (defaultDmChannelId == null || currentChannelId == defaultDmChannelId) {
      return false;
    }
    return currentChannelId.startsWith('dm_');
  }

  /// Extract a short session identifier from a channelId for display.
  ///
  /// For group channels, optionally pass [groupChannel] to detect the default session.
  static String shortSessionId(String channelId, {Channel? groupChannel}) {
    // Group channels: use creation time from channel object if available
    if (groupChannel != null && groupChannel.isGroup) {
      if (groupChannel.parentGroupId == null && channelId == groupChannel.id) {
        return '#default';
      }
    }
    // Synced peer session: id is `psess_<remoteSessionId>` (see
    // kSyncedPeerSessionPrefix). Show the tail of the bound remote session id.
    const peerPrefix = 'psess_';
    if (channelId.startsWith(peerPrefix)) {
      final sid = sessionIdFromChannelId(channelId);
      final tail = sid.length > 6 ? sid.substring(sid.length - 6) : sid;
      return '#$tail';
    }
    // channelId format: dm_userId_agentId or dm_userId_agentId_timestamp
    //                   group_<uuid>
    final parts = channelId.split('_');
    if (parts.length > 3) {
      // DM with timestamp suffix
      return '#${parts.last.substring(parts.last.length > 6 ? parts.last.length - 6 : 0)}';
    }
    if (channelId.startsWith('group_') && parts.length == 2) {
      // group_<uuid> - show last 6 chars of uuid
      final uuid = parts[1];
      return '#${uuid.substring(uuid.length > 6 ? uuid.length - 6 : 0)}';
    }
    return '#default';
  }

  /// 上游 / 引擎侧 session id：已同步远端会话去掉 `psess_`，其余即 channel id。
  static String sessionIdFromChannelId(String channelId) {
    const peerPrefix = 'psess_';
    if (channelId.startsWith(peerPrefix)) {
      return channelId.substring(peerPrefix.length);
    }
    return channelId;
  }

  /// 复制/展示用的 channel id：群会话取家族根（群 id），群成员绑定 DM 取
  /// 来源群，普通单聊没有群，退回会话自身 id。
  static String familyChannelId(Channel session) {
    if (session.isGroup) return session.groupFamilyId;
    final bound = session.sourceGroupChannelId;
    if (bound != null && bound.isNotEmpty) return bound;
    return session.id;
  }

  /// Claude Code 本地斜杠命令（/model、/clear 等）注入的包装标签，
  /// 同步远端会话后可能残留在会话标题里，展示层需剔除。
  static const _kClaudeCommandTagPatterns = [
    r'<local-command-caveat>.*?</local-command-caveat>',
    r'<command-name>.*?</command-name>',
    r'<local-command-stdout>.*?</local-command-stdout>',
  ];

  /// 判断一段文本是否为 Claude Code 注入的本地命令伪消息
  /// （caveat / 命令名 / 命令输出）。这类内容不应作为会话标题或预览。
  static bool isClaudeCommandArtifact(String? text) {
    if (text == null) return false;
    final t = text.trim();
    return t.startsWith('<local-command-caveat>') ||
        t.startsWith('<command-name>') ||
        t.startsWith('<local-command-stdout>');
  }

  /// 剔除会话标题里由本地斜杠命令注入的标签及内容，折叠多余空白。
  ///
  /// 清理后为空返回 null，便于调用方回落默认名（如 'Session'）。
  static String? cleanClaudeSessionTitle(String? title) {
    if (title == null) return null;
    var s = title;
    for (final pattern in _kClaudeCommandTagPatterns) {
      s = s.replaceAll(RegExp(pattern, dotAll: true), '');
    }
    // 标题可能被截断导致标签未闭合，再兜底剔除一次裸标签。
    s = s.replaceAll(
      RegExp(
        r'</?(?:local-command-caveat|command-name|local-command-stdout)\b[^>]*>',
        dotAll: true,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isEmpty ? null : s;
  }
}
