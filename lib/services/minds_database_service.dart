import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/cognition.dart';
import '../identity/services/sync_local_write_hook.dart';

/// 认知数据库服务
///
/// 管理 `minds.db`，包含两张表：
///   - `cognition_self`  — 每个 Agent 的自我认知（soul、self_notes、capabilities）
///   - `cognition_user`  — 每个 Agent 对用户的认知（user_profile、user_impression、user_notes）
///
/// ### 数据库设计原则
/// - 每个 Agent 在每张表中仅有一条记录（UNIQUE agent_id）
/// - 写入时使用 INSERT OR REPLACE 保证幂等
/// - 查询接口尽量保持与旧系统（SheProfileDatabaseService）相同的语义，
///   便于 CognitionService 做零侵入的替换
///
/// ### 使用示例
/// ```dart
/// final db = MindsDatabaseService();
/// await db.setSelfCognition(SelfCognition(agentId: 'xxx', soul: '...', ...));
/// final self = await db.getSelfCognition('xxx');
/// ```
class MindsDatabaseService {
  static final MindsDatabaseService _instance =
      MindsDatabaseService._internal();
  factory MindsDatabaseService() => _instance;
  MindsDatabaseService._internal();

  Database? _database;
  String? _scopedAccountId;
  static const int _dbVersion = 1;
  static const String _dbName = 'minds.db';

  Future<void> switchAccount(String? accountId) async {
    if (_scopedAccountId == accountId && _database != null) return;
    await close();
    _scopedAccountId = accountId;
  }

