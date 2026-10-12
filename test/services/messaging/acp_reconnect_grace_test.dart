import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/services/acp_agent_connection.dart';

/// 掉线宽限：切网时不能在掉线瞬间就把在跑的回合判死 —— 主机上的回合照常在跑，
/// 要给它一个「重连 + resume」的窗口。
void main() {
  group('disconnect failTasks', () {
    test('主动断开立刻把在跑的回合判失败', () async {
      final errors = <String>[];
      final conn = ACPAgentConnection(agentId: 'a1');
      conn.registerTaskCallbacks(
        't1',
        TaskCallbacks(onTaskError: (d) => errors.add(d['message'] as String)),
      );

      await conn.disconnect();

      expect(errors, isNotEmpty);
    });

    test('掉线不立刻判失败，宽限期到点才判', () async {
      final errors = <String>[];
      final conn = ACPAgentConnection(
        agentId: 'a1',
        // 没配 wsUrl/token，_tryReconnect 会立刻返回，不会干扰这条用例。
        reconnectGrace: const Duration(milliseconds: 60),
      );
      conn.registerTaskCallbacks(
        't1',
        TaskCallbacks(onTaskError: (d) => errors.add(d['message'] as String)),
      );

      await conn.disconnect(failTasks: false);
      // 掉线瞬间：回合还在主机上跑着，不能判死。
      expect(errors, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errors, isNotEmpty);
    });
  });

  group('probeAlive', () {
    test('ping 通则 alive', () async {
      final conn = _PingConnection(alive: true);
      expect(await conn.probeAlive(), isTrue);
    });

    test('ping 不通则不 alive（半开连接靠它发现）', () async {
      final conn = _PingConnection(alive: false);
      expect(await conn.probeAlive(), isFalse);
    });
  });

  group('resumeTaskAndDispatch', () {
    test('同一回合并发续传只发一次请求', () async {
      final conn = _FakeResumeConnection([
        {'status': 'streaming', 'delta': 'more'},
      ]);
      final texts = <String>[];
      conn.registerTaskCallbacks(
        't1',
        TaskCallbacks(onTextContent: (d) => texts.add(d['content'] as String)),
      );

      // 重连续传和停滞看门狗可能同时盯上同一个回合：两次都带同样的
      // known_length，不禁重入就会把同一段文本贴两遍。
      await Future.wait([
        conn.resumeTaskAndDispatch('t1', 3),
        conn.resumeTaskAndDispatch('t1', 3),
      ]);

      expect(conn.resumeCalls, 1);
      expect(texts, ['more']);
    });
  });
}

class _PingConnection extends ACPAgentConnection {
  _PingConnection({required this.alive}) : super(agentId: 'ping');

  final bool alive;

  @override
  bool get isConnected => true;

  // 直接覆写 ping：真实的 sendRequest 会把帧交给 Noise 会话加密，这个 double
  // 没有会话，会静默丢帧导致 future 永不完成。
  @override
  Future<ACPResponse> ping() async {
    if (!alive) throw Exception('ping failed');
    return ACPResponse.success(id: 1, result: <String, dynamic>{});
  }
}

/// 可控的 ACP 连接 double：覆写 sendRequest 返回 canned 的 taskResume 响应。
class _FakeResumeConnection extends ACPAgentConnection {
  _FakeResumeConnection(this.responses) : super(agentId: 'fake');

  final List<Map<String, dynamic>> responses;
  int resumeCalls = 0;
  int? lastKnownLength;

  @override
  bool get isConnected => true;

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
