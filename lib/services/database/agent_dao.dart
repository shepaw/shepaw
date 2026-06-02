import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../models/agent.dart';
import '../local_database_service.dart';

/// 本地 Agent 表的数据访问层。
///
/// 以 `extension` 形式挂载到 [LocalDatabaseService]，通过主文件 `export` 暴露，
/// 调用方仍只需 `import 'local_database_service.dart'`，无需感知本文件。
extension AgentDao on LocalDatabaseService {
  /// 创建 Agent
  Future<void> createAgent(Agent agent, String ownerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      'agents',
      {
        'id': agent.id,
        'name': agent.name,
        'avatar': agent.avatar,
        'bio': agent.description,
        'token': agent.metadata?['token'] ?? const Uuid().v4(),
        'endpoint': agent.metadata?['endpoint'] ?? '',
        'protocol': agent.metadata?['protocol'] ?? 'a2a',
        'connection_type': agent.metadata?['connection_type'] ?? 'http',
        'status': agent.status.state,
        'capabilities': jsonEncode(agent.capabilities),
        'metadata': jsonEncode(agent.metadata ?? {}),
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取所有 Agent
  Future<List<Agent>> getAllAgents() async {
    final db = await database;
    final results = await db.query('agents', orderBy: 'created_at DESC');
    return results.map((map) => _agentFromMap(map)).toList();
  }

  /// 根据 ID 获取 Agent
  Future<Agent?> getAgentById(String id) async {
    final db = await database;
    final results = await db.query('agents', where: 'id = ?', whereArgs: [id]);
    return results.isEmpty ? null : _agentFromMap(results.first);
  }

  /// 更新 Agent
  Future<void> updateAgent(Agent agent) async {
    final db = await database;
    await db.update(
      'agents',
      {
        'name': agent.name,
        'avatar': agent.avatar,
        'bio': agent.description,
        'status': agent.status.state,
        'capabilities': jsonEncode(agent.capabilities ?? []),
        'metadata': jsonEncode(agent.metadata ?? {}),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [agent.id],
    );
  }

  /// 删除 Agent
  Future<void> deleteAgent(String id) async {
    final db = await database;
    await db.delete('agents', where: 'id = ?', whereArgs: [id]);
  }
}

Agent _agentFromMap(Map<String, dynamic> map) {
  final metadata = map['metadata'] != null
      ? Map<String, dynamic>.from(jsonDecode(map['metadata']))
      : <String, dynamic>{};

  return Agent(
    id: map['id'] ?? '',
    name: map['name'] ?? 'Unknown Agent',
    avatar: map['avatar'] ?? '🤖',
    description: map['bio'],
    model: metadata['model'],
    systemPrompt: metadata['system_prompt'],
    temperature: metadata['temperature']?.toDouble(),
    maxTokens: metadata['max_tokens'],
    type: map['protocol'] ?? 'a2a',
    provider: AgentProvider(
      name: metadata['provider_name'] ?? 'Unknown',
      platform: map['protocol'] ?? 'unknown',
      type: metadata['provider_type'] ?? 'llm',
    ),
    status: AgentStatus(
      state: map['status'] ?? 'offline',
      connectedAt: map['connected_at'],
      lastHeartbeat: map['last_heartbeat'],
    ),
    capabilities: map['capabilities'] != null
        ? List<String>.from(jsonDecode(map['capabilities']))
        : [],
    metadata: metadata,
  );
}
