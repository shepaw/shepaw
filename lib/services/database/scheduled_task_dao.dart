import 'package:sqflite/sqflite.dart';
import '../../task/models/scheduled_task.dart';
import '../local_database_service.dart';

/// 定时任务（ScheduledTask）相关的数据访问层。
extension ScheduledTaskDao on LocalDatabaseService {
  /// 创建定时任务
  Future<void> createScheduledTask(ScheduledTask task) async {
    final db = await database;
    await db.insert(
      'scheduled_tasks',
      task.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 根据 ID 获取定时任务
  Future<ScheduledTask?> getScheduledTaskById(String id) async {
    final db = await database;
    final results = await db.query(
      'scheduled_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
    return results.isEmpty ? null : ScheduledTask.fromJson(results.first);
  }

  /// 列出定时任务（支持筛选）
  Future<List<ScheduledTask>> listScheduledTasks({
    String? agentId,
    String? status,
    String? channelId,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <dynamic>[];

    if (agentId != null) {
      where.add('agent_id = ?');
      args.add(agentId);
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    if (channelId != null) {
      where.add('channel_id = ?');
      args.add(channelId);
    }

    final results = await db.query(
      'scheduled_tasks',
      where: where.isNotEmpty ? where.join(' AND ') : null,
      whereArgs: args.isNotEmpty ? args : null,
      orderBy: 'next_run_at ASC',
    );

    return results.map((r) => ScheduledTask.fromJson(r)).toList();
  }

  /// 获取到期执行的定时任务
  Future<List<ScheduledTask>> getTasksDueForExecution({int? beforeTime}) async {
    final db = await database;
    final now = beforeTime ?? DateTime.now().millisecondsSinceEpoch;

    final results = await db.query(
      'scheduled_tasks',
      where: 'status = ? AND next_run_at <= ?',
      whereArgs: [ScheduledTask.statusActive, now],
      orderBy: 'next_run_at ASC',
    );

    return results.map((r) => ScheduledTask.fromJson(r)).toList();
  }

  /// 更新定时任务
  Future<void> updateScheduledTask(ScheduledTask task) async {
    final db = await database;
    await db.update(
      'scheduled_tasks',
      task.toJson(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  /// 删除定时任务
  Future<void> deleteScheduledTask(String id) async {
    final db = await database;
    await db.delete(
      'scheduled_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
