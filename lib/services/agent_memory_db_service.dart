import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_memory_entry.dart';
import '../identity/services/sync_local_write_hook.dart';
import 'logger_service.dart';

/// Agent 独立记忆数据库服务
///
/// 为每个 Agent 创建并管理一个独立的 SQLite 数据库文件。
///
/// ### 数据库命名规则
/// 文件名：`agent_memory_{sanitized_agent_id}.db`
/// 其中 `sanitized_agent_id` 将 UUID 中的 `-` 替换为 `_`，以保证文件名合法。
///
/// ### 使用方式
/// ```dart
/// final service = AgentMemoryDbService.forAgent(agentId);
/// final id = await service.addMemory(entry);
/// ```
///
/// ### 表结构（memories）
/// | 字段            | 类型         | 说明                          |
/// |----------------|--------------|-------------------------------|
/// | memory_id      | INTEGER PK   | 自增主键                      |
/// | memory_content | TEXT         | 记忆内容                      |
/// | memory_time    | INTEGER      | 记忆发生时间戳（毫秒）         |
/// | memory_type    | TEXT         | 枚举字符串（MemoryType.name） |
/// | memory_keywords| TEXT         | JSON 数组字符串               |
/// | source_type    | TEXT         | 来源类型（direct/group/system）|
/// | source_id      | TEXT         | 来源 ID（如 channel_id）      |
/// | created_at     | INTEGER      | 写入时间戳（毫秒）             |
/// | updated_at     | INTEGER      | 最后更新时间戳（毫秒）         |
class AgentMemoryDbService {
  // ---------------------------------------------------------------------------
  // 单例实例池（每个 agentId 对应一个服务实例）
  // ---------------------------------------------------------------------------

  static final Map<String, AgentMemoryDbService> _instances = {};
  static String? _scopedAccountId;

  /// 当前账号 scope（与 [LocalDatabaseService.scopedAccountId] 联动）。
  static String? get scopedAccountId => _scopedAccountId;

  /// 获取指定 Agent 的数据库服务（单例）
  static AgentMemoryDbService forAgent(String agentId) {
    return _instances.putIfAbsent(
      agentId,
      () => AgentMemoryDbService._(agentId),
    );
  }

  /// 切换到指定账号（关闭所有已打开连接，下次访问时使用新路径）。
  static Future<void> switchAccount(String? accountId) async {
    if (_scopedAccountId == accountId) return;
    await closeAll();
    _scopedAccountId = accountId;
  }

  /// 关闭并移除所有缓存的实例（App 退出或切换账号时调用）
  static Future<void> closeAll() async {
    for (final service in List.of(_instances.values)) {
      await service._closeConnection();
    }
    _instances.clear();
  }

  /// 删除指定账号目录下所有 agent_memory_*.db
  static Future<void> deleteAllForAccount(String accountId) async {
    if (kIsWeb || accountId.isEmpty) return;
    if (_scopedAccountId == accountId) {
      await closeAll();
    }
    await _deleteAgentMemoryFilesInDirectory(
      Directory(
        join(
          (await getApplicationDocumentsDirectory()).path,
          'accounts',
          accountId,
        ),
      ),
    );
  }

  /// 删除全局 legacy 目录下的 agent_memory_*.db
  static Future<void> deleteAllLegacyGlobal() async {
    if (kIsWeb) return;
    await closeAll();
    await _deleteAgentMemoryFilesInDirectory(
      Directory((await getApplicationDocumentsDirectory()).path),
    );
  }

  /// 删除所有账号及 legacy 目录下的 agent_memory_*.db
  static Future<void> deleteAllAcrossAccounts() async {
    if (kIsWeb) return;
    await closeAll();
    final docs = await getApplicationDocumentsDirectory();
    await _deleteAgentMemoryFilesInDirectory(Directory(docs.path));
    final accountsDir = Directory(join(docs.path, 'accounts'));
    if (!await accountsDir.exists()) return;
    await for (final entity in accountsDir.list()) {
      if (entity is Directory) {
        await _deleteAgentMemoryFilesInDirectory(entity);
      }
    }
  }

  static Future<void> _deleteAgentMemoryFilesInDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = basename(entity.path);
        if (name.startsWith('agent_memory_') && name.endsWith('.db')) {
          await entity.delete();
        }
      }
    }
  }

  static String agentIdFromDbFileName(String fileName) {
    if (!fileName.startsWith('agent_memory_') || !fileName.endsWith('.db')) {
      return '';
    }
    final sanitized = fileName.substring(
      'agent_memory_'.length,
      fileName.length - '.db'.length,
    );
    return sanitized.replaceAll('_', '-');
  }

  /// 扫描当前账号目录下所有 agent_memory DB，返回 since 之后变更的行。
  static Future<List<Map<String, dynamic>>> queryAllChangedSince({
    required int sinceMs,
    int limit = 50,
  }) async {
    if (kIsWeb) return [];

    final baseDir = Directory(await _resolveDirectoryPath());
    if (!await baseDir.exists()) return [];

    final merged = <Map<String, dynamic>>[];
    await for (final entity in baseDir.list()) {
      if (entity is! File) continue;
      final name = basename(entity.path);
      if (!name.startsWith('agent_memory_') || !name.endsWith('.db')) continue;

      final agentId = agentIdFromDbFileName(name);
      if (agentId.isEmpty) continue;

      Database? db;
      try {
        db = await openDatabase(entity.path, readOnly: true);
        final rows = await db.query(
          'memories',
          where: 'updated_at > ?',
          whereArgs: [sinceMs],
          orderBy: 'updated_at ASC',
        );
        for (final row in rows) {
          merged.add({...row, 'agent_id': agentId});
        }
      } finally {
        await db?.close();
      }
    }

    merged.sort(
      (a, b) => ((a['updated_at'] as int?) ?? 0).compareTo(
        (b['updated_at'] as int?) ?? 0,
      ),
    );
    if (merged.length > limit) return merged.sublist(0, limit);
    return merged;
  }

  static Future<String> _resolveDirectoryPath() async {
    final directory = await getApplicationDocumentsDirectory();
    final accountId = _scopedAccountId;
    if (accountId != null && accountId.isNotEmpty) {
      final accountDir = Directory(join(directory.path, 'accounts', accountId));
      if (!accountDir.existsSync()) await accountDir.create(recursive: true);
      return accountDir.path;
    }
    return directory.path;
  }

  // ---------------------------------------------------------------------------
  // 实例成员
  // ---------------------------------------------------------------------------

  final String _agentId;
  Database? _database;
  static const int _dbVersion = 2;
  static const _uuid = Uuid();

  AgentMemoryDbService._(this._agentId);

  /// 获取 Agent ID
  String get agentId => _agentId;

  // ---------------------------------------------------------------------------
  // 数据库初始化
  // ---------------------------------------------------------------------------

  /// 将 agentId 转换为合法文件名（替换 `-` 为 `_`）
  static String _sanitizeAgentId(String agentId) =>
      agentId.replaceAll('-', '_').replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

  /// 获取数据库文件名
  String get _dbFileName =>
      'agent_memory_${_sanitizeAgentId(_agentId)}.db';

  /// 获取数据库实例（懒加载）
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'agent_memory_${_sanitizeAgentId(_agentId)}',
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    final path = join(await _resolveDirectoryPath(), _dbFileName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE memories ADD COLUMN sync_key TEXT');
      final rows = await db.query('memories');
      for (final row in rows) {
        await db.update(
          'memories',
          {'sync_key': _uuid.v4()},
          where: 'memory_id = ?',
          whereArgs: [row['memory_id']],
        );
      }
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_sync_key ON memories(sync_key)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_memory_updated_at ON memories(updated_at ASC)',
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE memories (
        memory_id      INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_key       TEXT NOT NULL UNIQUE,
        memory_content TEXT NOT NULL,
        memory_time    INTEGER NOT NULL,
        memory_type    TEXT NOT NULL,
        memory_keywords TEXT NOT NULL DEFAULT '[]',
        source_type    TEXT,
        source_id      TEXT,
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
      )
    ''');

    // 按类型查询
    await db.execute(
      'CREATE INDEX idx_memory_type ON memories(memory_type)',
    );
    // 按时间倒序查询（最常用）
    await db.execute(
      'CREATE INDEX idx_memory_time ON memories(memory_time DESC)',
    );
    // 按来源类型过滤
    await db.execute(
      'CREATE INDEX idx_source_type ON memories(source_type)',
    );
    // 按来源 ID 查询
    await db.execute(
      'CREATE INDEX idx_source_id ON memories(source_id)',
    );
    await db.execute(
      'CREATE INDEX idx_memory_updated_at ON memories(updated_at ASC)',
    );
  }

  Map<String, dynamic> _rowWithAgentId(Map<String, dynamic> row) => {
        ...row,
        'agent_id': _agentId,
      };

  Future<Map<String, dynamic>?> getRowBySyncKey(String syncKey) async {
    final db = await database;
    final rows = await db.query(
      'memories',
      where: 'sync_key = ?',
      whereArgs: [syncKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getChangedSince({
    required int sinceMs,
    int limit = 50,
  }) async {
    final db = await database;
    final rows = await db.query(
      'memories',
      where: 'updated_at > ?',
      whereArgs: [sinceMs],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return rows.map(_rowWithAgentId).toList();
  }

  Future<void> upsertFromSync(Map<String, dynamic> row) async {
    final syncKey = row['sync_key'] as String?;
    if (syncKey == null || syncKey.isEmpty) return;

    final incomingMs = row['updated_at'] as int? ?? 0;
    final existing = await getRowBySyncKey(syncKey);
    if (existing != null) {
      final existingMs = existing['updated_at'] as int? ?? 0;
      if (incomingMs < existingMs) return;
      final db = await database;
      await db.update(
        'memories',
        {
          'memory_content': row['memory_content'] as String? ?? '',
          'memory_time': row['memory_time'] as int? ?? incomingMs,
          'memory_type': row['memory_type'] as String? ?? 'conversation',
          'memory_keywords': row['memory_keywords'] as String? ?? '[]',
          'source_type': row['source_type'],
          'source_id': row['source_id'],
          'created_at': row['created_at'] as int? ??
              existing['created_at'] as int? ??
              incomingMs,
          'updated_at': incomingMs,
        },
        where: 'sync_key = ?',
        whereArgs: [syncKey],
      );
      return;
    }

    final db = await database;
    await db.insert(
      'memories',
      {
        'sync_key': syncKey,
        'memory_content': row['memory_content'] as String? ?? '',
        'memory_time': row['memory_time'] as int? ?? incomingMs,
        'memory_type': row['memory_type'] as String? ?? 'conversation',
        'memory_keywords': row['memory_keywords'] as String? ?? '[]',
        'source_type': row['source_type'],
        'source_id': row['source_id'],
        'created_at': row['created_at'] as int? ?? incomingMs,
        'updated_at': incomingMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteFromSync(String syncKey) async {
    final db = await database;
    await db.delete('memories', where: 'sync_key = ?', whereArgs: [syncKey]);
  }

  // ---------------------------------------------------------------------------
  // CRUD 操作
  // ---------------------------------------------------------------------------

  /// 添加一条记忆，返回数据库自增的 memory_id
  Future<int> addMemory(AgentMemoryEntry entry) async {
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final syncKey = entry.syncKey ?? _uuid.v4();
      final effectiveEntry = entry.copyWith(
        syncKey: syncKey,
        createdAt: entry.createdAt == 0 ? now : entry.createdAt,
        updatedAt: now,
      );
      final map = effectiveEntry.toMap();
      map['sync_key'] = syncKey;
      final id = await db.insert(
        'memories',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await SyncLocalWriteHook.onAgentMemoryUpserted(
        _rowWithAgentId({...map, 'memory_id': id}),
      );
      LoggerService().info(
        'Memory added: #$id',
        tag: 'AgentMemoryDbService[$_agentId]',
      );
      return id;
    } catch (e) {
      LoggerService().error(
        'Failed to add memory',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      rethrow;
    }
  }

  /// 根据 memory_id 查询单条记忆
  Future<AgentMemoryEntry?> getMemory(int memoryId) async {
    try {
      final db = await database;
      final rows = await db.query(
        'memories',
        where: 'memory_id = ?',
        whereArgs: [memoryId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return AgentMemoryEntry.fromMap(rows.first);
    } catch (e) {
      LoggerService().error(
        'Failed to get memory: $memoryId',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return null;
    }
  }

  /// 获取全部记忆，支持按类型和来源类型过滤
  ///
  /// - [type]       可选，按 [MemoryType] 过滤
  /// - [sourceType] 可选，按来源类型过滤（如 `MemorySourceType.direct`）
  /// - [limit]      最大返回条数（默认 200）
  /// - [offset]     分页偏移（默认 0）
  Future<List<AgentMemoryEntry>> getAllMemories({
    MemoryType? type,
    String? sourceType,
    int limit = 200,
    int offset = 0,
  }) async {
    try {
      final db = await database;

      final conditions = <String>[];
      final args = <dynamic>[];

      if (type != null) {
        conditions.add('memory_type = ?');
        args.add(type.name);
      }
      if (sourceType != null) {
        conditions.add('source_type = ?');
        args.add(sourceType);
      }

      final rows = await db.query(
        'memories',
        where: conditions.isEmpty ? null : conditions.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'memory_time DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map(AgentMemoryEntry.fromMap).toList();
    } catch (e) {
      LoggerService().error(
        'Failed to get memories',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return [];
    }
  }

  /// 更新一条已存在的记忆（根据 memory_id 匹配）
  Future<void> updateMemory(AgentMemoryEntry entry) async {
    assert(entry.memoryId != null, 'memoryId must not be null when updating');
    try {
      final db = await database;
      final existing = await getMemory(entry.memoryId!);
      final syncKey = entry.syncKey ?? existing?.syncKey ?? _uuid.v4();
      final updated = entry.copyWith(
        syncKey: syncKey,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      final map = updated.toMap();
      map['sync_key'] = syncKey;
      final count = await db.update(
        'memories',
        map,
        where: 'memory_id = ?',
        whereArgs: [entry.memoryId],
      );
      if (count == 0) {
        LoggerService().warning(
          'updateMemory: no row matched for id=${entry.memoryId}',
          tag: 'AgentMemoryDbService[$_agentId]',
        );
      } else {
        final row = await db.query(
          'memories',
          where: 'memory_id = ?',
          whereArgs: [entry.memoryId],
          limit: 1,
        );
        if (row.isNotEmpty) {
          await SyncLocalWriteHook.onAgentMemoryUpserted(_rowWithAgentId(row.first));
        }
      }
    } catch (e) {
      LoggerService().error(
        'Failed to update memory: ${entry.memoryId}',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      rethrow;
    }
  }

  /// 删除单条记忆
  Future<void> deleteMemory(int memoryId) async {
    try {
      final db = await database;
      final rows = await db.query(
        'memories',
        where: 'memory_id = ?',
        whereArgs: [memoryId],
        limit: 1,
      );
      final syncKey = rows.isEmpty ? null : rows.first['sync_key'] as String?;
      await db.delete('memories', where: 'memory_id = ?', whereArgs: [memoryId]);
      if (syncKey != null && syncKey.isNotEmpty) {
        await SyncLocalWriteHook.onAgentMemoryDeleted(
          agentId: _agentId,
          syncKey: syncKey,
        );
      }
      LoggerService().info(
        'Memory deleted: #$memoryId',
        tag: 'AgentMemoryDbService[$_agentId]',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to delete memory: $memoryId',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      rethrow;
    }
  }

  /// 清除该 Agent 的全部记忆（不删除数据库文件）
  Future<void> clearAllMemories() async {
    try {
      final db = await database;
      await db.delete('memories');
      LoggerService().info(
        'All memories cleared',
        tag: 'AgentMemoryDbService[$_agentId]',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to clear memories',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 查询操作
  // ---------------------------------------------------------------------------

  /// 按关键词搜索记忆（在 memory_content 和 memory_keywords 中搜索）
  Future<List<AgentMemoryEntry>> queryByKeyword(
    String keyword, {
    int limit = 50,
  }) async {
    if (keyword.trim().isEmpty) return [];
    try {
      final db = await database;
      final rows = await db.query(
        'memories',
        where: 'memory_content LIKE ? OR memory_keywords LIKE ?',
        whereArgs: ['%$keyword%', '%$keyword%'],
        orderBy: 'memory_time DESC',
        limit: limit,
      );
      return rows.map(AgentMemoryEntry.fromMap).toList();
    } catch (e) {
      LoggerService().error(
        'Failed to query by keyword: $keyword',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return [];
    }
  }

  /// 按来源查询记忆
  ///
  /// - [sourceType] 来源类型（`MemorySourceType.direct` / `group` / `system`）
  /// - [sourceId]   可选，进一步过滤具体的 channel_id 等
  Future<List<AgentMemoryEntry>> queryBySource(
    String sourceType, {
    String? sourceId,
    int limit = 100,
  }) async {
    try {
      final db = await database;
      final conditions = ['source_type = ?'];
      final args = <dynamic>[sourceType];

      if (sourceId != null) {
        conditions.add('source_id = ?');
        args.add(sourceId);
      }

      final rows = await db.query(
        'memories',
        where: conditions.join(' AND '),
        whereArgs: args,
        orderBy: 'memory_time DESC',
        limit: limit,
      );
      return rows.map(AgentMemoryEntry.fromMap).toList();
    } catch (e) {
      LoggerService().error(
        'Failed to query by source: $sourceType/$sourceId',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return [];
    }
  }

  /// 获取记忆总数，可按类型过滤
  Future<int> getMemoryCount({MemoryType? type}) async {
    try {
      final db = await database;
      final result = await db.rawQuery(
        type == null
            ? 'SELECT COUNT(*) as cnt FROM memories'
            : 'SELECT COUNT(*) as cnt FROM memories WHERE memory_type = ?',
        type == null ? null : [type.name],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      LoggerService().error(
        'Failed to get memory count',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return 0;
    }
  }

  /// 获取每种记忆类型的数量统计
  ///
  /// 返回 `Map<MemoryType, int>`，无数据的类型不包含在结果中。
  Future<Map<MemoryType, int>> getMemoryCountByType() async {
    try {
      final db = await database;
      final rows = await db.rawQuery(
        'SELECT memory_type, COUNT(*) as cnt FROM memories GROUP BY memory_type',
      );
      final result = <MemoryType, int>{};
      for (final row in rows) {
        final type = MemoryType.fromString(row['memory_type'] as String? ?? '');
        result[type] = (row['cnt'] as int?) ?? 0;
      }
      return result;
    } catch (e) {
      LoggerService().error(
        'Failed to get memory count by type',
        tag: 'AgentMemoryDbService[$_agentId]',
        error: e,
      );
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // 生命周期管理
  // ---------------------------------------------------------------------------

  /// 关闭数据库连接（不删除文件）
  Future<void> close() async {
    await _closeConnection();
    _instances.remove(_agentId);
  }

  Future<void> _closeConnection() async {
    await _database?.close();
    _database = null;
  }

  /// 删除该 Agent 的整个数据库文件并关闭连接
  ///
  /// 警告：此操作不可逆，将永久删除所有记忆数据。
  Future<void> deleteDatabase() async {
    if (!kIsWeb) {
      try {
        final path = join(await _resolveDirectoryPath(), _dbFileName);
        await _closeConnection();
        _instances.remove(_agentId);
        await databaseFactory.deleteDatabase(path);
        LoggerService().info(
          'Memory database deleted: $_dbFileName',
          tag: 'AgentMemoryDbService[$_agentId]',
        );
      } catch (e) {
        LoggerService().error(
          'Failed to delete database: $_dbFileName',
          tag: 'AgentMemoryDbService[$_agentId]',
          error: e,
        );
      }
      return;
    }
    await close();
  }
}
