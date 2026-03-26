import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// 独立的 She 档案数据库服务。
///
/// ### 为什么独立？
/// `she_memory` 和 `user_profile` 是 She（内置守护 Agent）的长期人格与用户档案
/// 数据，读写模式与核心的聊天表（messages/channels）完全不同：
///   - 更新频率低（每次对话末尾写一次）
///   - 每次打开 App 都会被完整读取以构建系统提示词
///   - 数据量小但极为关键，需要避免被大量聊天写入阻塞
///
/// 独立到 `she_profile.db` 可：
///   1. 彻底隔离 She 档案与聊天消息的文件锁竞争
///   2. 支持独立备份/导出 She 的人格与记忆
///   3. `clearAllData()` 重置聊天时不会误删 She 的记忆
///
/// ### 表结构
///   - `she_memory`      — She 的动态记忆（soul / long_term_memory / heartbeat 等）
///   - `user_profile`    — 结构化用户档案（name / age / occupation 等）
///   - `agent_memory_text` — 各 Agent 的独立记忆（name/profile/notes 等）
class SheProfileDatabaseService {
  static final SheProfileDatabaseService _instance =
      SheProfileDatabaseService._internal();
  factory SheProfileDatabaseService() => _instance;
  SheProfileDatabaseService._internal();

  Database? _database;

  static const int _version = 2;
  static const String _dbName = 'she_profile.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'she_profile',
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, _dbName);

    return await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // She 记忆表
    // 存储 She 的动态长期记忆，key 全局唯一：
    //   soul            — She 的自我认知与性格（随对话成长）
    //   self_notes      — She 的自我备注
    //   long_term_memory — 对主人的长期印象
    //   heartbeat       — 最近一次对话摘要
    //   conversation_count — 累计对话轮次
    //   user_info       — 对主人的初步了解
    //   capabilities    — She 可用工具索引
    await db.execute('''
      CREATE TABLE she_memory (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        key        TEXT NOT NULL UNIQUE,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // 用户档案表
    // 结构化存储主人的个人信息（She 用于构建系统提示词）：
    //   核心层：name / age / gender / occupation / city
    //   扩展层：interests / values / goals / communication_style 等
    //   内部标志：_initialized（首次填写后置 true，不对 She 可见）
    await db.execute('''
      CREATE TABLE user_profile (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 → v2: 添加 agent_memory_text 表（为所有 Agent 存储记忆）
    if (oldVersion < 2 && newVersion >= 2) {
      await db.execute('''
        CREATE TABLE agent_memory_text (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          agent_id   TEXT NOT NULL,
          key        TEXT NOT NULL,
          value      TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          UNIQUE(agent_id, key)
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_agent_memory_agent_id ON agent_memory_text(agent_id)'
      );
    }
  }

  // ---------------------------------------------------------------------------
  // She 记忆 CRUD
  // ---------------------------------------------------------------------------

  /// 读取单条 She 记忆。
  Future<String?> getSheMemory(String key) async {
    final db = await database;
    final results = await db.query(
      'she_memory',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  /// 写入（或覆盖）单条 She 记忆。
  Future<void> setSheMemory(String key, String value) async {
    final db = await database;
    await db.insert(
      'she_memory',
      {
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取全部 She 记忆，返回 `Map<key, value>`。
  Future<Map<String, String>> getAllSheMemory() async {
    final db = await database;
    final results = await db.query('she_memory');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  // ---------------------------------------------------------------------------
  // 用户档案 CRUD
  // ---------------------------------------------------------------------------

  /// 读取单个用户档案字段。
  Future<String?> getUserProfile(String key) async {
    final db = await database;
    final results = await db.query(
      'user_profile',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  /// 写入（或覆盖）单个用户档案字段。
  Future<void> setUserProfile(String key, String value) async {
    final db = await database;
    await db.insert(
      'user_profile',
      {
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取全部用户档案，按 key 字母序返回 `Map<key, value>`。
  Future<Map<String, String>> getAllUserProfile() async {
    final db = await database;
    final results = await db.query('user_profile', orderBy: 'key ASC');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  /// 删除单个用户档案字段。
  Future<void> deleteUserProfile(String key) async {
    final db = await database;
    await db.delete('user_profile', where: 'key = ?', whereArgs: [key]);
  }

  // ---------------------------------------------------------------------------
  // Agent 记忆 CRUD (v2 新增)
  // ---------------------------------------------------------------------------

  /// 读取单条 Agent 记忆。
  Future<String?> getAgentMemory(String agentId, String key) async {
    final db = await database;
    final results = await db.query(
      'agent_memory_text',
      where: 'agent_id = ? AND key = ?',
      whereArgs: [agentId, key],
      limit: 1,
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  /// 写入（或覆盖）单条 Agent 记忆。
  Future<void> setAgentMemory(String agentId, String key, String value) async {
    final db = await database;
    await db.insert(
      'agent_memory_text',
      {
        'agent_id': agentId,
        'key': key,
        'value': value,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取指定 Agent 的全部记忆，返回 `Map<key, value>`。
  Future<Map<String, String>> getAllAgentMemory(String agentId) async {
    final db = await database;
    final results = await db.query(
      'agent_memory_text',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'updated_at DESC',
    );
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  /// 删除单条 Agent 记忆。
  Future<void> deleteAgentMemory(String agentId, String key) async {
    final db = await database;
    await db.delete(
      'agent_memory_text',
      where: 'agent_id = ? AND key = ?',
      whereArgs: [agentId, key],
    );
  }

  /// 删除指定 Agent 的全部记忆。
  Future<void> deleteAllAgentMemory(String agentId) async {
    final db = await database;
    await db.delete(
      'agent_memory_text',
      where: 'agent_id = ?',
      whereArgs: [agentId],
    );
  }

  /// 获取指定 Agent 的记忆数量。
  Future<int> getAgentMemoryCount(String agentId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM agent_memory_text WHERE agent_id = ?',
      [agentId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 批量写入 Agent 记忆。
  Future<void> setAgentMemoryBatch(
    String agentId,
    Map<String, String> memories,
  ) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final entry in memories.entries) {
      batch.insert(
        'agent_memory_text',
        {
          'agent_id': agentId,
          'key': entry.key,
          'value': entry.value,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit();
  }

  // ---------------------------------------------------------------------------
  // 批量清理（供设置页「重置 She 档案」使用）
  // ---------------------------------------------------------------------------

  /// 清空 She 的全部记忆（不影响用户档案）。
  Future<void> clearSheMemory() async {
    final db = await database;
    await db.delete('she_memory');
  }

  /// 清空用户档案（不影响 She 记忆）。
  Future<void> clearUserProfile() async {
    final db = await database;
    await db.delete('user_profile');
  }

  /// 清空全部数据（she_memory + user_profile）。
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('she_memory');
    await db.delete('user_profile');
  }

  // ---------------------------------------------------------------------------
  // 数据库生命周期
  // ---------------------------------------------------------------------------

  /// 关闭数据库连接。
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// 删除整个数据库文件并重置（不影响主库 shepaw.db）。
  Future<void> deleteDatabase() async {
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