  // ---------------------------------------------------------------------------
  // 初始化
  // ---------------------------------------------------------------------------

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<String> _resolveDbPath() async {
    if (kIsWeb) return 'minds';

    final directory = await getApplicationDocumentsDirectory();
    final accountId = _scopedAccountId;
    if (accountId != null && accountId.isNotEmpty) {
      final accountDir = Directory(join(directory.path, 'accounts', accountId));
      if (!accountDir.existsSync()) await accountDir.create(recursive: true);
      return join(accountDir.path, _dbName);
    }
    return join(directory.path, _dbName);
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'minds',
        version: _dbVersion,
        onCreate: _onCreate,
      );
    }

    final path = await _resolveDbPath();

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // ── cognition_self: Agent 的自我认知 ────────────────────────────────────
    await db.execute('''
      CREATE TABLE cognition_self (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id     TEXT NOT NULL UNIQUE,
        soul         TEXT NOT NULL DEFAULT '',
        self_notes   TEXT,
        capabilities TEXT,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_cognition_self_agent ON cognition_self(agent_id)',
    );

    // ── cognition_user: Agent 对用户的认知 ──────────────────────────────────
    await db.execute('''
      CREATE TABLE cognition_user (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        agent_id         TEXT NOT NULL UNIQUE,
        user_profile     TEXT NOT NULL DEFAULT '{}',
        user_impression  TEXT,
        user_notes       TEXT,
        last_updated     INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_cognition_user_agent ON cognition_user(agent_id)',
    );
  }

  // ---------------------------------------------------------------------------
  // cognition_self CRUD
  // ---------------------------------------------------------------------------

  /// 写入或覆盖一条自我认知记录（基于 agent_id REPLACE）
  Future<void> setSelfCognition(SelfCognition cognition) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = cognition.copyWith(
      updatedAt: now,
      createdAt: cognition.createdAt == 0 ? now : cognition.createdAt,
    );
    await db.insert(
      'cognition_self',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await SyncLocalWriteHook.onCognitionSelfUpserted(entry.toMap());
  }

  /// 读取单个 Agent 的自我认知
  Future<SelfCognition?> getSelfCognition(String agentId) async {
    final db = await database;
    final rows = await db.query(
      'cognition_self',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SelfCognition.fromMap(rows.first);
  }

  /// 获取所有 Agent 的自我认知
  Future<List<SelfCognition>> getAllSelfCognitions() async {
    final db = await database;
    final rows = await db.query('cognition_self', orderBy: 'updated_at DESC');
    return rows.map(SelfCognition.fromMap).toList();
  }

  /// 仅更新 soul 字段（常用路径）
  Future<void> updateSoul(String agentId, String soul) async {
    final existing = await getSelfCognition(agentId);
    if (existing == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await setSelfCognition(SelfCognition(
        agentId: agentId,
        soul: soul,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await setSelfCognition(existing.copyWith(soul: soul));
    }
  }

  /// 仅更新 self_notes 字段
  Future<void> updateSelfNotes(String agentId, String selfNotes) async {
    final existing = await getSelfCognition(agentId);
    if (existing == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await setSelfCognition(SelfCognition(
        agentId: agentId,
        soul: '',
        selfNotes: selfNotes,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await setSelfCognition(existing.copyWith(selfNotes: selfNotes));
    }
  }

  /// 删除单个 Agent 的自我认知
  Future<void> deleteSelfCognition(String agentId) async {
    final db = await database;
    await db.delete('cognition_self', where: 'agent_id = ?', whereArgs: [agentId]);
    await SyncLocalWriteHook.onCognitionSelfDeleted(agentId: agentId);
  }

  Future<void> deleteSelfCognitionFromSync(String agentId) async {
    final db = await database;
    await db.delete('cognition_self', where: 'agent_id = ?', whereArgs: [agentId]);
  }

  // ---------------------------------------------------------------------------
  // cognition_user CRUD
  // ---------------------------------------------------------------------------

  /// 写入或覆盖一条用户认知记录（基于 agent_id REPLACE）
  Future<void> setUserCognition(UserCognition cognition) async {
    final db = await database;
    final entry = cognition.copyWith(
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert(
      'cognition_user',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await SyncLocalWriteHook.onCognitionUserUpserted(entry.toMap());
  }

  /// 读取单个 Agent 的用户认知
  Future<UserCognition?> getUserCognition(String agentId) async {
    final db = await database;
    final rows = await db.query(
      'cognition_user',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UserCognition.fromMap(rows.first);
  }

  /// 获取 user_profile KV Map（与旧 getAllUserProfile() 语义一致）
  ///
  /// [agentId] 通常为 She 的 ID，因为用户档案由 She 维护。
  Future<Map<String, String>> getUserProfile(String agentId) async {
    final cog = await getUserCognition(agentId);
    return cog?.userProfile ?? {};
  }

  /// 设置单个 user_profile 字段（不覆盖其他字段）
  Future<void> setUserProfileField(
    String agentId,
    String key,
    String value,
  ) async {
    final existing = await getUserCognition(agentId);
    final profile = Map<String, String>.from(existing?.userProfile ?? {});
    profile[key] = value;
    final updated = existing != null
        ? existing.copyWith(userProfile: profile)
        : UserCognition(
            agentId: agentId,
            userProfile: profile,
            lastUpdated: DateTime.now().millisecondsSinceEpoch,
          );
    await setUserCognition(updated);
  }

  /// 批量设置 user_profile 字段
  Future<void> setUserProfileFields(
    String agentId,
    Map<String, String> fields,
  ) async {
    final existing = await getUserCognition(agentId);
    final profile = Map<String, String>.from(existing?.userProfile ?? {});
    profile.addAll(fields);
    final updated = existing != null
        ? existing.copyWith(userProfile: profile)
        : UserCognition(
            agentId: agentId,
            userProfile: profile,
            lastUpdated: DateTime.now().millisecondsSinceEpoch,
          );
    await setUserCognition(updated);
  }

  /// 删除 user_profile 中的单个字段
  Future<void> deleteUserProfileField(String agentId, String key) async {
    final existing = await getUserCognition(agentId);
    if (existing == null) return;
    final profile = Map<String, String>.from(existing.userProfile);
    profile.remove(key);
    await setUserCognition(existing.copyWith(userProfile: profile));
  }

  /// 仅更新 user_impression 字段
  Future<void> updateUserImpression(String agentId, String impression) async {
    final existing = await getUserCognition(agentId);
    if (existing == null) {
      await setUserCognition(UserCognition(
        agentId: agentId,
        userProfile: {},
        userImpression: impression,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      await setUserCognition(existing.copyWith(userImpression: impression));
    }
  }

  /// 删除单个 Agent 的用户认知
  Future<void> deleteUserCognition(String agentId) async {
    final db = await database;
    await db.delete('cognition_user', where: 'agent_id = ?', whereArgs: [agentId]);
    await SyncLocalWriteHook.onCognitionUserDeleted(agentId: agentId);
  }

  Future<void> deleteUserCognitionFromSync(String agentId) async {
    final db = await database;
    await db.delete('cognition_user', where: 'agent_id = ?', whereArgs: [agentId]);
  }

  /// 合并 self/user 认知变更，按时间统一分页（避免单表 limit 截断丢事件）。
  Future<List<Map<String, dynamic>>> getCognitionChangedSince({
    required int sinceMs,
    int limit = 50,
    int offset = 0,
  }) async {
    final fetchCap = limit + offset + 50;
    final selfRows = await getSelfChangedSince(sinceMs: sinceMs, limit: fetchCap);
    final userRows = await getUserChangedSince(sinceMs: sinceMs, limit: fetchCap);
    final merged = <Map<String, dynamic>>[
      ...selfRows.map((row) => {...row, 'kind': 'self'}),
      ...userRows.map((row) => {...row, 'kind': 'user'}),
    ]..sort((a, b) {
        final aMs = a['kind'] == 'user'
            ? (a['last_updated'] as int? ?? 0)
            : (a['updated_at'] as int? ?? 0);
        final bMs = b['kind'] == 'user'
            ? (b['last_updated'] as int? ?? 0)
            : (b['updated_at'] as int? ?? 0);
        final byTime = aMs.compareTo(bMs);
        if (byTime != 0) return byTime;
        final aId = a['agent_id'] as String? ?? '';
        final bId = b['agent_id'] as String? ?? '';
        return aId.compareTo(bId);
      });
    if (merged.length <= offset) return [];
    final end = (offset + limit).clamp(0, merged.length);
    return merged.sublist(offset, end);
  }

  Future<List<Map<String, dynamic>>> getSelfChangedSince({
    required int sinceMs,
    int? limit,
  }) async {
    final db = await database;
    return db.query(
      'cognition_self',
      where: 'updated_at >= ?',
      whereArgs: [sinceMs],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
  }

  Future<List<Map<String, dynamic>>> getUserChangedSince({
    required int sinceMs,
    int? limit,
  }) async {
    final db = await database;
    return db.query(
      'cognition_user',
      where: 'last_updated >= ?',
      whereArgs: [sinceMs],
      orderBy: 'last_updated ASC',
      limit: limit,
    );
  }

  Future<void> upsertSelfFromSync(Map<String, dynamic> row) async {
    final agentId = row['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return;
    final incomingMs = row['updated_at'] as int? ?? 0;
    final existing = await getSelfCognition(agentId);
    if (existing != null && incomingMs < existing.updatedAt) return;
    final db = await database;
    await db.insert(
      'cognition_self',
      {
        'agent_id': agentId,
        'soul': row['soul'] as String? ?? '',
        'self_notes': row['self_notes'],
        'capabilities': row['capabilities'],
        'created_at': row['created_at'] as int? ??
            existing?.createdAt ??
            incomingMs,
        'updated_at': incomingMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertUserFromSync(Map<String, dynamic> row) async {
    final agentId = row['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return;
    final incomingMs = row['last_updated'] as int? ?? 0;
    final existing = await getUserCognition(agentId);
    if (existing != null && incomingMs < existing.lastUpdated) return;
    final db = await database;
    await db.insert(
      'cognition_user',
      {
        'agent_id': agentId,
        'user_profile': row['user_profile'] as String? ?? '{}',
        'user_impression': row['user_impression'],
        'user_notes': row['user_notes'],
        'last_updated': incomingMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------------------
  // 批量清理 / 生命周期
  // ---------------------------------------------------------------------------

  /// 清空所有认知数据（保留数据库文件）
  Future<void> clearAll() async {
    final db = await database;
    final selfRows = await db.query('cognition_self', columns: ['agent_id']);
    final userRows = await db.query('cognition_user', columns: ['agent_id']);
    await db.delete('cognition_self');
    await db.delete('cognition_user');
    for (final row in selfRows) {
      final agentId = row['agent_id'] as String?;
      if (agentId == null || agentId.isEmpty) continue;
      await SyncLocalWriteHook.onCognitionSelfDeleted(agentId: agentId);
    }
    for (final row in userRows) {
      final agentId = row['agent_id'] as String?;
      if (agentId == null || agentId.isEmpty) continue;
      await SyncLocalWriteHook.onCognitionUserDeleted(agentId: agentId);
    }
  }

  /// 清空单个 Agent 的所有认知
  Future<void> clearAgent(String agentId) async {
    await deleteSelfCognition(agentId);
    await deleteUserCognition(agentId);
  }

  /// 关闭数据库连接
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// 删除整个数据库文件
  Future<void> deleteDatabase() async {
    await clearAll();
    await close();
    if (!kIsWeb) {
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _dbName);
      try {
        await databaseFactory.deleteDatabase(path);
      } catch (_) {}
    }
  }
}
