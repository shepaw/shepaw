import 'package:sqflite/sqflite.dart';
import '../../identity/services/sync_agent_fetch_service.dart';
import '../../identity/services/sync_local_write_hook.dart';
import '../../models/remote_agent.dart' as remote_agent;
import '../local_database_service.dart';

/// 远端助手（RemoteAgent）相关的数据访问层。
extension RemoteAgentDao on LocalDatabaseService {
  /// 创建远端助手
  Future<void> createRemoteAgent(remote_agent.RemoteAgent agent) async {
    final db = await database;
    await db.insert(
      'agents',
      agent.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final row = await getAgentRowById(agent.id);
    if (row != null) {
      SyncLocalWriteHook.onAgentUpserted(row);
    }
  }

  /// 获取所有远端助手
  Future<List<remote_agent.RemoteAgent>> getAllRemoteAgents() async {
    final db = await database;
    final results = await db.query('agents', orderBy: 'is_pinned DESC, created_at DESC');
    return results.map((map) => remote_agent.RemoteAgent.fromMap(map)).toList();
  }

  /// 根据 ID 获取远端助手（App 可自动从 Primary 按需拉取）。
  Future<remote_agent.RemoteAgent?> getRemoteAgentById(String id, {bool fetchRemote = true}) async {
    final db = await database;
    final results = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    if (results.isNotEmpty) {
      return remote_agent.RemoteAgent.fromMap(results.first);
    }
    if (!fetchRemote) return null;

    final row = await SyncAgentFetchService.instance.fetchAgentRow(id);
    if (row == null) return null;
    return remote_agent.RemoteAgent.fromMap(row);
  }

  /// 根据 Token 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByToken(String token) async {
    final db = await database;
    final results = await db.query('agents', where: 'token = ?', whereArgs: [token]);
    return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
  }

  /// 根据 Endpoint 获取远端助手
  Future<remote_agent.RemoteAgent?> getRemoteAgentByEndpoint(String endpoint) async {
    final db = await database;
    final results = await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
    return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
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
      final results = await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
      return results.isEmpty ? null : remote_agent.RemoteAgent.fromMap(results.first);
    }
    
    // 获取所有指定 endpoint 的 agents
    final results = await db.query('agents', where: 'endpoint = ?', whereArgs: [endpoint]);
    if (results.isEmpty) return null;
    
    // 检查是否有匹配的 agentId
    for (final result in results) {
      final agent = remote_agent.RemoteAgent.fromMap(result);
      final targetAgentId = agent.metadata['target_agent_id'] as String?;
      
      if (targetAgentId == agentId) {
        return agent;
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
    return results.map((map) => remote_agent.RemoteAgent.fromMap(map)).toList();
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

    final row = await getAgentRowById(agent.id);
    if (row != null) {
      SyncLocalWriteHook.onAgentUpserted(row);
    }
  }

  /// 更新远端助手状态
  Future<void> updateRemoteAgentStatus(String agentId, String status, {int? connectedAt}) async {
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

  /// 删除远端助手
  Future<void> deleteRemoteAgent(String id) async {
    final db = await database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
    SyncLocalWriteHook.onAgentDeleted(id);
  }
}
