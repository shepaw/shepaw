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
  int at = 1300,
  String hubId = 'hub-a',
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
      'at': at,
      'hub_id': hubId,
    };

void main() {
  // 流帧归属已移到 PeerAgentClientService 的 _pending[request_id] 判定，
  // mirror 不再承担「迟到帧」判断（主机 epoch 不持久化，绝对比较会误丢帧）。

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

  test('pouch / 群回合的裸 channel_id 也能按频道找到', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(key: 'group_g1', revision: 3));
    expect(mirror.notifierForChannel('group_g1')?.value.turnId, 't1');
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

  test('全量对账把主机不再报告的会话重置为 revision 0', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(key: 'agent:a:s1', revision: 12));
    mirror.apply(snap(key: 'agent:a:s2', revision: 8, turnId: 't9'));
    expect(mirror.stateFor('agent:a:s2').isRunning, isTrue);

    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:a:s1', revision: 13, state: 'idle', turnId: ''),
    ]);
    expect(mirror.stateFor('agent:a:s2').isRunning, isFalse);
    expect(
      mirror.stateFor('agent:a:s2').revision,
      0,
      reason: '不能伪造比新主机更大的 revision',
    );
    // 换 hub / 重启后主机从 1 重新计数，低 revision 的真实事件也要能收敛。
    expect(
      mirror.apply(snap(key: 'agent:a:s2', revision: 1, turnId: 't10')),
      isTrue,
    );
    expect(mirror.stateFor('agent:a:s2').turnId, 't10');
  });

  test('换 hub 后低 revision 的权威快照也能落地', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(revision: 20, at: 1000));
    expect(mirror.stateFor('agent:a:s1').revision, 20);

    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(revision: 1, at: 2000, turnId: 't2'),
    ]);
    expect(
      mirror.stateFor('agent:a:s1').revision,
      1,
      reason: 'force apply 绕过本地更高的旧 revision',
    );
    expect(mirror.stateFor('agent:a:s1').turnId, 't2');
  });

  test('旧 hub 的回放按 hub_id 拒绝，不复活已结束回合', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(revision: 1, state: 'idle', turnId: '', hubId: 'hub-b'),
    ], hubId: 'hub-b');
    expect(
      mirror.apply(snap(
        revision: 12,
        at: 9000,
        turnId: 'old',
        hubId: 'hub-a',
      )),
      isFalse,
      reason: '旧 hub 的回放必须被拒，即使 at 更晚、revision 更高',
    );
    expect(mirror.stateFor('agent:a:s1').isRunning, isFalse);
    expect(
      mirror.apply(snap(revision: 2, turnId: 't3', hubId: 'hub-b')),
      isTrue,
    );
    expect(mirror.stateFor('agent:a:s1').turnId, 't3');
  });

  test('isRequestQueued 从 durable 队列自愈排队豁免', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.apply(snap(
      at: 9000,
      queue: <Map<String, dynamic>>[
        <String, dynamic>{
          'request_id': 'r2',
          'position': 1,
          'preview': 'x',
          'content': 'x',
        },
      ],
    ));
    expect(mirror.isRequestQueued('r2'), isTrue);
    expect(mirror.isRequestQueued('missing'), isFalse);
  });

  test('换 hub 的空快照也重置身份，新 hub 事件能收敛', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(revision: 20, at: 9000, hubId: 'hub-a'),
    ], hubId: 'hub-a');
    expect(mirror.stateFor('agent:a:s1').revision, 20);
    // 新 hub 没有活跃会话，时钟也比旧的早；顶层 hub_id 仍要触发换 hub。
    mirror.reconcileTo(<Map<String, dynamic>>[], hubId: 'hub-b');
    expect(mirror.stateFor('agent:a:s1').revision, 0);
    expect(
      mirror.apply(snap(
        revision: 1,
        at: 5000,
        turnId: 't2',
        hubId: 'hub-b',
      )),
      isTrue,
    );
    expect(mirror.stateFor('agent:a:s1').turnId, 't2');
    expect(
      mirror.apply(snap(
        revision: 30,
        at: 6000,
        turnId: 'old',
        hubId: 'hub-a',
      )),
      isFalse,
    );
  });
}
