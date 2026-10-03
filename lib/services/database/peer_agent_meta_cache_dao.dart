import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../local_database_service.dart';

/// `peer_agent_meta_cache.kind` 的取值。
class PeerAgentMetaKind {
  static const models = 'models';
  static const modes = 'modes';
  static const commands = 'commands';
  static const soul = 'soul';
}

/// 一条 peer agent 元数据缓存。这一期只用 `scope == ''`（agent 级）。
class PeerAgentMetaCacheEntry {
  final String agentId;
  final String kind;
  final String scope;
  final Map<String, dynamic> payload;
  final int fetchedAt;

  const PeerAgentMetaCacheEntry({
    required this.agentId,
    required this.kind,
    this.scope = '',
    required this.payload,
    required this.fetchedAt,
  });

  Map<String, Object?> toMap() => {
        'agent_id': agentId,
        'kind': kind,
        'scope': scope,
        'payload': jsonEncode(payload),
        'fetched_at': fetchedAt,
      };

  factory PeerAgentMetaCacheEntry.fromMap(Map<String, Object?> map) {
    final raw = map['payload'];
    Map<String, dynamic> payload = const {};
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } else if (raw is Map) {
      payload = Map<String, dynamic>.from(raw);
    }
    return PeerAgentMetaCacheEntry(
      agentId: map['agent_id'] as String? ?? '',
      kind: map['kind'] as String? ?? '',
      scope: map['scope'] as String? ?? '',
      payload: payload,
      fetchedAt: map['fetched_at'] as int? ?? 0,
    );
  }
}

/// Peer agent 元数据本地缓存（模型 / 模式 / 斜杠命令 / 灵魂）。
extension PeerAgentMetaCacheDao on LocalDatabaseService {
  Future<PeerAgentMetaCacheEntry?> getPeerAgentMeta(
    String agentId,
    String kind, {
    String scope = '',
  }) async {
    final db = await database;
    final rows = await db.query(
      'peer_agent_meta_cache',
      where: 'agent_id = ? AND kind = ? AND scope = ?',
      whereArgs: [agentId, kind, scope],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PeerAgentMetaCacheEntry.fromMap(rows.first);
  }

  Future<List<PeerAgentMetaCacheEntry>> getAllPeerAgentMeta(String kind) async {
    final db = await database;
    final rows = await db.query(
      'peer_agent_meta_cache',
      where: 'kind = ?',
      whereArgs: [kind],
    );
    return rows.map(PeerAgentMetaCacheEntry.fromMap).toList();
  }

  Future<void> upsertPeerAgentMeta(PeerAgentMetaCacheEntry entry) async {
    final db = await database;
    await db.insert(
      'peer_agent_meta_cache',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deletePeerAgentMeta(String agentId) async {
    final db = await database;
    await db.delete(
      'peer_agent_meta_cache',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
  }
}
