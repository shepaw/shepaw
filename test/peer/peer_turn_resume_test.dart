import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_turn_resume.dart';

void main() {
  group('applyResumeDelta', () {
    test('skip=0 — 全量应用（无 live 重叠）', () {
      expect(
        applyResumeDelta(delta: 'world', receivedLength: 6, baseLength: 6),
        'world',
      );
    });

    test('部分跳过 — resume 发出后有 live chunk 先到达', () {
      // resume(K=6) 发出后，live chunk 'wor' 先到达（receivedLength=9），
      // delta='world' 中前 3 个码元与 live 重叠。
      expect(
        applyResumeDelta(delta: 'world', receivedLength: 9, baseLength: 6),
        'ld',
      );
    });

    test('全跳过 — 重复 resume（delta 已全部通过 live 收到）', () {
      expect(
        applyResumeDelta(delta: 'world', receivedLength: 11, baseLength: 6),
        '',
      );
    });

    test('空 delta', () {
      expect(applyResumeDelta(delta: '', receivedLength: 6, baseLength: 6), '');
    });

    test('skip 越界 clamp（receivedLength 异常小于 base）', () {
      expect(
        applyResumeDelta(delta: 'world', receivedLength: 3, baseLength: 6),
        'world',
      );
    });

    test('skip 大于 delta 长度 clamp 为空串', () {
      expect(
        applyResumeDelta(delta: 'abc', receivedLength: 100, baseLength: 6),
        '',
      );
    });
  });

  group('evaluateTurnWatchdog', () {
    final startedAt = DateTime(2026, 7, 20, 12, 0, 0);
    const chatTimeout = Duration(seconds: 300);
    const suspendCap = Duration(minutes: 10);
    const hardCap = Duration(minutes: 25);

    test('正常活动 → none', () {
      final now = startedAt.add(const Duration(seconds: 60));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('持续有输出时 idle 计时重置 → none', () {
      final lastOutput = startedAt.add(const Duration(minutes: 4, seconds: 50));
      final now = startedAt.add(const Duration(minutes: 5, seconds: 30));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: lastOutput,
          suspendedSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('无输出空闲超时 → idleTimeout', () {
      final now = startedAt.add(const Duration(seconds: 301));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.idleTimeout,
      );
    });

    test('审批等待冻结 idle 计时', () {
      final now = startedAt.add(const Duration(minutes: 6));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          openApprovals: 1,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('suspended 冻结 idle 计时（断连等 5 分钟不判 idle）', () {
      final suspendedAt = startedAt.add(const Duration(seconds: 30));
      final now = suspendedAt.add(const Duration(minutes: 5));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: suspendedAt,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('suspended 超过 suspendWaitHardCap → suspendCap', () {
      final suspendedAt = startedAt.add(const Duration(seconds: 30));
      final now = suspendedAt.add(const Duration(minutes: 11));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: suspendedAt,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.suspendCap,
      );
    });

    test('hardCap 优先级最高（suspended 未超 suspendCap 但超 hardCap）', () {
      final suspendedAt = startedAt.add(const Duration(minutes: 20));
      final now = startedAt.add(const Duration(minutes: 26));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: suspendedAt,
          openApprovals: 1,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          approvalWaitHardCap: hardCap,
        ),
        TurnWatchdogVerdict.hardCap,
      );
    });
  });
}
