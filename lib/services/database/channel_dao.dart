import 'package:sqflite/sqflite.dart';
import '../../models/channel.dart';
import '../local_database_service.dart';

/// Channel / 成员 / 会话相关的数据访问层。
extension ChannelDao on LocalDatabaseService {
  /// 创建 Channel
  Future<void> createChannel(Channel channel, String createdBy) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.insert(
      'channels',
      {
        'id': channel.id,
        'name': channel.name,
        'description': channel.description,
        'type': channel.type,
        'avatar_path': channel.avatar,
        'is_private': channel.isPrivate ? 1 : 0,
        'parent_group_id': channel.parentGroupId,
        'system_prompt': channel.systemPrompt,
        'max_loop_rounds': channel.maxLoopRounds,
        'mention_mode': channel.mentionMode,
        'planning_mode': 0, // deprecated, kept for migration compatibility
        'flow_mode': channel.flowMode ? 1 : 0,
        'created_at': now,
        'updated_at': now,
        'created_by': createdBy,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // 添加成员（保留角色信息）
    for (final member in channel.members) {
      await addChannelMember(channel.id, member.id, role: member.role, groupBio: member.groupBio);
    }
  }

  /// 获取所有 Channel
  Future<List<Channel>> getAllChannels() async {
    final db = await database;
    final results = await db.query('channels', orderBy: 'created_at DESC');
    
    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 根据 ID 获取 Channel
  Future<Channel?> getChannelById(String id) async {
    final db = await database;
    final results = await db.query('channels', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;

    final members = await getChannelMembers(id);
    return _channelFromMap(results.first, members);
  }

  /// 更新 Channel
  Future<void> updateChannel(Channel channel) async {
    final db = await database;
    await db.update(
      'channels',
      {
        'name': channel.name,
        'description': channel.description,
        'type': channel.type,
        'avatar_path': channel.avatar,
        'is_private': channel.isPrivate ? 1 : 0,
        'system_prompt': channel.systemPrompt,
        'max_loop_rounds': channel.maxLoopRounds,
        'mention_mode': channel.mentionMode,
        'planning_mode': 0, // deprecated, kept for migration compatibility
        'flow_mode': channel.flowMode ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [channel.id],
    );
  }

  /// 更新 Channel 的 updated_at 时间戳
  Future<void> touchChannelUpdatedAt(String channelId) async {
    final db = await database;
    await db.update(
      'channels',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [channelId],
    );
  }

  /// 删除 Channel
  Future<void> deleteChannel(String id) async {
    final db = await database;
    await db.delete('channels', where: 'id = ?', whereArgs: [id]);
  }

  /// 添加 Channel 成员
  Future<void> addChannelMember(String channelId, String agentId, {String role = 'member', String? groupBio}) async {
    final db = await database;
    await db.insert(
      'channel_members',
      {
        'channel_id': channelId,
        'agent_id': agentId,
        'role': role,
        'group_bio': groupBio,
        'joined_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 更新 Channel 成员角色
  Future<void> updateChannelMemberRole(String channelId, String agentId, String role) async {
    final db = await database;
    await db.update(
      'channel_members',
      {'role': role},
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 更新 Channel 成员的群内能力描述
  Future<void> updateChannelMemberGroupBio(String channelId, String agentId, String? groupBio) async {
    final db = await database;
    await db.update(
      'channel_members',
      {'group_bio': groupBio},
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 移除 Channel 成员
  Future<void> removeChannelMember(String channelId, String agentId) async {
    final db = await database;
    await db.delete(
      'channel_members',
      where: 'channel_id = ? AND agent_id = ?',
      whereArgs: [channelId, agentId],
    );
  }

  /// 获取 Channel 成员 ID 列表
  Future<List<String>> getChannelMemberIds(String channelId) async {
    final db = await database;
    final results = await db.query(
      'channel_members',
      columns: ['agent_id'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    return results.map((r) => r['agent_id'] as String).toList();
  }

  /// 获取 Channel 成员（包含角色信息）
  Future<List<ChannelMember>> getChannelMembers(String channelId) async {
    final db = await database;
    final results = await db.query(
      'channel_members',
      columns: ['agent_id', 'role', 'group_bio', 'joined_at'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    return results.map((r) => ChannelMember(
      id: r['agent_id'] as String,
      type: 'agent',
      role: r['role'] as String? ?? 'member',
      groupBio: r['group_bio'] as String?,
      joinedAt: DateTime.tryParse(r['joined_at'] as String? ?? '')
              ?.millisecondsSinceEpoch ?? 0,
    )).toList();
  }

  /// 获取某 user 和 agent 之间最近活跃的 channel（按最新消息时间排序）
  Future<String?> getLatestActiveChannelForUserAndAgent(String userId, String agentId) async {
    final db = await database;
    // 查找同时包含 userId 和 agentId 的 dm channel，按最近访问时间排序
    final results = await db.rawQuery('''
      SELECT c.id FROM channels c
      INNER JOIN channel_members cm1 ON c.id = cm1.channel_id AND cm1.agent_id = ?
      INNER JOIN channel_members cm2 ON c.id = cm2.channel_id AND cm2.agent_id = ?
      WHERE c.type = 'dm'
      ORDER BY c.updated_at DESC
      LIMIT 1
    ''', [userId, agentId]);

    if (results.isEmpty) return null;
    return results.first['id'] as String;
  }

  /// 获取某个群聊的所有会话（包括原始群聊和所有子会话）
  Future<List<Channel>> getGroupSessions(String parentGroupId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.* FROM channels c
      WHERE c.type = 'group' AND (c.id = ? OR c.parent_group_id = ?)
      ORDER BY c.created_at DESC
    ''', [parentGroupId, parentGroupId]);

    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 获取某个群聊家族中最近活跃的会话（按 updated_at 排序）
  Future<String?> getLatestActiveGroupChannel(String parentGroupId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.id FROM channels c
      WHERE c.type = 'group' AND (c.id = ? OR c.parent_group_id = ?)
      ORDER BY c.updated_at DESC
      LIMIT 1
    ''', [parentGroupId, parentGroupId]);

    if (results.isEmpty) return null;
    return results.first['id'] as String;
  }

  /// 获取某 agent 参与的所有 dm 类型 channels
  Future<List<Channel>> getChannelsForAgent(String agentId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT c.* FROM channels c
      INNER JOIN channel_members cm ON c.id = cm.channel_id
      WHERE cm.agent_id = ? AND c.type = 'dm'
      ORDER BY c.updated_at DESC
    ''', [agentId]);

    List<Channel> channels = [];
    for (final map in results) {
      final members = await getChannelMembers(map['id'] as String);
      channels.add(_channelFromMap(map, members));
    }
    return channels;
  }

  /// 获取 channel 最新一条消息（用于会话列表预览）
  Future<Map<String, dynamic>?> getLatestChannelMessage(String channelId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 获取 channel 未读消息数（仅统计 agent 发送的未读消息）
  Future<int> getUnreadCountByChannel(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM messages WHERE channel_id = ? AND is_read = 0 AND sender_type != ?',
      [channelId, 'user'],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  /// 标记 channel 所有消息为已读
  Future<void> markChannelMessagesAsRead(String channelId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_read': 1},
      where: 'channel_id = ? AND is_read = 0',
      whereArgs: [channelId],
    );
  }
}

Channel _channelFromMap(Map<String, dynamic> map, List<ChannelMember> members) {
  return Channel(
    id: map['id'],
    name: map['name'],
    description: map['description'],
    type: map['type'],
    avatar: map['avatar_path'],
    members: members,
    isPrivate: map['is_private'] == 1,
    lastMessage: null,
    lastMessageTime: null,
    unreadCount: 0,
    parentGroupId: map['parent_group_id'] as String?,
    systemPrompt: map['system_prompt'] as String?,
    maxLoopRounds: map['max_loop_rounds'] as int?,
    mentionMode: map['mention_mode'] as String?,
    // planning_mode column kept for migration compatibility but no longer used
    flowMode: (map['flow_mode'] as int?) == 1,
  );
}
