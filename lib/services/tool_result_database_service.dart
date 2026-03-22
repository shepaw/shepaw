import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// 独立的工具执行结果数据库服务。
///
/// ### 为什么独立？
/// `tool_executions.full_result` 存储完整的工具输出，单行可达几百 KB
/// 到数 MB（代码文件、shell 输出、图片 base64 等）。随对话积累，这张表
/// 会是整体数据库文件体积的主要贡献者。SQLite 所有表共享同一个文件锁，
/// 将其独立到 `tool_results.db` 可避免大事务写入阻塞对 `messages` /
/// `channels` 等核心表的并发读取。
///
/// ### 与主库的关联
/// 由于不同 SQLite 文件之间无法直接使用外键，原有的
/// `FOREIGN KEY (message_id) REFERENCES messages` 约束改由应用层保证：
///   - 删除 channel 时：调用 [deleteByChannel]
///   - 删除单条消息时：调用 [deleteByMessage]
class ToolResultDatabaseService {
  static final ToolResultDatabaseService _instance =
      ToolResultDatabaseService._internal();
  factory ToolResultDatabaseService() => _instance;
  ToolResultDatabaseService._internal();

  Database? _database;

  static const int _version = 1;
  static const String _dbName = 'tool_results.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (kIsWeb) {
      return await openDatabase(
        'tool_results',
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
    // 工具执行记录表
    // 每条 assistant 消息中调用的每个工具在这里存一行，
    // tool_use 和 tool_result 通过 tool_call_id 关联。
    // summary   压缩摘要，注入 LLM 上下文时使用（≤ 300 字符）。
    // full_result 完整结果的 JSON 序列化字符串，按需拉取。
    // result_type 决定如何反序列化 full_result：
    //   'text'           → 纯文本
    //   'content_blocks' → Anthropic content block 数组（含图片等）
    //   'binary_ref'     → 大型文件引用（仅存路径，不内联 base64）
    await db.execute('''
      CREATE TABLE tool_executions (
        id            TEXT PRIMARY KEY,
        message_id    TEXT NOT NULL,
        channel_id    TEXT NOT NULL,
        tool_call_id  TEXT NOT NULL,
        tool_name     TEXT NOT NULL,
        arguments     TEXT,
        result_type   TEXT NOT NULL DEFAULT 'text',
        summary       TEXT,
        full_result   TEXT,
        status        TEXT NOT NULL DEFAULT 'pending',
        executed_at   INTEGER
      )
    ''');

    // 按 message 查询（历史重建用）
    await db.execute(
      'CREATE INDEX idx_tr_message ON tool_executions(message_id)',
    );
    // 按 channel 删除（级联清理用）
    await db.execute(
      'CREATE INDEX idx_tr_channel ON tool_executions(channel_id, executed_at DESC)',
    );
    // tool_call_id 全局唯一（幂等写入用）
    await db.execute(
      'CREATE UNIQUE INDEX idx_tr_call_id ON tool_executions(tool_call_id)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 预留：未来版本的迁移逻辑
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// 写入一条工具执行骨架记录（tool_use 阶段，result 暂为 null）。
  ///
  /// 使用 [ConflictAlgorithm.ignore] 保证幂等：同一 [toolCallId] 重复写入
  /// 时静默忽略，不会抛出异常。
  Future<void> createToolExecution({
    required String id,
    required String messageId,
    required String channelId,
    required String toolCallId,
    required String toolName,
    Map<String, dynamic>? arguments,
  }) async {
    final db = await database;
    await db.insert(
      'tool_executions',
      {
        'id': id,
        'message_id': messageId,
        'channel_id': channelId,
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'arguments': arguments != null ? jsonEncode(arguments) : null,
        'status': 'pending',
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 回填工具执行结果（tool_result 阶段）。
  ///
  /// [resultType] 取值：`'text'` | `'content_blocks'` | `'binary_ref'`
  Future<void> updateToolExecutionResult({
    required String toolCallId,
    required String resultType,
    required String summary,
    required String fullResult,
    String status = 'completed',
  }) async {
    final db = await database;
    await db.update(
      'tool_executions',
      {
        'result_type': resultType,
        'summary': summary,
        'full_result': fullResult,
        'status': status,
        'executed_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'tool_call_id = ?',
      whereArgs: [toolCallId],
    );
  }

  /// 按 [toolCallId] 查询单条记录。
  Future<Map<String, dynamic>?> getToolExecutionByCallId(
    String toolCallId,
  ) async {
    final db = await database;
    final results = await db.query(
      'tool_executions',
      where: 'tool_call_id = ?',
      whereArgs: [toolCallId],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 批量获取多条消息关联的工具执行记录。
  ///
  /// 返回 `Map<messageId, List<record>>`，供历史重建时批量使用，
  /// 避免 N+1 查询。
  Future<Map<String, List<Map<String, dynamic>>>> getToolExecutionsByMessageIds(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(messageIds.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT * FROM tool_executions '
      'WHERE message_id IN ($placeholders) '
      'ORDER BY executed_at ASC',
      messageIds,
    );
    final result = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final mid = row['message_id'] as String;
      result.putIfAbsent(mid, () => []).add(row);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 级联删除（替代跨库外键约束）
  // ---------------------------------------------------------------------------

  /// 删除某条消息关联的所有工具执行记录。
  ///
  /// 应在 [LocalDatabaseService.deleteMessage] 之后调用。
  Future<void> deleteByMessage(String messageId) async {
    final db = await database;
    await db.delete(
      'tool_executions',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// 删除某个 channel 关联的所有工具执行记录。
  ///
  /// 应在 [LocalDatabaseService.deleteChannel] 之后调用。
  Future<void> deleteByChannel(String channelId) async {
    final db = await database;
    await db.delete(
      'tool_executions',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
  }

  /// 清空全部工具执行记录（测试 / 重置用）。
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('tool_executions');
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
