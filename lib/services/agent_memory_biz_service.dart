import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/agent_memory_entry.dart';
import 'agent_memory_db_service.dart';
import 'logger_service.dart';

/// Agent 记忆业务逻辑服务（新版本）
///
/// 在 [AgentMemoryDbService] 之上提供更高级的业务逻辑：
/// - 记忆导入/导出
/// - 批量操作
/// - 统计和检索
class AgentMemoryBizService {
  static final AgentMemoryBizService _instance = AgentMemoryBizService._();
  factory AgentMemoryBizService() => _instance;
  AgentMemoryBizService._();

  final _uuid = const Uuid();

  // ---------------------------------------------------------------------------
  // 便利方法 - CRUD 包装
  // ---------------------------------------------------------------------------

  /// 添加一条记忆，自动生成 memory_id
  ///
  /// 参数：
  /// - [agentId] Agent ID
  /// - [content] 记忆内容
  /// - [type] 记忆类型
  /// - [keywords] 关键词列表
  /// - [sourceType] 来源类型（如 `MemorySourceType.direct`）
  /// - [sourceId] 来源 ID（如 channel_id）
  /// - [memoryTime] 记忆发生时间（默认当前时间）
  Future<int> addMemory({
    required String agentId,
    required String content,
    required MemoryType type,
    List<String>? keywords,
    String? sourceType,
    String? sourceId,
    int? memoryTime,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = AgentMemoryEntry(
      memoryId: null,
      memoryContent: content,
      memoryTime: memoryTime ?? now,
      memoryType: type,
      memoryKeywords: keywords ?? [],
      sourceType: sourceType,
      sourceId: sourceId,
      createdAt: now,
      updatedAt: now,
    );
    return await AgentMemoryDbService.forAgent(agentId).addMemory(entry);
  }

  /// 获取单条记忆
  Future<AgentMemoryEntry?> getMemory(String agentId, int memoryId) async {
    return await AgentMemoryDbService.forAgent(agentId).getMemory(memoryId);
  }

  /// 获取所有记忆（支持过滤）
  Future<List<AgentMemoryEntry>> getAllMemories(
    String agentId, {
    MemoryType? type,
    String? sourceType,
    int limit = 200,
  }) async {
    return await AgentMemoryDbService.forAgent(agentId).getAllMemories(
      type: type,
      sourceType: sourceType,
      limit: limit,
    );
  }

  /// 更新记忆
  Future<void> updateMemory(String agentId, AgentMemoryEntry entry) async {
    await AgentMemoryDbService.forAgent(agentId).updateMemory(entry);
  }

  /// 删除记忆
  Future<void> deleteMemory(String agentId, int memoryId) async {
    await AgentMemoryDbService.forAgent(agentId).deleteMemory(memoryId);
  }

  /// 清空所有记忆
  Future<void> clearAllMemories(String agentId) async {
    await AgentMemoryDbService.forAgent(agentId).clearAllMemories();
  }

  // ---------------------------------------------------------------------------
  // 查询 - 搜索和统计
  // ---------------------------------------------------------------------------

  /// 按关键词搜索
  Future<List<AgentMemoryEntry>> queryByKeyword(
    String agentId,
    String keyword, {
    int limit = 50,
  }) async {
    return await AgentMemoryDbService.forAgent(agentId)
        .queryByKeyword(keyword, limit: limit);
  }

  /// 按来源查询
  Future<List<AgentMemoryEntry>> queryBySource(
    String agentId,
    String sourceType, {
    String? sourceId,
    int limit = 100,
  }) async {
    return await AgentMemoryDbService.forAgent(agentId).queryBySource(
      sourceType,
      sourceId: sourceId,
      limit: limit,
    );
  }

  /// 获取记忆计数
  Future<int> getMemoryCount(String agentId, {MemoryType? type}) async {
    return await AgentMemoryDbService.forAgent(agentId)
        .getMemoryCount(type: type);
  }

  /// 获取按类型分类的计数
  Future<Map<MemoryType, int>> getMemoryCountByType(String agentId) async {
    return await AgentMemoryDbService.forAgent(agentId).getMemoryCountByType();
  }

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// 导出为 JSON 格式
  Future<String> exportAsJson(String agentId) async {
    try {
      final memories = await getAllMemories(agentId);
      final json = <Map<String, dynamic>>[];

      for (final memory in memories) {
        json.add(memory.toJson());
      }

      return jsonEncode({
        'agentId': agentId,
        'exportedAt': DateTime.now().toIso8601String(),
        'count': memories.length,
        'memories': json,
      });
    } catch (e) {
      LoggerService().error(
        'Failed to export as JSON',
        tag: 'AgentMemoryBizService',
        error: e,
      );
      return '{}';
    }
  }

  /// 导出为 Markdown 格式
  Future<String> exportAsMarkdown(String agentId) async {
    try {
      final memories = await getAllMemories(agentId);
      final buffer = StringBuffer();

      buffer.writeln('# Agent Memory Export');
      buffer.writeln();
      buffer.writeln('**Agent ID:** `$agentId`');
      buffer.writeln('**Exported At:** ${DateTime.now().toLocal()}');
      buffer.writeln('**Total Memories:** ${memories.length}');
      buffer.writeln();

      for (final memory in memories) {
        buffer.writeln('## Memory #${memory.memoryId}');
        buffer.writeln();
        buffer.writeln('**Type:** ${memory.memoryType.displayName}');
        if (memory.sourceType != null) {
          buffer.writeln('**Source:** ${memory.sourceType}${memory.sourceId != null ? ' (${memory.sourceId})' : ''}');
        }
        if (memory.memoryKeywords.isNotEmpty) {
          buffer.writeln('**Keywords:** ${memory.memoryKeywords.join(', ')}');
        }
        buffer.writeln('**Recorded:** ${memory.memoryTimeFormatted}');
        buffer.writeln('**Created:** ${memory.createdAtFormatted}');
        buffer.writeln();
        buffer.writeln(memory.memoryContent);
        buffer.writeln();
        buffer.writeln('---');
        buffer.writeln();
      }

      return buffer.toString();
    } catch (e) {
      LoggerService().error(
        'Failed to export as Markdown',
        tag: 'AgentMemoryBizService',
        error: e,
      );
      return '';
    }
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 关闭指定 Agent 的数据库
  Future<void> closeAgent(String agentId) async {
    await AgentMemoryDbService.forAgent(agentId).close();
  }

  /// 删除指定 Agent 的整个记忆数据库
  Future<void> deleteAgentMemories(String agentId) async {
    await AgentMemoryDbService.forAgent(agentId).deleteDatabase();
  }

  /// 关闭所有数据库连接
  Future<void> closeAll() async {
    await AgentMemoryDbService.closeAll();
  }
}
