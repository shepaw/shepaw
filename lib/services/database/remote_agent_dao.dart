import 'package:sqflite/sqflite.dart';
import '../../models/remote_agent.dart' as remote_agent;
import '../local_database_service.dart';
import '../she_service.dart';

/// 远端助手（RemoteAgent）相关的数据访问层。
extension RemoteAgentDao on LocalDatabaseService {
  /// 创建远端助手
  Future<void> createRemoteAgent(remote_agent.RemoteAgent agent) async {
    final db = await database;
    await db.insert(
      'agents',
      agent.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// 获取所有远端助手
  Future<List<remote_agent.RemoteAgent>> getAllRemoteAgents() async {
    final db = await database;
    final results =
        await db.query('agents', orderBy: 'is_pinned DESC, created_at DESC');
    return results
        .map((map) => _withSheAvatar(remote_agent.RemoteAgent.fromMap(map)))
        .toList();
  }

  /// 根据 ID 获取远端助手。
  ///
  /// [presentSheAvatar] 为 false 时返回库里的原始头像，供启动迁移判断旧爪印。
  /// 界面读取保持默认，惜宝一律显示灵宠图。
  Future<remote_agent.RemoteAgent?> getRemoteAgentById(
    String id, {
    bool presentSheAvatar = true,
  }) async {
    final db = await database;
    final results = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    final agent = remote_agent.RemoteAgent.fromMap(results.first);
    if (!presentSheAvatar) return agent;
    return _withSheAvatar(agent);
  }

  /// 根据 Token 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByToken(String token) async {
    final db = await database;
    final results =
        await db.query('agents', where: 'token = ?', whereArgs: [token]);
    return results.isEmpty
        ? null
        : _withSheAvatar(remote_agent.RemoteAgent.fromMap(results.first));
  }

  /// 根据 Endpoint 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByEndpoint(
      String endpoint) async {
    final db = await database;
    final results =
        await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
    return results.isEmpty
        ? null
        : _withSheAvatar(remote_agent.RemoteAgent.fromMap(results.first));
  }

  /// 根据 Endpoint 和 Agent ID 获取远端助手
  ///
  /// 用于检查 (endpoint, agentId) 组合是否已存在
  /// 当 agentId 为空时，仅检查 endpoint
  /// 当 agentId 不为空时，检查 endpoint + metadata['target_agent_id'] 的组合
  Future<remote_agent.RemoteAgent?> getRemoteAgentByEndpointAndAgentId(
    String endpoint, {
    String? agentId,
  }) async {
    final db = await database;

    // 如果没有提供 agentId，仅按 endpoint 查询
    if (agentId == null || agentId.isEmpty) {
      final results = await db
          .query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
      return results.isEmpty
          ? null
          : _withSheAvatar(remote_agent.RemoteAgent.fromMap(results.first));
    }

    // 获取所有指定 endpoint 的 agents
    final results =
        await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
    if (results.isEmpty) return null;

    // 检查是否有匹配的 agentId
    for (final result in results) {
      final agent = remote_agent.RemoteAgent.fromMap(result);
      final targetAgentId = agent.metadata['target_agent_id'] as String?;

      if (targetAgentId == agentId) {
        return _withSheAvatar(agent);
      }
    }

    return null;
  }

  /// 获取所有在线的远端助手
  Future<List<remote_agent.RemoteAgent>> getOnlineRemoteAgents() async {
    final db = await database;
    final results = await db.query(
      'agents',
      where: 'status = ?',
      whereArgs: ['online'],
      orderBy: 'connected_at DESC',
    );
    return results
        .map((map) => _withSheAvatar(remote_agent.RemoteAgent.fromMap(map)))
        .toList();
  }

  /// 更新远端助手
  Future<void> updateRemoteAgent(remote_agent.RemoteAgent agent) async {
    final db = await database;
    await db.update(
      'agents',
      agent.toMap(),
      where: 'id = ?',
      whereArgs: [agent.id],
    );
  }

  /// 更新远端助手状态
  Future<void> updateRemoteAgentStatus(String agentId, String status,
      {int? connectedAt}) async {
    final db = await database;
    final updateData = {
      'status': status,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };

    if (connectedAt != null) {
      updateData['connected_at'] = connectedAt;
    }

    await db.update(
      'agents',
      updateData,
      where: 'id = ?',
      whereArgs: [agentId],
    );
  }

  /// 更新远端助手心跳
  Future<void> updateRemoteAgentHeartbeat(String agentId) async {
    final db = await database;
    await db.update(
      'agents',
      {
        'last_heartbeat': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [agentId],
    );
  }

  /// 删除远端助手，并清掉它的元数据缓存。
  Future<void> deleteRemoteAgent(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('agents', where: 'id = ?', whereArgs: [id]);
      await txn.delete(
        'peer_agent_meta_cache',
        where: 'agent_id = ?',
        whereArgs: [id],
      );
    });
    onRemoteAgentDeleted?.call(id);
  }
}

/// 惜宝读出来就换成灵宠图，避免会话列表继续显示库里的旧爪印。
remote_agent.RemoteAgent _withSheAvatar(remote_agent.RemoteAgent agent) {
  final avatar = SheService.displayAvatar(
    id: agent.id,
    stored: agent.avatar,
    metadata: agent.metadata,
  );
  if (avatar == agent.avatar) return agent;
  return agent.copyWith(avatar: avatar);
}
