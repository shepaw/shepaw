@Tags(['needs-plugins'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/dispatch_task.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// dispatch_tasks 表的状态机测试（DAO 层）。
/// Needs path_provider + sqflite harness; excluded from default CI via `needs-plugins`.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DispatchTaskDao state machine', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
    });

    DispatchTask makeTask(String id, {String status = DispatchTask.statusPending}) =>
        DispatchTask(
          id: id,
          sourceChannelId: 'dm_she_user',
          targetAgentId: 'agent-$id',
          targetAgentName: 'agent-$id',
          targetChannelId: 'dm_user_agent_$id',
          prompt: 'task $id',
          status: status,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        );

    test('create → running → done 全链路', () async {
      final id = 'dao-flow-${DateTime.now().microsecondsSinceEpoch}';
      await db.createDispatchTask(makeTask(id));

      var task = await db.getDispatchTaskById(id);
      expect(task, isNotNull);
      expect(task?.status, DispatchTask.statusPending);

      await db.updateDispatchTask(task!.copyWith(
        status: DispatchTask.statusRunning,
        userMessageId: 'msg-$id',
        statusMessageId: 'status-$id',
      ));
      task = await db.getDispatchTaskById(id);
      expect(task?.status, DispatchTask.statusRunning);
      expect(task?.userMessageId, 'msg-$id');
      expect(task?.isTerminal, isFalse);

      await db.updateDispatchTask(task!.copyWith(
        status: DispatchTask.statusDone,
        resultSummary: 'ok',
        completedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      task = await db.getDispatchTaskById(id);
      expect(task?.status, DispatchTask.statusDone);
      expect(task?.resultSummary, 'ok');
      expect(task?.isTerminal, isTrue);
    });

    test('listDispatchTasks 按 status / targetChannelId 过滤', () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final running = makeTask('dao-filter-r-$suffix',
          status: DispatchTask.statusRunning);
      final done = makeTask('dao-filter-d-$suffix',
          status: DispatchTask.statusDone);

      await db.createDispatchTask(running);
      await db.createDispatchTask(done);

      final runningList = await db.listDispatchTasks(
          status: DispatchTask.statusRunning,
          targetChannelId: running.targetChannelId);
      expect(runningList.map((t) => t.id), contains(running.id));
      expect(runningList.map((t) => t.id), isNot(contains(done.id)));
    });

    test('failStaleDispatchTasks 只清扫 pending/running', () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final stale = makeTask('dao-stale-$suffix',
          status: DispatchTask.statusRunning);
      final finished = makeTask('dao-finished-$suffix',
          status: DispatchTask.statusDone);

      await db.createDispatchTask(stale);
      await db.createDispatchTask(finished);

      await db.failStaleDispatchTasks();

      final staleAfter = await db.getDispatchTaskById(stale.id);
      expect(staleAfter?.status, DispatchTask.statusError);
      expect(staleAfter?.errorMessage, 'interrupted by app restart');
      expect(staleAfter?.completedAtMs, isNotNull);

      final finishedAfter = await db.getDispatchTaskById(finished.id);
      expect(finishedAfter?.status, DispatchTask.statusDone);
    });
  });
}
