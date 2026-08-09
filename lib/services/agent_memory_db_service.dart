import 'dart:io' show File;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/agent_memory_entry.dart';
import 'logger_service.dart';
import '../storage/runtime_mirror_service.dart';

/// Agent 独立记忆数据库服务（**遗留**）。
///
/// 新权威为储物袋 [AgentMemoryStoreService]（`memory/<agentId>/entries/`）。
/// 本类仅保留供一次性迁移与旧备份扫描；业务请走 [AgentMemoryBizService]。
class AgentMemoryDbService {
  // ---------------------------------------------------------------------------
  // 单例实例池（每个 agentId 对应一个服务实例）
  // ---------------------------------------------------------------------------

  static final Map<String, AgentMemoryDbService> _instances = {};

  /// 获取指定 Agent 的数据库服务（单例）
  static AgentMemoryDbService forAgent(String agentId) {
    return _instances.putIfAbsent(
      agentId,
      () => AgentMemoryDbService._(agentId),
    );
  }

  /// 关闭并移除所有缓存的实例（App 退出时调用）
  static Future<void> closeAll() async {
    for (final service in _instances.values) {
      await service.close();
    }
    _instances.clear();
  }

  /// 删除所有 Agent 的记忆数据库文件（用于「清除全部数据」）。
  ///
  /// 先关闭并清空实例缓存，再扫描文档目录删除 `agent_memory_*.db`，
  /// 因此连缓存之外的（如已删除 Agent 遗留的）记忆库也会被清除。
  static Future<void> deleteAllDatabases() async {
    await closeAll();
    try {
      final directory = await getApplicationDocumentsDirectory();
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.contains('agent_memory_') && entity.path.endsWith('.db')) {
          await entity.delete();
          LoggerService().info(
            'Memory database deleted: ${entity.path}',
            tag: 'AgentMemoryDbService',
          );
        }
      }
    } catch (e) {
      LoggerService().error(
        'Failed to delete agent memory databases',
        tag: 'AgentMemoryDbService',
        error: e,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 实例成员
  // ---------------------------------------------------------------------------

  final String _agentId;
  Database? _database;
  static const int _dbVersion = 1;

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
    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, _dbFileName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE memories (
        memory_id      INTEGER PRIMARY KEY AUTOINCREMENT,
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
  }

  // ---------------------------------------------------------------------------
  // CRUD 操作
  // ---------------------------------------------------------------------------

  /// 添加一条记忆，返回数据库自增的 memory_id
  Future<int> addMemory(AgentMemoryEntry entry) async {
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final effectiveEntry = entry.copyWith(
        createdAt: entry.createdAt == 0 ? now : entry.createdAt,
        updatedAt: now,
      );
      final id = await db.insert(
        'memories',
        effectiveEntry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      LoggerService().info(
        'Memory added: #$id',
        tag: 'AgentMemoryDbService[$_agentId]',
      );
      RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
      // Best-effort export of recent memories as markdown
      // ignore: unawaited_futures
      _exportMemoryMarkdown();
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
      final updated = entry.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      final count = await db.update(
        'memories',
        updated.toMap(),
        where: 'memory_id = ?',
        whereArgs: [entry.memoryId],
      );
      if (count == 0) {
        LoggerService().warning(
          'updateMemory: no row matched for id=${entry.memoryId}',
          tag: 'AgentMemoryDbService[$_agentId]',
        );
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
      await db.delete('memories', where: 'memory_id = ?', whereArgs: [memoryId]);
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

  Future<void> _exportMemoryMarkdown() async {
    try {
      final entries = await getAllMemories(limit: 200);
      final buf = StringBuffer('# Memory export\n\n');
      for (final e in entries) {
        buf.writeln('- (${e.memoryType.name}) ${e.memoryContent}');
      }
      await RuntimeMirrorService.instance.mirrorMemory(_agentId, buf.toString());
    } catch (e) {
      LoggerService().warning(
        'memory.md export failed: $e',
        tag: 'AgentMemoryDbService[$_agentId]',
      );
    }
  }

  /// 关闭数据库连接（不删除文件）
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _instances.remove(_agentId);
  }

  /// 删除该 Agent 的整个数据库文件并关闭连接
  ///
  /// 警告：此操作不可逆，将永久删除所有记忆数据。
  Future<void> deleteDatabase() async {
    await close();
    try {
      final directory = await getApplicationDocumentsDirectory();
      final path = join(directory.path, _dbFileName);
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
  }
}
