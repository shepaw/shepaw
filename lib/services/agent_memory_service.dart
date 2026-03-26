import 'package:uuid/uuid.dart';
import '../models/agent_memory.dart';
import 'she_profile_database_service.dart';
import 'logger_service.dart';

/// Agent 记忆服务
/// 
/// 负责管理每个 Agent 的独立记忆系统：
/// - CRUD 操作（创建、读取、更新、删除记忆）
/// - 记忆导出（JSON / Markdown 格式）
/// - 记忆统计
/// 
/// 数据存储：she_profile.db 的 agent_memory_text 表
class AgentMemoryService {
  static final AgentMemoryService instance = AgentMemoryService._();
  AgentMemoryService._();

  final SheProfileDatabaseService _profileDb = SheProfileDatabaseService();
  final Uuid _uuid = const Uuid();

  // ── 查询操作 ──────────────────────────────────────────────────────────────

  /// 获取指定 Agent 的所有记忆
  Future<List<AgentMemory>> getAgentMemories(String agentId) async {
    try {
      final memoriesMap = await _profileDb.getAllAgentMemory(agentId);
      final memories = <AgentMemory>[];

      for (final entry in memoriesMap.entries) {
        memories.add(
          AgentMemory(
            id: _uuid.v5(Uuid.NAMESPACE_URL, '$agentId:${entry.key}'),
            agentId: agentId,
            key: entry.key,
            value: entry.value,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      // 按更新时间倒序排列
      memories.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return memories;
    } catch (e) {
      LoggerService().error(
        'Failed to get agent memories',
        tag: 'AgentMemoryService',
        error: e,
      );
      return [];
    }
  }

  /// 获取单条记忆
  Future<String?> getMemory(String agentId, String key) async {
    try {
      return await _profileDb.getAgentMemory(agentId, key);
    } catch (e) {
      LoggerService().error(
        'Failed to get memory: $key',
        tag: 'AgentMemoryService',
        error: e,
      );
      return null;
    }
  }

  /// 获取记忆数量
  Future<int> getMemoryCount(String agentId) async {
    try {
      return await _profileDb.getAgentMemoryCount(agentId);
    } catch (e) {
      LoggerService().error(
        'Failed to get memory count',
        tag: 'AgentMemoryService',
        error: e,
      );
      return 0;
    }
  }

  // ── 写入操作 ──────────────────────────────────────────────────────────────

  /// 添加新的记忆条目（自动生成带时间戳的 key）
  Future<void> appendNote(String agentId, String note) async {
    try {
      final timestamp = DateTime.now().toLocal().toString().substring(0, 19);
      final key = 'note_$timestamp';
      await _profileDb.setAgentMemory(agentId, key, note);
      LoggerService().info(
        'Note appended to agent $agentId',
        tag: 'AgentMemoryService',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to append note',
        tag: 'AgentMemoryService',
        error: e,
      );
    }
  }

  /// 更新单个记忆字段
  Future<void> updateField(String agentId, String key, String value) async {
    try {
      await _profileDb.setAgentMemory(agentId, key, value);
      LoggerService().info(
        'Memory updated: $agentId:$key',
        tag: 'AgentMemoryService',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to update field: $key',
        tag: 'AgentMemoryService',
        error: e,
      );
    }
  }

  /// 批量更新记忆字段
  Future<void> updateFieldBatch(
    String agentId,
    Map<String, String> fields,
  ) async {
    try {
      await _profileDb.setAgentMemoryBatch(agentId, fields);
      LoggerService().info(
        'Memory batch updated: $agentId (${fields.length} fields)',
        tag: 'AgentMemoryService',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to batch update fields',
        tag: 'AgentMemoryService',
        error: e,
      );
    }
  }

  // ── 删除操作 ──────────────────────────────────────────────────────────────

  /// 删除单条记忆
  Future<void> deleteNote(String agentId, String key) async {
    try {
      await _profileDb.deleteAgentMemory(agentId, key);
      LoggerService().info(
        'Memory deleted: $agentId:$key',
        tag: 'AgentMemoryService',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to delete note: $key',
        tag: 'AgentMemoryService',
        error: e,
      );
    }
  }

  /// 清除指定 Agent 的全部记忆
  Future<void> clearAllMemories(String agentId) async {
    try {
      await _profileDb.deleteAllAgentMemory(agentId);
      LoggerService().info(
        'All memories cleared for agent $agentId',
        tag: 'AgentMemoryService',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to clear all memories',
        tag: 'AgentMemoryService',
        error: e,
      );
    }
  }

  // ── 导出操作 ──────────────────────────────────────────────────────────────

  /// 导出为 JSON 格式
  Future<String> exportAsJson(String agentId) async {
    try {
      final memories = await getAgentMemories(agentId);
      final json = <Map<String, dynamic>>[];

      for (final memory in memories) {
        json.add(memory.toJson());
      }

      return '''
{
  "agentId": "$agentId",
  "exportedAt": "${DateTime.now().toIso8601String()}",
  "count": ${memories.length},
  "memories": ${_prettyJsonEncode(json)}
}
''';
    } catch (e) {
      LoggerService().error(
        'Failed to export as JSON',
        tag: 'AgentMemoryService',
        error: e,
      );
      return '{}';
    }
  }

  /// 导出为 Markdown 格式
  Future<String> exportAsMarkdown(String agentId) async {
    try {
      final memories = await getAgentMemories(agentId);
      final buffer = StringBuffer();

      buffer.writeln('# Agent Memories Export');
      buffer.writeln();
      buffer.writeln('**Agent ID:** `$agentId`');
      buffer.writeln('**Exported At:** ${DateTime.now().toLocal()}');
      buffer.writeln('**Total Memories:** ${memories.length}');
      buffer.writeln();

      for (final memory in memories) {
        buffer.writeln('## ${memory.key}');
        buffer.writeln();
        buffer.writeln('**Created:** ${memory.createdAtFormatted}');
        buffer.writeln('**Updated:** ${memory.updatedAtFormatted}');
        buffer.writeln();
        buffer.writeln(memory.value);
        buffer.writeln();
        buffer.writeln('---');
        buffer.writeln();
      }

      return buffer.toString();
    } catch (e) {
      LoggerService().error(
        'Failed to export as Markdown',
        tag: 'AgentMemoryService',
        error: e,
      );
      return '';
    }
  }

  // ── 辅助方法 ──────────────────────────────────────────────────────────────

  /// 格式化输出 JSON（带缩进）
  static String _prettyJsonEncode(dynamic object, [int indent = 0]) {
    final spaces = ' ' * (indent * 2);
    final nextSpaces = ' ' * ((indent + 1) * 2);

    if (object is Map) {
      if (object.isEmpty) return '{}';
      final items = object.entries
          .map((e) =>
              '$nextSpaces"${e.key}": ${_prettyJsonEncode(e.value, indent + 1)}')
          .join(',\n');
      return '{\n$items\n$spaces}';
    } else if (object is List) {
      if (object.isEmpty) return '[]';
      final items = object
          .map((e) => '${nextSpaces}${_prettyJsonEncode(e, indent + 1)}')
          .join(',\n');
      return '[\n$items\n$spaces]';
    } else if (object is String) {
      return '"${object.replaceAll('"', '\\"')}"';
    } else {
      return '$object';
    }
  }

  /// 验证记忆字段名称（仅允许字母、数字、下划线）
  bool isValidMemoryKey(String key) {
    final regex = RegExp(r'^[a-zA-Z0-9_-]+$');
    return regex.hasMatch(key) && key.length > 0 && key.length <= 128;
  }

  /// 验证记忆内容长度
  bool isValidMemoryValue(String value) {
    return value.length > 0 && value.length <= 10000; // 最多 10K 字符
  }
}
