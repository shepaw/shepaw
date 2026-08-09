import 'dart:convert';
import '../models/agent_memory_entry.dart';
import 'agent_memory_store_service.dart';
import 'logger_service.dart';

/// Agent 记忆业务门面。
///
/// 权威落在储物袋 `memory/<agentId>/entries/*.json`（[AgentMemoryStoreService]）；
/// 不再写入 SQLite（旧库仅作一次性迁移源）。
class AgentMemoryBizService {
  static final AgentMemoryBizService _instance = AgentMemoryBizService._();
  factory AgentMemoryBizService() => _instance;
  AgentMemoryBizService._();

  // ---------------------------------------------------------------------------
  // 便利方法 - CRUD 包装
  // ---------------------------------------------------------------------------

  /// 添加一条记忆，自动生成 memory_id
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
    return AgentMemoryStoreService.forAgent(agentId).addMemory(entry);
  }

  Future<AgentMemoryEntry?> getMemory(String agentId, int memoryId) async {
    return AgentMemoryStoreService.forAgent(agentId).getMemory(memoryId);
  }

  Future<List<AgentMemoryEntry>> getAllMemories(
    String agentId, {
    MemoryType? type,
    String? sourceType,
    int limit = 200,
  }) async {
    return AgentMemoryStoreService.forAgent(agentId).getAllMemories(
      type: type,
      sourceType: sourceType,
      limit: limit,
    );
  }

  Future<void> updateMemory(String agentId, AgentMemoryEntry entry) async {
    await AgentMemoryStoreService.forAgent(agentId).updateMemory(entry);
  }

  Future<void> deleteMemory(String agentId, int memoryId) async {
    await AgentMemoryStoreService.forAgent(agentId).deleteMemory(memoryId);
  }

  Future<void> clearAllMemories(String agentId) async {
    await AgentMemoryStoreService.forAgent(agentId).clearAllMemories();
  }

  Future<List<AgentMemoryEntry>> queryByKeyword(
    String agentId,
    String keyword, {
    int limit = 50,
  }) async {
    return AgentMemoryStoreService.forAgent(agentId)
        .queryByKeyword(keyword, limit: limit);
  }

  Future<List<AgentMemoryEntry>> queryBySource(
    String agentId,
    String sourceType, {
    String? sourceId,
    int limit = 100,
  }) async {
    return AgentMemoryStoreService.forAgent(agentId).queryBySource(
      sourceType,
      sourceId: sourceId,
      limit: limit,
    );
  }

  Future<int> getMemoryCount(String agentId, {MemoryType? type}) async {
    return AgentMemoryStoreService.forAgent(agentId)
        .getMemoryCount(type: type);
  }

  Future<Map<MemoryType, int>> getMemoryCountByType(String agentId) async {
    return AgentMemoryStoreService.forAgent(agentId).getMemoryCountByType();
  }

  Future<String> exportAsJson(String agentId) async {
    try {
      final memories = await getAllMemories(agentId);
      return jsonEncode({
        'agentId': agentId,
        'exportedAt': DateTime.now().toIso8601String(),
        'count': memories.length,
        'memories': [for (final m in memories) m.toJson()],
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
        buffer.writeln('**Type:** ${memory.memoryType.name}');
        if (memory.sourceType != null) {
          buffer.writeln(
              '**Source:** ${memory.sourceType}${memory.sourceId != null ? ' (${memory.sourceId})' : ''}');
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

  Future<void> closeAgent(String agentId) async {
    await AgentMemoryStoreService.forAgent(agentId).close();
  }

  Future<void> deleteAgentMemories(String agentId) async {
    await AgentMemoryStoreService.forAgent(agentId).deleteAll();
  }

  Future<void> closeAll() async {
    await AgentMemoryStoreService.closeAll();
  }
}
