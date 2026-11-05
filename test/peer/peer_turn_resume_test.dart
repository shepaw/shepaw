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

  group('alignLiveChunk', () {
    test('没有重叠 → 全量应用', () {
      final aligned =
          alignLiveChunk(content: 'world', offset: 6, receivedLength: 6);
      expect(aligned.gap, isFalse);
      expect(aligned.content, 'world');
    });

    test('前缀已被 resume 补过 → 只应用缺的后半段', () {
      final aligned =
          alignLiveChunk(content: 'world', offset: 3, receivedLength: 6);
      expect(aligned.content, 'ld');
    });

    test('整段都收过 → 丢弃', () {
      final aligned =
          alignLiveChunk(content: 'world', offset: 3, receivedLength: 8);
      expect(aligned.content, isNull);
      expect(aligned.gap, isFalse);
    });

    test('跳在已收长度前面 → 标记缺口，不能直接拼', () {
      final aligned =
          alignLiveChunk(content: 'world', offset: 8, receivedLength: 3);
      expect(aligned.content, isNull);
      expect(aligned.gap, isTrue);
    });

    test('按 UTF-16 码元对齐（emoji 占两个码元）', () {
      // 已收 2 个码元 = 一个整 emoji；分片从 offset 2 起，整段都要应用。
      expect(
        alignLiveChunk(content: '🙂a', offset: 2, receivedLength: 2).content,
        '🙂a',
      );
      // 已收 4 个码元 = emoji + 分片里的 emoji，只剩末尾的 'a'。
      expect(
        alignLiveChunk(content: '🙂a', offset: 2, receivedLength: 4).content,
        'a',
      );
      // 已收 5 个码元 = 整条分片都收过。
      expect(
        alignLiveChunk(content: '🙂a', offset: 2, receivedLength: 5).content,
        isNull,
      );
    });
  });

  group('evaluateTurnWatchdog', () {
    final startedAt = DateTime(2026, 7, 20, 12, 0, 0);
    const chatTimeout = Duration(seconds: 300);
    const suspendCap = Duration(minutes: 10);

    test('正常活动 → none', () {
      final now = startedAt.add(const Duration(seconds: 60));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
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
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
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
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
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
          upstreamReconnectingSince: null,
          openApprovals: 1,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
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
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
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
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
        ),
        TurnWatchdogVerdict.suspendCap,
      );
    });

    test('审批等待不设硬上限（远超原 hardCap 仍 none）', () {
      // 审批等待无超时：用户何时裁决由用户决定，idle 计时全程冻结。
      final now = startedAt.add(const Duration(hours: 5));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 1,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('无审批的健康长任务不受总时长限制（持续输出 30 分钟）', () {
      // 持续流式输出的 turn 由 idleTimeout 约束，跑多久都不判死。
      final lastOutput = startedAt.add(const Duration(minutes: 29, seconds: 30));
      final now = startedAt.add(const Duration(minutes: 30));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: lastOutput,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('无审批的挂起 turn 只受 suspendCap 约束（挂起未超时不判死）', () {
      final suspendedAt = startedAt.add(const Duration(minutes: 24));
      final now = suspendedAt.add(const Duration(minutes: 2));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: suspendedAt,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('Hub keepalive 推迟 idle 超时（静默长工具不判失败）', () {
      final now = startedAt.add(const Duration(minutes: 40));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          lastKeepaliveAt: now.subtract(const Duration(seconds: 90)),
        ),
        TurnWatchdogVerdict.none,
      );
    });

    test('Hub 停止 keepalive 后从最后一次报活起算 idle 超时', () {
      final lastKeepalive = startedAt.add(const Duration(minutes: 20));
      expect(
        evaluateTurnWatchdog(
          now: lastKeepalive.add(const Duration(seconds: 301)),
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
          lastKeepaliveAt: lastKeepalive,
        ),
        TurnWatchdogVerdict.idleTimeout,
      );
    });
  });

  group('shouldProbeStalledTurn', () {
    final startedAt = DateTime(2026, 7, 20, 12, 0, 0);
    const stallInterval = Duration(seconds: 180);

    test('空闲超过阈值且无 resume 在途 → true', () {
      final now = startedAt.add(const Duration(seconds: 200));
      expect(
        shouldProbeStalledTurn(
          now: now,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          resumeInFlight: false,
          lastStallProbeAt: null,
          stallProbeInterval: stallInterval,
        ),
        isTrue,
      );
    });

    test('上游重连中不探测', () {
      final now = startedAt.add(const Duration(seconds: 200));
      expect(
        shouldProbeStalledTurn(
          now: now,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: startedAt,
          openApprovals: 0,
          resumeInFlight: false,
          lastStallProbeAt: null,
          stallProbeInterval: stallInterval,
        ),
        isFalse,
      );
    });

    test('新鲜审批卡不探测', () {
      final opened = startedAt.add(const Duration(minutes: 1));
      final now = opened.add(const Duration(minutes: 2));
      expect(
        shouldProbeStalledTurn(
          now: now,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 1,
          resumeInFlight: false,
          lastStallProbeAt: null,
          stallProbeInterval: stallInterval,
          lastApprovalOpenedAt: opened,
        ),
        isFalse,
      );
    });

    test('审批闸门过期后恢复探测', () {
      final opened = startedAt;
      final now = opened.add(const Duration(minutes: 11));
      expect(
        shouldProbeStalledTurn(
          now: now,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 1,
          resumeInFlight: false,
          lastStallProbeAt: null,
          stallProbeInterval: stallInterval,
          lastApprovalOpenedAt: opened,
        ),
        isTrue,
      );
    });

    test('距上次探测不足间隔 → false', () {
      final lastProbe = startedAt.add(const Duration(seconds: 30));
      final now = startedAt.add(const Duration(seconds: 200));
      expect(
        shouldProbeStalledTurn(
          now: now,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: null,
          openApprovals: 0,
          resumeInFlight: false,
          lastStallProbeAt: lastProbe,
          stallProbeInterval: stallInterval,
        ),
        isFalse,
      );
    });
  });

  group('metadataResetsIdleClock', () {
    test('keepalive 不重置空闲计时', () {
      expect(
        metadataResetsIdleClock({
          'keepalive': true,
          'upstream_status': 'working',
        }),
        isFalse,
      );
    });

    test('真正的工具/正文 metadata 仍重置', () {
      expect(
        metadataResetsIdleClock({
          'keepalive': true,
          'collapsibleTitle': 'Bash',
        }),
        isTrue,
      );
      expect(
        metadataResetsIdleClock({'collapsible': true}),
        isTrue,
      );
    });
  });

  group('settlingReplyFromRemoteTranscript', () {
    String? settle(
      List<RemoteHistoryLine> history, {
      String sessionId = 's1',
      String syncedSessionId = 's1',
      String receivedContent = '',
    }) {
      return settlingReplyFromRemoteTranscript(
        inflightSessionId: sessionId,
        syncedRemoteSessionId: syncedSessionId,
        history: history,
        receivedContent: receivedContent,
      );
    }

    test('session 对上且回合已答完 → 交出末条回复', () {
      expect(
        settle(
          const [
            RemoteHistoryLine(role: 'user', content: 'q'),
            RemoteHistoryLine(role: 'agent', content: '## 官网引擎清单现状'),
          ],
          sessionId: 'gmd_g1__a1__wf_w__step_s',
          syncedSessionId: 'gmd_g1__a1__wf_w__step_s',
        ),
        '## 官网引擎清单现状',
      );
    });

    test('session 不一致 → null', () {
      expect(
        settle(
          const [RemoteHistoryLine(role: 'agent', content: 'done')],
          sessionId: 'gmd_g1__a1',
          syncedSessionId: 'gmd_g1__a2',
        ),
        isNull,
      );
    });

    test('无助手回复 → null', () {
      expect(
        settle(const [
          RemoteHistoryLine(role: 'user', content: 'q'),
          RemoteHistoryLine(role: 'agent', content: '   '),
        ]),
        isNull,
      );
    });

    // 回归：提问已提交但 agent 还没答，尾部是 user 行。旧实现会跨过它取到 A1，
    // 把上一回合的回复存成新提问的答案。
    test('提问已在 transcript 但尚未作答 → null', () {
      expect(
        settle(const [
          RemoteHistoryLine(role: 'user', content: 'Q1'),
          RemoteHistoryLine(role: 'agent', content: 'A1 回答的是 Q1'),
          RemoteHistoryLine(role: 'user', content: 'Q2'),
        ]),
        isNull,
      );
    });

    test('答完后同一 transcript 交出新回复', () {
      expect(
        settle(const [
          RemoteHistoryLine(role: 'user', content: 'Q1'),
          RemoteHistoryLine(role: 'agent', content: 'A1 回答的是 Q1'),
          RemoteHistoryLine(role: 'user', content: 'Q2'),
          RemoteHistoryLine(role: 'agent', content: 'A2 回答的是 Q2'),
        ]),
        'A2 回答的是 Q2',
      );
    });

    test('已流出的开头对得上 → 交出完整回复', () {
      expect(
        settle(
          const [
            RemoteHistoryLine(role: 'user', content: 'Q'),
            RemoteHistoryLine(role: 'agent', content: 'Hello world, 详细展开…'),
          ],
          receivedContent: 'Hello wo',
        ),
        'Hello world, 详细展开…',
      );
    });

    test('已流出的开头对不上（末条属于别的回合）→ null', () {
      expect(
        settle(
          const [
            RemoteHistoryLine(role: 'user', content: 'Q'),
            RemoteHistoryLine(role: 'agent', content: '完全不同的另一条回复'),
          ],
          receivedContent: 'Hello wo',
        ),
        isNull,
      );
    });
  });

  group('evaluateTurnWatchdog upstream reconnect', () {
    final startedAt = DateTime(2026, 7, 20, 12, 0, 0);
    const chatTimeout = Duration(seconds: 300);
    const suspendCap = Duration(minutes: 10);

    test('上游重连中冻结 idle 超时', () {
      final reconnectingAt = startedAt.add(const Duration(seconds: 10));
      final now = reconnectingAt.add(const Duration(minutes: 6));
      expect(
        evaluateTurnWatchdog(
          now: now,
          startedAt: startedAt,
          idleSince: startedAt,
          suspendedSince: null,
          upstreamReconnectingSince: reconnectingAt,
          openApprovals: 0,
          chatTimeout: chatTimeout,
          suspendWaitHardCap: suspendCap,
        ),
        TurnWatchdogVerdict.none,
      );
    });
  });
}
