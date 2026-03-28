import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// She 专用记忆数据库服务
///
/// 为内置 Agent"She"的记忆数据（soul、long_term_memory、heartbeat 等）
/// 提供独立的 SQLite 数据库文件存储。
///
/// ### 数据库命名
/// 文件名：`she_memory.db`（固定名，She 是单例）
/// 位置：与 `she_profile.db` 和 `shepaw.db` 同目录
///
/// ### 表结构（she_memory）
/// | 字段名    | 类型    | 说明 |
/// |----------|---------|-----|
/// | id       | INTEGER PK AUTOINCREMENT | 自增主键（为了与 Agent 记忆系统一致） |
/// | key      | TEXT NOT NULL UNIQUE | 记忆键（如 'soul', 'heartbeat' 等） |
/// | value    | TEXT NOT NULL | 记忆内容 |
/// | updated_at | INTEGER NOT NULL | 最后更新时间戳（毫秒） |
///
/// ### 使用示例
/// ```dart
/// final sheMemDb = SheMemoryDbService.instance;
/// await sheMemDb.setSheMemory('soul', 'I am She...');
/// final soul = await sheMemDb.getSheMemory('soul');
/// ```
class SheMemoryDbService {
  static final SheMemoryDbService _instance = SheMemoryDbService._internal();
  factory SheMemoryDbService() => _instance;

  /// 获取单例
  static SheMemoryDbService get instance => _instance;

  SheMemoryDbService._internal();

  Database? _database;
  static const int _dbVersion = 1;
  static const String _dbName = 'she_memory.db';

  /// 获取数据库实例（懒加载）
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'she_memory',
        version: _dbVersion,
        onCreate: _onCreate,
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE she_memory (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        key        TEXT NOT NULL UNIQUE,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // 按 key 查询索引
    await db.execute(
      'CREATE INDEX idx_she_memory_key ON she_memory(key)',
    );
  }

  // ---------------------------------------------------------------------------
  // CRUD 操作（与旧系统相同 API）
  // ---------------------------------------------------------------------------

  /// 读取单条 She 记忆
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

  /// 写入（或覆盖）单条 She 记忆
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

  /// 获取全部 She 记忆，返回 `Map<key, value>`
  Future<Map<String, String>> getAllSheMemory() async {
    final db = await database;
    final results = await db.query('she_memory');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  /// 删除单条 She 记忆
  Future<void> deleteSheMemory(String key) async {
    final db = await database;
    await db.delete('she_memory', where: 'key = ?', whereArgs: [key]);
  }

  /// 清空全部 She 记忆
  Future<void> clearSheMemory() async {
    final db = await database;
    await db.delete('she_memory');
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 关闭数据库连接
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// 删除整个数据库文件
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
