import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

/// 切网后立刻发消息：sendControl 应在连接不可用时主动等待重连并补发，
/// 而不是立刻返回 false 让 UI 弹「配对设备未连接」。
void main() {
  final mgr = PeerConnectionManager.instance;

  setUp(() {
    mgr.debugTrySendControlOverride = null;
  });

  tearDown(() {
    mgr.debugTrySendControlOverride = null;
  });

  test('连接恢复后补发成功，并回报等待状态', () async {
    var calls = 0;
    var waiting = false;
    mgr.debugTrySendControlOverride = (peerId, json) async {
      calls++;
      return calls >= 3; // 前两次（含切网瞬间）失败，第三次连上
    };

    final stopwatch = Stopwatch()..start();
    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      waitForReconnect: const Duration(seconds: 2),
      onWaitingForReconnect: () => waiting = true,
    );
    stopwatch.stop();

    expect(sent, isTrue);
    expect(waiting, isTrue);
    expect(calls, greaterThanOrEqualTo(3));
    expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 100)));
  });

  test('等待窗口内始终连不上 → 返回 false 而不是无限等', () async {
    var calls = 0;
    mgr.debugTrySendControlOverride = (peerId, json) async {
      calls++;
      return false;
    };

    final stopwatch = Stopwatch()..start();
    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      waitForReconnect: const Duration(milliseconds: 350),
    );
    stopwatch.stop();

    expect(sent, isFalse);
    expect(calls, greaterThan(1));
    expect(stopwatch.elapsed, greaterThanOrEqualTo(
      const Duration(milliseconds: 300),
    ));
  });

  test('未指定 waitForReconnect 时保持原语义：立即返回 false、不等待', () async {
    var calls = 0;
    var waiting = false;
    mgr.debugTrySendControlOverride = (peerId, json) async {
      calls++;
      return false;
    };

    final stopwatch = Stopwatch()..start();
    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      onWaitingForReconnect: () => waiting = true,
    );
    stopwatch.stop();

    expect(sent, isFalse);
    expect(calls, 1);
    expect(waiting, isFalse);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));
  });

  test('用户在等待期间取消 → 提前放弃发送', () async {
    var calls = 0;
    var cancelled = false;
    mgr.debugTrySendControlOverride = (peerId, json) async {
      calls++;
      return false;
    };

    // 模拟用户在等待重连时点了停止。
    final cancelTimer =
        Timer(const Duration(milliseconds: 150), () => cancelled = true);

    final stopwatch = Stopwatch()..start();
    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      waitForReconnect: const Duration(seconds: 2),
      abortWhen: () => cancelled,
    );
    stopwatch.stop();
    cancelTimer.cancel();

    expect(sent, isFalse);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(calls, lessThanOrEqualTo(2));
  });
}
