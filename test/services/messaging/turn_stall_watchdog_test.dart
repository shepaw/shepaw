import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/messaging/agent_messaging_service.dart';
import 'package:shepaw/services/task/task_models.dart';

void main() {
  group('ActiveTask activity tracking', () {
    test('markActivity refreshes lastActivityAtMs', () {
      final task = ActiveTask(
        taskId: 't1',
        agentId: 'a1',
        agentName: 'Agent',
        channelId: 'c1',
        userMessageId: 'm1',
        userId: 'user',
        userName: 'User',
      );
      final before = task.lastActivityAtMs;
      // Force the clock forward: simulate an inbound frame some time later.
      task.lastActivityAtMs = before - 5000;
      expect(task.lastActivityAtMs, before - 5000);
      task.markActivity();
      expect(task.lastActivityAtMs, greaterThanOrEqualTo(before));
    });

    test('rawStreamLength starts at 0 and accumulates', () {
      final task = ActiveTask(
        taskId: 't1',
        agentId: 'a1',
        agentName: 'Agent',
        channelId: 'c1',
        userMessageId: 'm1',
        userId: 'user',
        userName: 'User',
      );
      expect(task.rawStreamLength, 0);
      task.rawStreamLength += 'hello'.length;
      expect(task.rawStreamLength, 5);
    });

    test('stallTimeout defaults to 180s', () {
      final task = ActiveTask(
        taskId: 't1',
        agentId: 'a1',
        agentName: 'Agent',
        channelId: 'c1',
        userMessageId: 'm1',
        userId: 'user',
        userName: 'User',
      );
      expect(task.stallTimeout, const Duration(seconds: 180));
    });
  });

  group('stalledTurns', () {
    ActiveTask task({required String id, required String agentId, bool complete = false}) {
      final t = ActiveTask(
        taskId: id,
        agentId: agentId,
        agentName: 'Agent',
        channelId: 'c',
        userMessageId: 'm',
        userId: 'user',
        userName: 'User',
      );
      if (complete) t.isComplete = true;
      return t;
    }

    test('skips complete tasks, missing conns, and recent activity', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final done = task(id: 'done', agentId: 'a1', complete: true);
      final noConn = task(id: 'noconn', agentId: 'missing');
      final fresh = task(id: 'fresh', agentId: 'a1')..lastActivityAtMs = now - 1000;
      final stalled = task(id: 'stalled', agentId: 'a1')
        ..lastActivityAtMs = now - 200000;

      final conn = _FakeResumeConnection(const []);
      final result = stalledTurns(
        activeTasks: {
          done.taskId: done,
          noConn.taskId: noConn,
          fresh.taskId: fresh,
          stalled.taskId: stalled,
        },
        connections: {'a1': conn},
        nowMs: now,
      );
      expect(result.map((t) => t.taskId), ['stalled']);
    });

    test('skips tasks whose connection is not connected', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final stalled = task(id: 's', agentId: 'a1')..lastActivityAtMs = now - 200000;
      final conn = _FakeResumeConnection(const [])..connected = false;
      final result = stalledTurns(
        activeTasks: {stalled.taskId: stalled},
        connections: {'a1': conn},
        nowMs: now,
      );
      expect(result, isEmpty);
    });

    test('returns multiple stalled tasks', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = task(id: 's1', agentId: 'a1')..lastActivityAtMs = now - 200000;
      final s2 = task(id: 's2', agentId: 'a2')..lastActivityAtMs = now - 200000;
      final conn = _FakeResumeConnection(const []);
      final result = stalledTurns(
        activeTasks: {s1.taskId: s1, s2.taskId: s2},
        connections: {'a1': conn, 'a2': conn},
        nowMs: now,
      );
      expect(result.length, 2);
    });
  });

  group('resumeTaskAndDispatch', () {
    test('done status routes delta to onTextContent and metadata to onTaskCompleted',
        () async {
      final conn = _FakeResumeConnection([
        {
          'status': 'done',
          'delta': ' tail',
          'content': 'full content',
          'metadata': {'usage': {'input_tokens': 10}, 'trace_id': 'tr'},
        },
      ]);
      final texts = <String>[];
      Map<String, dynamic>? completed;
      Map<String, dynamic>? errored;
      conn.registerTaskCallbacks('t1', TaskCallbacks(
        onTextContent: (data) => texts.add(data['content'] as String),
        onTaskCompleted: (data) => completed = data,
        onTaskError: (data) => errored = data,
      ));

      await conn.resumeTaskAndDispatch('t1', 3);

      expect(texts, [' tail']);
      expect(conn.lastKnownLength, 3);
      expect(completed, {'usage': {'input_tokens': 10}, 'trace_id': 'tr'});
      expect(errored, isNull);
    });

    test('streaming status routes delta without completing', () async {
      final conn = _FakeResumeConnection([
        {'status': 'streaming', 'delta': ' more'},
      ]);
      final texts = <String>[];
      var completed = false;
      Map<String, dynamic>? errored;
      conn.registerTaskCallbacks('t1', TaskCallbacks(
        onTextContent: (data) => texts.add(data['content'] as String),
        onTaskCompleted: (_) => completed = true,
        onTaskError: (data) => errored = data,
      ));

      await conn.resumeTaskAndDispatch('t1', 0);

      expect(texts, [' more']);
      expect(completed, isFalse);
      expect(errored, isNull);
    });

    test('error status routes onTaskError', () async {
      final conn = _FakeResumeConnection([
        {'status': 'error', 'message': 'boom'},
      ]);
      Map<String, dynamic>? errored;
      var completed = false;
      conn.registerTaskCallbacks('t1', TaskCallbacks(
        onTaskCompleted: (_) => completed = true,
        onTaskError: (data) => errored = data,
      ));

      await conn.resumeTaskAndDispatch('t1', 0);

      expect(errored, {'message': 'boom'});
      expect(completed, isFalse);
    });

    test('lost status routes onTaskError with a message', () async {
      final conn = _FakeResumeConnection([
        {'status': 'lost', 'message': 'task unknown or expired'},
      ]);
      Map<String, dynamic>? errored;
      conn.registerTaskCallbacks('t1', TaskCallbacks(
        onTaskError: (data) => errored = data,
      ));

      await conn.resumeTaskAndDispatch('t1', 0);

      expect(errored, isNotNull);
      expect(errored!['message'], 'task unknown or expired');
    });

    test('no registered callbacks is a safe no-op', () async {
      final conn = _FakeResumeConnection([
        {'status': 'done', 'delta': '', 'content': 'x', 'metadata': <String, dynamic>{}},
      ]);
      await conn.resumeTaskAndDispatch('missing-task', 0);
      // Should not throw.
    });
  });
}

/// 可控的 ACP 连接 double：覆写 sendRequest 返回 canned 的 taskResume 响应。
class _FakeResumeConnection extends ACPAgentConnection {
  _FakeResumeConnection(this.responses) : super(agentId: 'fake');

  final List<Map<String, dynamic>> responses;
  int resumeCalls = 0;
  int? lastKnownLength;
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  Future<ACPResponse> sendRequest(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    if (method != ACPMethod.agentTaskResume) {
      return ACPResponse.error(id: -1, code: -32601, message: 'unexpected');
    }
    lastKnownLength = params?['known_length'] as int?;
    final idx = resumeCalls++;
    if (idx >= responses.length) {
      return ACPResponse.error(id: idx + 1, code: -32601, message: 'no canned');
    }
    return ACPResponse.success(id: idx + 1, result: responses[idx]);
  }
}
