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
  bool flow = false,
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
      if (flow) 'flow': true,
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
    // 先确立 hub 身份，避免换 hub 复位分支干扰计数。
    mirror.reconcileTo(<Map<String, dynamic>>[], hubId: 'hub-a');
    mirror.apply(snap(key: 'agent:a:s1'));
    mirror.apply(snap(key: 'agent:a:s2', turnId: 't9'));
    var notifications = 0;
    void listener() => notifications++;
    mirror.changes.addListener(listener);
    addTearDown(() => mirror.changes.removeListener(listener));

    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:a:s1', revision: 2, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');
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
    expect(state.streamingMessageId, 't1', reason: '正文看起来写完也不能结束气泡');
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

  test('A2-2: 重连对账保留 running 的 flow_ 节点会话，idle 后清掉', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 1, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');
    mirror.apply(snap(
      key: 'flow_deadbe12_impl',
      revision: 1,
      turnId: 'flow-deadbe12-impl-a1',
    ));
    mirror.apply(snap(
      key: 'agent:real:flow_deadbe12_plan',
      revision: 1,
      turnId: 'flow-deadbe12-plan-a1',
    ));
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isTrue);

    // 重连的 session_snapshot_resp 只含 hub 运行时会话，节点会话不在里面。
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 2, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');

    final kept = mirror.stateFor('flow_deadbe12_impl');
    expect(kept.isRunning, isTrue);
    expect(kept.turnId, 'flow-deadbe12-impl-a1',
        reason: '保留 turnId，停止按钮才找得到回合');
    expect(
      mirror.stateFor('agent:real:flow_deadbe12_plan').turnId,
      'flow-deadbe12-plan-a1',
      reason: '带 agent: 前缀的 flow key 同样要保留',
    );

    // 主机发 idle 帧才收掉。
    mirror.apply(snap(
      key: 'flow_deadbe12_impl',
      revision: 2,
      state: 'idle',
      turnId: '',
    ));
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isFalse);
    expect(mirror.stateFor('flow_deadbe12_impl').turnId, '');
  });

  test('A2-2: 非 flow_ 会话在重连快照缺席时仍按原逻辑清掉', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    // 先确立 hub 身份，确认是「未报告的 running 会话」清理路径。
    mirror.reconcileTo(<Map<String, dynamic>>[], hubId: 'hub-a');
    mirror.apply(snap(key: 'agent:a:s1', revision: 5));
    mirror.reconcileTo(<Map<String, dynamic>>[], hubId: 'hub-a');
    expect(mirror.stateFor('agent:a:s1').isRunning, isFalse);
    expect(mirror.stateFor('agent:a:s1').turnId, '');
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

  test('换 hub 的复位本身也通知监听者，气泡能收起', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(revision: 20, hubId: 'hub-a'),
    ], hubId: 'hub-a');
    var notifications = 0;
    void listener() => notifications++;
    mirror.changes.addListener(listener);
    addTearDown(() => mirror.changes.removeListener(listener));
    expect(notifications, 0);

    mirror.reconcileTo(<Map<String, dynamic>>[], hubId: 'hub-b');
    expect(notifications, greaterThan(0));
    expect(mirror.stateFor('agent:a:s1').revision, 0);
    expect(mirror.stateFor('agent:a:s1').isRunning, isFalse);
  });

  test('首次运行不被旧 hub 回放毒化身份', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    // 旧 hub 的回放先到：apply 不认领身份。
    expect(mirror.apply(snap(revision: 12, hubId: 'hub-a')), isTrue);
    // 当前主机的权威快照纠正身份与状态。
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(revision: 1, hubId: 'hub-b'),
    ], hubId: 'hub-b');
    expect(mirror.stateFor('agent:a:s1').revision, 1);
    expect(mirror.apply(snap(revision: 30, hubId: 'hub-a')), isFalse);
    expect(mirror.apply(snap(revision: 2, hubId: 'hub-b')), isTrue);
    expect(mirror.stateFor('agent:a:s1').revision, 2);
  });

  test('出队：queue 里的 request 提成 turn_id 后不再算排队', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);

    mirror.apply(snap(
      key: 'agent:a:s1',
      revision: 1,
      turnId: 't-running',
      queue: <Map<String, dynamic>>[
        <String, dynamic>{
          'request_id': 'q-next',
          'position': 1,
          'preview': '下一条',
          'content': '下一条',
        },
      ],
    ));
    expect(mirror.isRequestQueued('q-next'), isTrue);
    expect(mirror.isRequestRunning('q-next'), isFalse);

    // 主机 continue_session：原子地结束上一轮、出队、把 q-next 提成 running。
    mirror.apply(snap(
      key: 'agent:a:s1',
      revision: 2,
      turnId: 'q-next',
      queue: <Map<String, dynamic>>[],
    ));
    expect(mirror.isRequestQueued('q-next'), isFalse);
    expect(mirror.isRequestRunning('q-next'), isTrue);
  });

  test('A4-1: 重连保留的 running flow 条目超时后回 idle 并广播', () async {
    final mirror = SessionRuntimeMirror(
      flowRetention: const Duration(milliseconds: 40),
    );
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 1, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');
    mirror.apply(snap(
      key: 'flow_deadbe12_impl',
      revision: 3,
      flow: true,
      turnId: 'flow-deadbe12-impl-a1',
    ));

    // 断线期间的 idle 帧丢了：重连快照只含 hub 运行时会话。
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 2, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isTrue,
        reason: '重连当下先保留 turnId，停止按钮还能用');

    var notifications = 0;
    void listener() => notifications++;
    mirror.changes.addListener(listener);
    addTearDown(() => mirror.changes.removeListener(listener));

    await Future<void>.delayed(const Duration(milliseconds: 80));
    final state = mirror.stateFor('flow_deadbe12_impl');
    expect(state.isRunning, isFalse, reason: '没有后续 flow 活动时必须收尾');
    expect(state.turnId, '');
    expect(state.revision, 3, reason: '收尾不伪造 revision');
    expect(notifications, 1);

    // 主机重启后 flow revision 从 1 重新计数：照样要能落地。
    expect(
      mirror.apply(snap(
        key: 'flow_deadbe12_impl',
        revision: 1,
        flow: true,
        turnId: 'flow-deadbe12-impl-a2',
      )),
      isTrue,
      reason: 'flow 帧按 key 独立 revision，低 revision 不能被拒',
    );
    expect(
        mirror.stateFor('flow_deadbe12_impl').turnId, 'flow-deadbe12-impl-a2');
  });

  test('A6-3: flow 帧跳过 revision 比较，但仍校验 hub 身份', () {
    final mirror = SessionRuntimeMirror();
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 1, state: 'idle', turnId: ''),
    ], hubId: 'hub-new');

    // 同 hub、per-key revision 回落：照常落地（不参与 hub 全局 revision 空间）。
    expect(
      mirror.apply(snap(
        key: 'flow_deadbe12_impl',
        revision: 9,
        flow: true,
        hubId: 'hub-new',
        turnId: 't9',
      )),
      isTrue,
      reason: 'flow 帧只作用于自己的 key，revision 从 1 重来也要接受',
    );
    // 旧 hub 的迟到 flow 帧：不能把当前主机已收尾的回合复活。
    expect(
      mirror.apply(snap(
        key: 'flow_deadbe12_impl',
        revision: 99,
        flow: true,
        hubId: 'hub-old',
        turnId: 'stale-flow',
      )),
      isFalse,
      reason: '换了 hub 后旧主机的 flow 帧一律拒绝',
    );
    expect(mirror.stateFor('flow_deadbe12_impl').turnId, 't9');
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isTrue);

    // 同 hub 的低 revision idle 仍要收尾。
    expect(
      mirror.apply(snap(
        key: 'flow_deadbe12_impl',
        revision: 1,
        flow: true,
        hubId: 'hub-new',
        state: 'idle',
        turnId: '',
      )),
      isTrue,
      reason: '只有「同 hub 但低 revision」才跳过 reducer',
    );
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isFalse);

    // 普通 hub 会话仍按原来的 hub 身份 / revision 规则拒绝。
    expect(
      mirror.apply(snap(
        key: 'agent:hub:main',
        revision: 2,
        hubId: 'hub-old',
        turnId: 'stale',
      )),
      isFalse,
    );
    // 没有 hub_id 的旧帧仍能落地（主机老版本 / 对账未确立身份时）。
    expect(
      mirror.apply(snap(
        key: 'flow_deadbe12_impl',
        revision: 1,
        flow: true,
        hubId: '',
        turnId: 't-no-hub',
      )),
      isTrue,
    );
  });

  test('A4-1: 保留期内有 flow chunk 活动就不误收尾', () async {
    final mirror = SessionRuntimeMirror(
      flowRetention: const Duration(milliseconds: 40),
    );
    addTearDown(mirror.dispose);
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 1, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');
    mirror.apply(snap(
      key: 'flow_deadbe12_impl',
      revision: 1,
      flow: true,
      turnId: 'flow-deadbe12-impl-a1',
    ));
    mirror.reconcileTo(<Map<String, dynamic>>[
      snap(key: 'agent:hub:main', revision: 2, state: 'idle', turnId: ''),
    ], hubId: 'hub-a');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    mirror.noteFlowActivity('flow_deadbe12_impl');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mirror.stateFor('flow_deadbe12_impl').isRunning, isTrue,
        reason: '还在出字的回合不能因为保留超时被清掉');
    expect(
        mirror.stateFor('flow_deadbe12_impl').turnId, 'flow-deadbe12-impl-a1');
  });
}
