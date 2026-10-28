import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

/// 切网后立刻发消息：sendControl 应在连接不可用时主动等待重连并补发，
/// 而不是立刻返回 false 让 UI 弹「配对设备未连接」。
void main() {
  final mgr = PeerConnectionManager.instance;

  setUp(() {
    mgr.debugTrySendControlOverride = null;
    mgr.debugCanSendNowOverride = null;
  });

  tearDown(() {
    mgr.debugTrySendControlOverride = null;
    mgr.debugCanSendNowOverride = null;
  });

  test('发送前探活失败 → 进入等待重连并补发', () async {
    var probeCalls = 0;
    var sendCalls = 0;
    var waiting = false;
    mgr.debugCanSendNowOverride = (peerId) async {
      probeCalls++;
      return false; // 半开连接：探活失败
    };
    mgr.debugTrySendControlOverride = (peerId, json) async {
      sendCalls++;
      return sendCalls >= 2; // 重连后第二次发送成功
    };

    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      waitForReconnect: const Duration(seconds: 2),
      onWaitingForReconnect: () => waiting = true,
    );

    expect(sent, isTrue);
    expect(waiting, isTrue);
    expect(probeCalls, 1, reason: '探活只做一次，不在重试循环里反复 ping');
    expect(sendCalls, 2);
  });

  test('发送前探活通过 → 直接发送，不进入重连等待', () async {
    var probeCalls = 0;
    var sendCalls = 0;
    var waiting = false;
    mgr.debugCanSendNowOverride = (peerId) async {
      probeCalls++;
      return true;
    };
    mgr.debugTrySendControlOverride = (peerId, json) async {
      sendCalls++;
      return true;
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
    expect(waiting, isFalse);
    expect(probeCalls, 1);
    expect(sendCalls, 1);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));
  });

  test('普通控制帧不探活，保持原有低延迟语义', () async {
    var probeCalls = 0;
    mgr.debugCanSendNowOverride = (peerId) async {
      probeCalls++;
      return false;
    };
    mgr.debugTrySendControlOverride = (peerId, json) async => false;

    final sent = await mgr.sendControl('peer-1', {'type': 'agent_list_req'});

    expect(sent, isFalse);
    expect(probeCalls, 0);
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

  test('绝对截止时间已到就不再等待或补发', () async {
    var sendCalls = 0;
    mgr.debugTrySendControlOverride = (peerId, json) async {
      sendCalls++;
      return true;
    };

    final sent = await mgr.sendControl(
      'peer-1',
      {'type': 'agent_chat'},
      waitForReconnect: const Duration(seconds: 2),
      deadline: DateTime.now().subtract(const Duration(milliseconds: 1)),
    );

    expect(sent, isFalse);
    expect(sendCalls, 0);
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
