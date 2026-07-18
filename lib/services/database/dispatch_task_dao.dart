import 'package:sqflite/sqflite.dart';
import '../../models/dispatch_task.dart';
import '../local_database_service.dart';

/// 派发任务（DispatchTask）相关的数据访问层。
extension DispatchTaskDao on LocalDatabaseService {
  /// 创建派发记录
  Future<void> createDispatchTask(DispatchTask task) async {
    final db = await database;
    await db.insert(
      'dispatch_tasks',
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 根据 ID 获取派发记录
  Future<DispatchTask?> getDispatchTaskById(String id) async {
    final db = await database;
    final results = await db.query(
      'dispatch_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
    return results.isEmpty ? null : DispatchTask.fromJson(results.first);
  }

  /// 列出派发记录（支持按状态 / 目标频道筛选）
  Future<List<DispatchTask>> listDispatchTasks({
    String? status,
    String? targetChannelId,
    String? sourceChannelId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    if (targetChannelId != null) {
      where.add('target_channel_id = ?');
      args.add(targetChannelId);
    }
    if (sourceChannelId != null) {
      where.add('source_channel_id = ?');
      args.add(sourceChannelId);
    }

    final results = await db.query(
      'dispatch_tasks',
      where: where.isNotEmpty ? where.join(' AND ') : null,
      whereArgs: args.isNotEmpty ? args : null,
      orderBy: 'created_at DESC',
    );

    return results.map((r) => DispatchTask.fromJson(r)).toList();
  }

  /// 更新派发记录
  Future<void> updateDispatchTask(DispatchTask task) async {
    final db = await database;
    await db.update(
      'dispatch_tasks',
      task.toJson(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  /// 将上次运行遗留的在途派发（pending/running）标记为失败。
  ///
  /// App 重启后内存中的完成事件订阅与定时器都已丢失，这些记录不可能再
  /// 闭环，启动时统一收尾，避免永远挂在 running 状态。
  Future<int> failStaleDispatchTasks() async {
    final db = await database;
    return db.rawUpdate(
      "UPDATE dispatch_tasks SET status = ?, error_message = ?, completed_at = ? "
      "WHERE status IN (?, ?)",
      [
        DispatchTask.statusError,
        'interrupted by app restart',
        DateTime.now().millisecondsSinceEpoch,
        DispatchTask.statusPending,
        DispatchTask.statusRunning,
      ],
    );
  }

  /// 单个 agent 的派发战绩（{status: count}，仅终态记录）。
  Future<Map<String, int>> getDispatchStatsForAgent(String agentId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS cnt FROM dispatch_tasks '
      'WHERE target_agent_id = ? AND status IN (?, ?, ?) GROUP BY status',
      [
        agentId,
        DispatchTask.statusDone,
        DispatchTask.statusError,
        DispatchTask.statusTimeout,
      ],
    );
    return {
      for (final r in rows) r['status'] as String: (r['cnt'] as num).toInt(),
    };
  }
}
