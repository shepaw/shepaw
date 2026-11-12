import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/jade_slip.dart';

JadeSlip base({
  String id = 'slip-1',
  JadeSlipStatus status = JadeSlipStatus.open,
  List<JadeSlipItem> items = const [],
  JadeSlipExecutorKind executorKind = JadeSlipExecutorKind.agent,
  JadeSlipFlowBinding? flowBinding,
  List<JadeSlipFlowRun> flowRuns = const [],
  String flowStatus = '',
  List<JadeSlipEvent> events = const [],
  int updatedAt = 100,
}) =>
    JadeSlip(
      id: id,
      title: '测试玉简',
      deviceId: 'host-device',
      createdAt: 1,
      updatedAt: updatedAt,
      status: status,
      items: items,
      executorKind: executorKind,
      flowBinding: flowBinding,
      flowRuns: flowRuns,
      flowStatus: flowStatus,
      events: events,
    );

const binding = JadeSlipFlowBinding(
  scope: 'group:g1',
  name: '发布流程',
  revision: 3,
  inputs: {'goal': '上线 v2'},
  bindings: {'coder': 'claude-main'},
  inputFrom: {'goal': 'slip'},
);

void main() {
  test('旧玉简没有新字段时按纯 Agent 处理，toJson 不写新键', () {
    final slip = JadeSlip.fromJson({
      'id': 'old',
      'title': '老玉简',
      'assignee_agent_id': 'agent-1',
      'created_at': 1,
      'updated_at': 2,
    });
    expect(slip.executorKind, JadeSlipExecutorKind.agent);
    expect(slip.flowBinding, isNull);
    expect(slip.flowRuns, isEmpty);
    expect(slip.flowStatus, '');
    expect(slip.isFlowExecutor, isFalse);
    expect(slip.toJson().containsKey('executor_kind'), isFalse);
    expect(slip.toJson().containsKey('flow_binding'), isFalse);
    expect(slip.toJson().containsKey('flow_runs'), isFalse);
    expect(slip.toJson().containsKey('flow_status'), isFalse);
  });

  test('flow 绑定序列化往返不丢 scope/name/revision/inputs/roles', () {
    final slip = base(
      executorKind: JadeSlipExecutorKind.flow,
      flowBinding: binding,
    );
    final json = slip.toJson();
    expect(json['executor_kind'], 'flow');
    expect(json['flow_binding']['scope'], 'group:g1');
    expect(json['flow_binding']['revision'], 3);
    expect(json['flow_binding']['inputs'], {'goal': '上线 v2'});
    expect(json['flow_binding']['bindings'], {'coder': 'claude-main'});
    expect(json['flow_binding']['input_from'], {'goal': 'slip'});

    final back = JadeSlip.fromJson(json);
    expect(back.executorKind, JadeSlipExecutorKind.flow);
    expect(back.isFlowExecutor, isTrue);
    expect(back.flowBinding!.scope, 'group:g1');
    expect(back.flowBinding!.name, '发布流程');
    expect(back.flowBinding!.revision, 3);
    expect(back.flowBinding!.inputs, {'goal': '上线 v2'});
    expect(back.flowBinding!.bindings, {'coder': 'claude-main'});
    expect(back.flowBinding!.inputFrom, {'goal': 'slip'});
  });

  test('绑定字段类型不对时不崩，退回纯 Agent 缺省', () {
    final slip = JadeSlip.fromJson({
      'id': 'bad',
      'title': '坏数据',
      'executor_kind': 42,
      'flow_binding': 'not-a-map',
      'flow_runs': 'not-a-list',
      'flow_status': 7,
      'created_at': 1,
      'updated_at': 2,
    });
    expect(slip.executorKind, JadeSlipExecutorKind.agent);
    expect(slip.flowBinding, isNull);
    expect(slip.flowRuns, isEmpty);
    expect(slip.flowStatus, '');
  });

  test('flow_binding 里的 Map 值不是字符串时也不崩', () {
    final slip = JadeSlip.fromJson({
      'id': 'bad2',
      'title': '坏数据',
      'executor_kind': 'flow',
      'flow_binding': {
        'scope': 'lib',
        'name': 't',
        'revision': 'not-a-number',
        'inputs': {'a': 1, 'b': null},
        'bindings': ['oops'],
      },
      'created_at': 1,
      'updated_at': 2,
    });
    expect(slip.flowBinding, isNotNull);
    expect(slip.flowBinding!.revision, isNull);
    expect(slip.flowBinding!.inputs, {'a': '1', 'b': ''});
    expect(slip.flowBinding!.bindings, isEmpty);
  });

  test('flow_runs 往返，并给出去重后的最近一次运行', () {
    final slip = base(
      executorKind: JadeSlipExecutorKind.flow,
      flowBinding: binding,
      flowRuns: const [
        JadeSlipFlowRun(
            runId: 'r1', startedAt: 10, status: 'failed', hostId: 'h1'),
        JadeSlipFlowRun(
            runId: 'r2', startedAt: 20, status: 'running', hostId: 'h1'),
      ],
    );
    final back = JadeSlip.fromJson(slip.toJson());
    expect(back.flowRuns.length, 2);
    expect(back.latestFlowRun!.runId, 'r2');
    expect(back.flowRunById('r1')!.status, 'failed');
    expect(back.flowRunById('nope'), isNull);
    expect(back.toAgentPrompt(), contains('executor: flow group:g1/发布流程@3'));
    expect(back.toAgentPrompt(), contains('latest_flow_run: r2 running'));
  });

  test('纯 Agent 玉简的 toAgentPrompt 不含工作流信息', () {
    expect(base().toAgentPrompt(), isNot(contains('executor: flow')));
  });

  test('executor_kind 未知值按 agent 处理（旧 App 兼容）', () {
    final slip = JadeSlip.fromJson({
      'id': 'x',
      'title': 'x',
      'executor_kind': 'something-new',
      'created_at': 1,
      'updated_at': 2,
    });
    expect(slip.executorKind, JadeSlipExecutorKind.agent);
  });

  test('copyWith 能设置/清空绑定，不影响 assignee', () {
    final slip = base(executorKind: JadeSlipExecutorKind.flow, flowBinding: binding)
        .copyWith(assigneeAgentId: 'agent-keep');
    expect(slip.executorKind, JadeSlipExecutorKind.flow);
    expect(slip.assigneeAgentId, 'agent-keep');
    expect(slip.flowBinding!.name, '发布流程');

    final cleared = slip.copyWith(
      executorKind: JadeSlipExecutorKind.agent,
      clearFlowBinding: true,
    );
    expect(cleared.executorKind, JadeSlipExecutorKind.agent);
    expect(cleared.flowBinding, isNull);
    expect(cleared.assigneeAgentId, 'agent-keep');
  });

  test('绑定了工作流就不再算空白草稿', () {
    const untitled = '未题玉简';
    final blank = base().copyWith(title: untitled);
    expect(blank.isBlankDraft(untitledTitle: untitled), isTrue);
    expect(
      blank
          .copyWith(
            executorKind: JadeSlipExecutorKind.flow,
            flowBinding: binding,
          )
          .isBlankDraft(untitledTitle: untitled),
      isFalse,
    );
    expect(
      blank
          .copyWith(flowRuns: const [JadeSlipFlowRun(runId: 'r1')])
          .isBlankDraft(untitledTitle: untitled),
      isFalse,
    );
  });

  test('flowStatus 状态锁：清单未验收完时保住待验收 / 受阻', () {
    final items = [
      JadeSlipItem(id: 'i1', text: '一件'),
    ];
    final locked = base(
      items: items,
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ).withDerivedStatus(updatedAt: 200);
    expect(locked.status, JadeSlipStatus.needsReview,
        reason: '工作流跑完了但清单没勾，不能被派生回 open');
    expect(locked.flowStatus, 'needs_review');

    final blocked = base(
      items: items,
      status: JadeSlipStatus.blocked,
      flowStatus: 'blocked',
    ).withDerivedStatus(updatedAt: 200);
    expect(blocked.status, JadeSlipStatus.blocked);
  });

  test('人验收完清单项后状态变 done 且状态锁清除（不自动验收）', () {
    final accepted = JadeSlipItem(
      id: 'i1',
      text: '一件',
      state: JadeSlipItemState.accepted,
    );
    final done = base(
      items: [accepted],
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ).withDerivedStatus(updatedAt: 300);
    expect(done.status, JadeSlipStatus.done);
    expect(done.flowStatus, '');
  });

  test('取消运行不设状态锁时，状态按清单正常派生', () {
    final cancelled = base(
      items: [JadeSlipItem(id: 'i1', text: '一件')],
      status: JadeSlipStatus.inProgress,
      flowStatus: '',
    ).withDerivedStatus(updatedAt: 200);
    expect(cancelled.status, JadeSlipStatus.open);
  });

  test('纯 Agent 玉简状态派生与改动前一致', () {
    final open = base(items: [JadeSlipItem(id: 'i1', text: 'a')])
        .withDerivedStatus(updatedAt: 200);
    expect(open.status, JadeSlipStatus.open);
    final review = base(
      items: [
        JadeSlipItem(
            id: 'i1', text: 'a', state: JadeSlipItemState.submitted),
      ],
    ).withDerivedStatus(updatedAt: 200);
    expect(review.status, JadeSlipStatus.needsReview);
    final blocked = base(
      items: [
        JadeSlipItem(id: 'i1', text: 'a', state: JadeSlipItemState.blocked),
      ],
    ).withDerivedStatus(updatedAt: 200);
    expect(blocked.status, JadeSlipStatus.blocked);
  });

  test('mergeCopies：flowRuns 按 runId 并集、终态优先、不重复', () {
    final older = base(
      updatedAt: 100,
      executorKind: JadeSlipExecutorKind.flow,
      flowBinding: binding,
      flowRuns: const [
        JadeSlipFlowRun(runId: 'r1', startedAt: 10, status: 'running'),
        JadeSlipFlowRun(runId: 'r2', startedAt: 11, status: 'running'),
      ],
    );
    final newer = base(
      updatedAt: 200,
      executorKind: JadeSlipExecutorKind.flow,
      flowBinding: const JadeSlipFlowBinding(scope: 'lib', name: '别的流程'),
      flowRuns: const [
        JadeSlipFlowRun(runId: 'r1', startedAt: 10, status: 'succeeded'),
        JadeSlipFlowRun(runId: 'r3', startedAt: 12, status: 'running'),
      ],
    );
    final merged = JadeSlip.mergeCopies(older, newer);
    expect(merged.flowRuns.map((e) => e.runId).toSet(), {'r1', 'r2', 'r3'});
    expect(merged.flowRunById('r1')!.status, 'succeeded',
        reason: '一端记 running、另一端记终态时终态赢');
    expect(merged.flowRuns.length, 3, reason: '不重复');
    expect(merged.flowBinding!.name, '别的流程', reason: '绑定按最新 updatedAt 取胜');
  });

  test('mergeCopies 反过来传也一样（顺序无关）', () {
    final a = base(
      updatedAt: 100,
      flowRuns: const [
        JadeSlipFlowRun(runId: 'r1', startedAt: 10, status: 'running'),
      ],
    );
    final b = base(
      updatedAt: 200,
      flowRuns: const [
        JadeSlipFlowRun(runId: 'r1', startedAt: 10, status: 'failed'),
        JadeSlipFlowRun(runId: 'r2', startedAt: 11, status: 'running'),
      ],
    );
    for (final merged in [JadeSlip.mergeCopies(a, b), JadeSlip.mergeCopies(b, a)]) {
      expect(merged.flowRuns.length, 2);
      expect(merged.flowRunById('r1')!.status, 'failed');
    }
  });

  test('mergeCopies：一端没有运行记录也不会把另一端清空', () {
    final withRuns = base(
      updatedAt: 100,
      flowRuns: const [JadeSlipFlowRun(runId: 'r1', startedAt: 10)],
    );
    final withoutRuns = base(updatedAt: 200);
    expect(JadeSlip.mergeCopies(withRuns, withoutRuns).flowRuns.length, 1);
    expect(JadeSlip.mergeCopies(withoutRuns, withRuns).flowRuns.length, 1);
  });

  test('事件按 id 去重后合并，flow_run 事件能带 text 显示', () {
    final older = base(
      updatedAt: 100,
      events: const [
        JadeSlipEvent(
            id: 'flow_run_r1_succeeded',
            kind: 'flow_run',
            actorId: 'system',
            text: '工作流完成，待验收',
            createdAt: 10),
      ],
    );
    final newer = base(
      updatedAt: 200,
      events: const [
        JadeSlipEvent(
            id: 'flow_run_r1_succeeded',
            kind: 'flow_run',
            actorId: 'system',
            text: '工作流完成，待验收',
            createdAt: 10),
      ],
    );
    final merged = JadeSlip.mergeCopies(older, newer);
    expect(merged.events.length, 1);
    expect(merged.events.single.kind, 'flow_run');
    expect(merged.events.single.text, '工作流完成，待验收');
  });
}
