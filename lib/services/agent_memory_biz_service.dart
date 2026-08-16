import 'dart:convert';

import '../models/agent_memory_entry.dart';
import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import 'agent_memory_store_service.dart';
import 'logger_service.dart';

/// Agent 记忆业务门面。
///
/// 权威落在储物袋：
/// - 本机：`cognition/<agentId>/entries/*.json`
/// - Peer 中继：宿主 `cognition/<agentId>/peers/<配对peerId>/entries/*.json`
///   （多客户端互不串味；Soul 仍共享 agent 根下的 soul.md）
class AgentMemoryBizService {
  static final AgentMemoryBizService _instance = AgentMemoryBizService._();
  factory AgentMemoryBizService() => _instance;
  AgentMemoryBizService._();

  // ---------------------------------------------------------------------------
  // Peer-aware API（UI 优先走这里）
  // ---------------------------------------------------------------------------

  Future<({List<AgentMemoryEntry> memories, bool editable})> listForAgent(
    RemoteAgent agent, {
    MemoryType? type,
    String? keyword,
    int limit = 200,
  }) async {
    if (agent.isPeerAgent) {
      final result = await _peerOp(
        agent,
        op: (keyword != null && keyword.trim().isNotEmpty) ? 'query' : 'list',
        type: type,
        keyword: keyword,
        limit: limit,
      );
      if (!result.ok) {
        throw StateError(result.error ?? 'peer_memory_failed');
      }
      return (memories: result.memories, editable: result.editable);
    }
    final memories = keyword != null && keyword.trim().isNotEmpty
        ? await queryByKeyword(agent.id, keyword, limit: limit)
        : await getAllMemories(agent.id, type: type, limit: limit);
    return (memories: memories, editable: true);
  }

  Future<int> addMemoryForAgent(
    RemoteAgent agent, {
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
    if (agent.isPeerAgent) {
      final result = await _peerOp(agent, op: 'add', entry: entry);
      if (!result.ok || result.memoryId == null) {
        throw StateError(result.error ?? 'peer_memory_add_failed');
      }
      return result.memoryId!;
    }
    return AgentMemoryStoreService.forAgent(agent.id).addMemory(entry);
  }

  Future<void> updateMemoryForAgent(
    RemoteAgent agent,
    AgentMemoryEntry entry,
  ) async {
    if (agent.isPeerAgent) {
      final result = await _peerOp(agent, op: 'update', entry: entry);
      if (!result.ok) {
        throw StateError(result.error ?? 'peer_memory_update_failed');
      }
      return;
    }
    await AgentMemoryStoreService.forAgent(agent.id).updateMemory(entry);
  }

  Future<void> deleteMemoryForAgent(RemoteAgent agent, int memoryId) async {
    if (agent.isPeerAgent) {
      final result = await _peerOp(agent, op: 'delete', memoryId: memoryId);
      if (!result.ok) {
        throw StateError(result.error ?? 'peer_memory_delete_failed');
      }
      return;
    }
    await AgentMemoryStoreService.forAgent(agent.id).deleteMemory(memoryId);
  }

  Future<void> clearMemoriesForAgent(RemoteAgent agent) async {
    if (agent.isPeerAgent) {
      final result = await _peerOp(agent, op: 'clear');
      if (!result.ok) {
        throw StateError(result.error ?? 'peer_memory_clear_failed');
      }
      return;
    }
    await AgentMemoryStoreService.forAgent(agent.id).clearAllMemories();
  }

  Future<PeerMemoryResult> _peerOp(
    RemoteAgent agent, {
    required String op,
    MemoryType? type,
    String? keyword,
    int? limit,
    AgentMemoryEntry? entry,
    int? memoryId,
  }) async {
    final peerId = agent.sourcePeerId;
    final remoteId = agent.remoteAgentId;
    if (peerId == null || remoteId == null) {
      return const PeerMemoryResult(ok: false, error: 'missing_peer');
    }
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      return const PeerMemoryResult(ok: false, error: 'offline');
    }
    return PeerAgentClientService.instance.memoryOp(
      peerId: peerId,
      remoteAgentId: remoteId,
      op: op,
      type: type,
      keyword: keyword,
      limit: limit,
      entry: entry,
      memoryId: memoryId,
    );
  }

  // ---------------------------------------------------------------------------
  // 便利方法 - CRUD 包装（按 agentId，本机 store）
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
