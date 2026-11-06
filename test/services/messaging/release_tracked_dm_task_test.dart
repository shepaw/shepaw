import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/agent_messaging_service.dart';
import 'package:shepaw/services/task/task_models.dart';

ActiveTask _task(
  String id, {
  String agentId = 'she',
  String userMessageId = 'user-msg',
}) {
  return ActiveTask(
    taskId: id,
    agentId: agentId,
    agentName: '惜宝',
    channelId: 'ch',
    userMessageId: userMessageId,
    userId: 'user',
    userName: 'User',
  );
}

/// 与 ChatService._updateTypingAgentIds 同一条规则：未结束的任务才算输入中。
Set<String> _typingAgentIds(Map<String, ActiveTask> tasks) => tasks.values
    .where((task) => !task.isComplete)
    .map((task) => task.agentId)
    .toSet();

void main() {
  test('回合结束后从活跃表卸下，输入中状态被刷掉', () {
    final task = _task('t1');
    final tasks = {'ch': task};
    final typing = <Set<String>>[];
    final released = <String>[];
    var finished = 0;
    task.onTaskFinished = () => finished++;

    releaseTrackedDmTask(
      activeTasks: tasks,
      channelId: 'ch',
      task: task,
      updateTypingAgentIds: () => typing.add(_typingAgentIds(tasks)),
      releaseForegroundTask: released.add,
    );

    expect(tasks, isEmpty);
    expect(task.isComplete, isTrue);
    expect(task.dbSaveCompleter.isCompleted, isTrue);
    expect(typing, [<String>{}]);
    expect(released, ['惜宝']);
    expect(finished, 1);
  });

  test('频道上已有更新的回合时，不把它一起清掉', () {
    final finished = _task('old');
    final newer = _task('new');
    final tasks = {'ch': newer};
    final typing = <Set<String>>[];
    final released = <String>[];

    releaseTrackedDmTask(
      activeTasks: tasks,
      channelId: 'ch',
      task: finished,
      updateTypingAgentIds: () => typing.add(_typingAgentIds(tasks)),
      releaseForegroundTask: released.add,
    );

    expect(tasks['ch'], same(newer));
    expect(newer.isComplete, isFalse);
    expect(typing, [
      {'she'},
    ]);
    expect(released, ['惜宝']);
    expect(finished.dbSaveCompleter.isCompleted, isTrue);
  });

  test('重复收尾不会再次释放前台，也不会再次回调', () {
    final task = _task('t1');
    final tasks = {'ch': task};
    final released = <String>[];
    var finished = 0;
    task.onTaskFinished = () => finished++;

    void release() {
      releaseTrackedDmTask(
        activeTasks: tasks,
        channelId: 'ch',
        task: task,
        updateTypingAgentIds: () {},
        releaseForegroundTask: released.add,
      );
    }

    release();
    release();

    expect(released, ['惜宝']);
    expect(finished, 1);
  });

  test('已经被标成结束的任务只刷新列表，不再触发结束回调', () {
    final task = _task('t1');
    task.isComplete = true;
    final tasks = {'ch': task};
    var finished = 0;
    task.onTaskFinished = () => finished++;
    var typingUpdates = 0;

    releaseTrackedDmTask(
      activeTasks: tasks,
      channelId: 'ch',
      task: task,
      updateTypingAgentIds: () => typingUpdates++,
      releaseForegroundTask: (_) {},
    );

    expect(tasks, isEmpty);
    expect(typingUpdates, 1);
    expect(finished, 0);
    expect(task.dbSaveCompleter.isCompleted, isTrue);
  });

  group('排队回合的 ActiveTask 归属', () {
    test('队列重排后按 userMessageId 提成开跑的那条，不是 FIFO', () {
      final b = _task('B', userMessageId: 'msg-b');
      final c = _task('C', userMessageId: 'msg-c');
      final held = <ActiveTask>[b, c];

      final promoted = takeDeferredDmTask(held, 'msg-c');

      expect(promoted, same(c));
      expect(held, <ActiveTask>[b], reason: '没开跑的 B 要继续挂着等');
    });

    test('队列里没有这条时不误提成别人', () {
      final b = _task('B', userMessageId: 'msg-b');
      final held = <ActiveTask>[b];
      expect(takeDeferredDmTask(held, 'msg-z'), isNull);
      expect(held, <ActiveTask>[b]);
    });

    test('恢复出来的空 userMessageId 任务不会被别的回合收走', () {
      final restored = _task('restored', userMessageId: '');
      final tasks = <String, ActiveTask>{'ch': restored};

      expect(takeOwnedDmTask(tasks, 'ch', 'fresh-msg'), isNull);
      expect(tasks['ch'], same(restored));
    });

    test('id 精确匹配时才从活跃表摘掉', () {
      final mine = _task('mine', userMessageId: 'msg-1');
      final tasks = <String, ActiveTask>{'ch': mine};
      expect(takeOwnedDmTask(tasks, 'ch', 'msg-1'), same(mine));
      expect(tasks, isEmpty);
    });

    test('被后来回合顶出活跃表时，先结束那条仍要释放前台并收口 dbSave', () {
      final displaced = _task('A', userMessageId: 'msg-a');
      final newer = _task('B', userMessageId: 'msg-b');
      final released = <String>[];

      // 模拟 A 收尾：_takeOwnedTask 认出当前任务已换成 B，返回 null。
      final fromMap = takeOwnedDmTask({'ch': newer}, 'ch', 'msg-a');
      expect(fromMap, isNull);

      finishOwnedDmTask(
        owned: displaced,
        fromMap: fromMap,
        releaseForegroundTask: released.add,
      );

      expect(released, ['惜宝'], reason: 'ForegroundTaskService 是引用计数，漏一次永不归零');
      expect(displaced.dbSaveCompleter.isCompleted, isTrue);
    });

    test('同一任务被 owned 和 fromMap 同时指向时只释放一次', () {
      final task = _task('t1');
      final released = <String>[];

      finishOwnedDmTask(
        owned: task,
        fromMap: task,
        releaseForegroundTask: released.add,
      );

      expect(released, hasLength(1));
      expect(task.dbSaveCompleter.isCompleted, isTrue);
    });
  });
}
