import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/agent_messaging_service.dart';
import 'package:shepaw/services/task/task_models.dart';

ActiveTask _task(String id, {String agentId = 'she'}) {
  return ActiveTask(
    taskId: id,
    agentId: agentId,
    agentName: '惜宝',
    channelId: 'ch',
    userMessageId: 'user-msg',
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
}
