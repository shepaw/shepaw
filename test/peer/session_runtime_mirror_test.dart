import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';

Map<String, dynamic> snap({
  String key = 'agent:a:s1',
  int revision = 1,
  int generation = 7,
  String state = 'running',
  String turnId = 't1',
  bool answerSettled = false,
  String phase = 'streaming',
  Object? lastTerminal,
  List<Map<String, dynamic>>? queue,
}) =>
    <String, dynamic>{
      'session_key': key,
      'revision': revision,
      'generation': generation,
      'state': state,
      'turn_id': turnId,
      'peer_id': 'phone',
      'phase': phase,
      'answer_settled': answerSettled,
      'started_at_ms': 1000,
      'last_progress_at_ms': 1200,
      'last_terminal': lastTerminal,
      'queue': queue ?? <Map<String, dynamic>>[],
      'at': 1300,
    };

void main() {
  group('liveTurns（主机自发回合）', () {
    test('开始/结束都登记到同一份 mirror 并通知一次', () {
      final mirror = SessionRuntimeMirror();
      addTearDown(mirror.dispose);
      var ticks = 0;
      void listener() => ticks++;
      mirror.changes.addListener(listener);
      addTearDown(() => mirror.changes.removeListener(listener));

      mirror.noteLiveTurnStarted('t-push', 'psess_s1');
      expect(mirror.liveTurns['t-push'], 'psess_s1');
      expect(mirror.lastChangedKey, 'psess_s1');
      expect(ticks, 1);

      mirror.noteLiveTurnFinished('t-push');
      expect(mirror.liveTurns.isEmpty, isTrue);
      expect(ticks, 2);

      mirror.noteLiveTurnFinished('t-push');
      expect(ticks, 2, reason: '重复结束不该通知');
    });

    test('空 turnId 忽略', () {
      final mirror = SessionRuntimeMirror();
      addTearDown(mirror.dispose);
      mirror.noteLiveTurnStarted('', 'psess_s1');
      expect(mirror.liveTurns.isEmpty, isTrue);
    });
  });

  group('isStaleOutputStream', () {
    SessionState running(int gen) => SessionState(
          sessionKey: 'agent:a:s1',
          revision: 5,
          generation: gen,
          isRunning: true,
          turnId: 't1',
        );
    SessionState idle(int gen) => SessionState(
          sessionKey: 'agent:a:s1',
          revision: 6,
          generation: gen,
          isRunning: false,
          lastTerminal: const SessionTerminal(
            turnId: 't1',
            reason: 'end_turn',
            atMs: 1,
            revision: 6,
          ),
        );
    Map<String, dynamic> frame(String type, {int gen = 3}) =>
        <String, dynamic>{
          'type': type,
          'request_id': 't1',
          'session_key': 'agent:a:s1',
          'generation': gen,
        };

    test('当前世代的 chunk 放行', () {
      expect(
        isStaleOutputStream('agent_chunk', frame('agent_chunk'), running(3)),
        isFalse,
      );
      expect(
        isStaleOutputStream(
          'agent_metadata',
          frame('agent_metadata'),
          running(3),
        ),
        isFalse,
      );
    });

    test('旧世代的 chunk 拦下', () {
      expect(
        isStaleOutputStream(
          'agent_chunk',
          frame('agent_chunk', gen: 2),
          running(3),
        ),
        isTrue,
      );
    });

    test('主机已宣布 idle 后的迟到输出拦下', () {
      expect(
        isStaleOutputStream('agent_chunk', frame('agent_chunk'), idle(3)),
        isTrue,
      );
    });

    test('终态帧与回执一律不拦，否则在途 turn 永远挂住', () {
      for (final type in <String>[
        'agent_done',
        'agent_error',
        'session_ack',
      ]) {
        expect(
          isStaleOutputStream(type, frame(type), idle(3)),
          isFalse,
          reason: type,
        );
      }
    });

    test('没有标签或没有状态快照时放行', () {
      expect(
        isStaleOutputStream(
          'agent_chunk',
          <String, dynamic>{'request_id': 't1'},
          idle(3),
        ),
        isFalse,
      );
      expect(
        isStaleOutputStream('agent_chunk', frame('agent_chunk'), null),
        isFalse,
      );
      expect(
        isStaleOutputStream(
          'agent_chunk',
          frame('agent_chunk'),
          SessionState.empty('agent:a:s1'),
        ),
        isFalse,
      );
    });
  });

  test('本地 channel id 映射到主机 session_key', () {
    expect(
      SessionRuntimeMirror.sessionKey(
        agentId: 'a1',
        channelId: 'dm_a1_user_9',
      ),
      'agent:a1:dm_a1_user_9',
    );
    expect(
      SessionRuntimeMirror.sessionKey(
        agentId: 'a1',
        channelId: 'psess_dm_a1_user_9',
      ),
      'agent:a1:dm_a1_user_9',
      reason: '已同步会话的 psess_ 壳必须剥掉',
    );
  });

  test('状态跃迁会广播变更并带上会话 key', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    var notifications = 0;
    void listener() => notifications++;
    mirror.changes.addListener(listener);
    addTearDown(() => mirror.changes.removeListener(listener));

    mirror.apply(snap(key: 'agent:a:s1', revision: 1));
    expect(notifications, 1);
    expect(mirror.lastChangedKey, 'agent:a:s1');

    mirror.apply(snap(key: 'agent:a:s1', revision: 1));
    expect(notifications, 1, reason: '重复快照不该通知');

    mirror.apply(snap(key: 'agent:a:s2', revision: 1, turnId: 't9'));
    expect(notifications, 2);
    expect(mirror.lastChangedKey, 'agent:a:s2');
  });

  test('reconcileTo 收敛未报告的会话也会广播', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(key: 'agent:a:s1'));
    mirror.apply(snap(key: 'agent:a:s2', turnId: 't9'));
    var notifications = 0;
    void listener() => notifications++;
    mirror.changes.addListener(listener);
    addTearDown(() => mirror.changes.removeListener(listener));

    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:a:s1', revision: 2, state: 'idle', turnId: ''),
    ]);
    expect(notifications, 2, reason: '对账里的 apply + 未报告会话的收敛');
    expect(mirror.lastChangedKey, 'agent:a:s2');
  });

  test('agentId 不确定时按 session_id 后缀找到会话', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(key: 'agent:real-host-id:dm_a1_user_9'));
    expect(mirror.notifierForChannel('dm_a1_user_9')?.value.turnId, 't1');
    expect(
      mirror.notifierForChannel('psess_dm_a1_user_9')?.value.turnId,
      't1',
    );
    expect(mirror.notifierForChannel('dm_other'), isNull);
    expect(mirror.peek('agent:wrong:dm_a1_user_9'), isNull);
  });

  test('空会话是 idle，没有任何排队', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    final state = mirror.stateFor('agent:a:s1');
    expect(state.isRunning, isFalse);
    expect(state.isProcessing, isFalse);
    expect(state.streamingMessageId, isNull);
    expect(state.hostQueuedCount, 0);
  });

  test('running 快照驱动气泡输出态与发送闸门', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    expect(mirror.apply(snap()), isTrue);
    final state = mirror.stateFor('agent:a:s1');
    expect(state.isRunning, isTrue);
    expect(state.isProcessing, isTrue);
    expect(state.streamingMessageId, 't1');
    expect(state.generation, 7);
    expect(state.dispositionFor('t1'), 'running');
  });

  test('同 revision 的重放被忽略', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    expect(mirror.apply(snap()), isTrue);
    expect(mirror.apply(snap()), isFalse);
    expect(mirror.stateFor('agent:a:s1').revision, 1);
  });

  test('迟到的旧快照不能把状态拉回 running', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(revision: 5));
    mirror.apply(snap(
      revision: 6,
      state: 'idle',
      turnId: '',
      lastTerminal: <String, dynamic>{
        'turn_id': 't1',
        'reason': 'end_turn',
        'at_ms': 2000,
        'revision': 6,
      },
    ));
    expect(mirror.apply(snap(revision: 4, state: 'running')), isFalse);
    final state = mirror.stateFor('agent:a:s1');
    expect(state.isRunning, isFalse);
    expect(state.streamingMessageId, isNull);
    expect(state.revision, 6);
  });

  test('终态快照收起气泡并记录结束原因', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(revision: 1));
    mirror.apply(snap(
      revision: 2,
      state: 'idle',
      turnId: '',
      lastTerminal: <String, dynamic>{
        'turn_id': 't1',
        'reason': 'timeout_idle',
        'at_ms': 2000,
        'revision': 2,
      },
    ));
    final state = mirror.stateFor('agent:a:s1');
    expect(state.isProcessing, isFalse);
    expect(state.streamingMessageId, isNull);
    expect(state.lastTerminal?.reason, 'timeout_idle');
    expect(state.lastTerminal?.turnId, 't1');
  });

  test('队列项带完整正文，编辑面板不会因 preview 截断而丢字', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    final long = '很长的一句正文' * 30;
    mirror.apply(snap(queue: <Map<String, dynamic>>[
      <String, dynamic>{
        'request_id': 't2',
        'position': 1,
        'preview': '很长的一句正文',
        'content': long,
      },
    ]));
    final item = mirror.stateFor('agent:a:s1').queue.single;
    expect(item.content, long);
    expect(item.preview, '很长的一句正文');
  });

  test('排队深度与位置来自主机队列，App 不再自己猜', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(
      revision: 3,
      queue: <Map<String, dynamic>>[
        <String, dynamic>{
          'request_id': 't2',
          'position': 1,
          'preview': '下一条',
        },
        <String, dynamic>{
          'request_id': 't3',
          'position': 2,
          'preview': '再下一条',
        },
      ],
    ));
    final state = mirror.stateFor('agent:a:s1');
    expect(state.hostQueuedCount, 2);
    expect(state.queuedPosition('t2'), 1);
    expect(state.queuedPosition('t3'), 2);
    expect(state.dispositionFor('t2'), 'queued');
    expect(state.dispositionFor('t1'), 'running');
  });

  test('answer_settled 只是 hint，绝不收起还在跑的回合', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(
      revision: 9,
      answerSettled: true,
      phase: 'tool_running',
    ));
    final state = mirror.stateFor('agent:a:s1');
    expect(state.answerSettled, isTrue);
    expect(state.phase, 'tool_running');
    expect(state.isRunning, isTrue);
    expect(state.isProcessing, isTrue);
    expect(state.streamingMessageId, 't1',
        reason: '正文看起来写完也不能结束气泡');
    expect(state.lastTerminal, isNull);
  });

  test('批量对账与到达顺序无关，收敛到最高 revision', () {
    final ascending = SessionRuntimeMirror();
    final shuffled = SessionRuntimeMirror();
    addTearDown(ascending.dispose);
    addTearDown(shuffled.dispose);
    final frames = <Map<String, dynamic>>[
      snap(revision: 1, turnId: 't1'),
      snap(revision: 2, turnId: 't2'),
      snap(revision: 3, turnId: 't3'),
    ];
    expect(ascending.applyAll(frames), 3);
    expect(
      shuffled.applyAll(<Map<String, dynamic>>[
        frames[2],
        frames[0],
        frames[1],
      ]),
      1,
      reason: '先到最高 revision 时，后续旧快照全部按幂等丢弃',
    );
    expect(ascending.stateFor('agent:a:s1').turnId, 't3');
    expect(shuffled.stateFor('agent:a:s1').turnId, 't3');
    expect(shuffled.stateFor('agent:a:s1').revision, 3);
  });

  test('每个会话的 notifier 独立且稳定', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    final first = mirror.notifierFor('agent:a:s1');
    expect(mirror.notifierFor('agent:a:s1'), same(first));
    expect(mirror.notifierFor('agent:a:s2'), isNot(same(first)));
    mirror.apply(snap());
    expect(first.value.turnId, 't1');
    expect(mirror.notifierFor('agent:a:s2').value.isRunning, isFalse);
  });

  test('每次被接受的状态跃迁都通知一次，排队条无需手势即可刷新', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    final notifier = mirror.notifierFor('agent:a:s1');
    var notifications = 0;
    notifier.addListener(() => notifications++);

    mirror.apply(snap(revision: 1));
    mirror.apply(snap(revision: 1)); // 重复
    mirror.apply(snap(
      revision: 2,
      queue: <Map<String, dynamic>>[
        <String, dynamic>{
          'request_id': 't2',
          'position': 1,
          'preview': '排队中',
        },
      ],
    ));
    expect(notifications, 2);
    expect(notifier.value.hostQueuedCount, 1);
  });

  test('全量对账会把主机不再报告的会话收敛成 idle', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(key: 'agent:a:s1'));
    mirror.apply(snap(key: 'agent:a:s2', turnId: 't9'));
    expect(mirror.stateFor('agent:a:s2').isRunning, isTrue);

    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:a:s1', revision: 2, state: 'idle', turnId: ''),
    ]);
    expect(mirror.stateFor('agent:a:s2').isRunning, isFalse);
    expect(mirror.stateFor('agent:a:s2').lastTerminal?.reason, 'reconciled');
  });
}
