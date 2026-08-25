import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/services/group/group_stage_gate.dart';

RemoteAgent _agent(String id, String name) {
  return RemoteAgent(
    id: id,
    name: name,
    token: 'token_$id',
    endpoint: 'wss://localhost/$id',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.websocket,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    metadata: const {},
  );
}

WorkflowStepExecution _step({
  int stage = 0,
  int step = 0,
  String agentName = 'Agent B',
  StepExecutionStatus status = StepExecutionStatus.pending,
  String? outputSummary,
  String? errorMessage,
  String stageName = '',
}) {
  return WorkflowStepExecution(
    id: 'step_${stage}_$step',
    workflowExecutionId: 'wf_1',
    stageIndex: stage,
    stepIndex: step,
    stageName: stageName,
    agentName: agentName,
    instruction: 'do',
    status: status,
    outputSummary: outputSummary,
    errorMessage: errorMessage,
  );
}

void main() {
  group('parseGateDecision', () {
    test('parses continue / abort / reassign', () {
      expect(parseGateDecision('[GATE_DECISION: continue]')!.isProceed, isTrue);
      expect(parseGateDecision('[GATE_DECISION: abort]')!.isAbort, isTrue);

      final reassign = parseGateDecision('[GATE_DECISION: reassign:Agent C]');
      expect(reassign, isNotNull);
      expect(reassign!.isReassign, isTrue);
      expect(reassign.reassignTarget, 'Agent C');
    });

    test('is case-insensitive and tolerates spacing', () {
      expect(parseGateDecision('[gate_decision: CONTINUE]')!.isProceed, isTrue);
      expect(parseGateDecision(' [GATE_DECISION: abort ] ')!.isAbort, isTrue);

      final r = parseGateDecision('[GATE_DECISION:  reassign :  Agent C  ]');
      expect(r, isNotNull);
      expect(r!.reassignTarget, 'Agent C');
    });

    test('finds the decision embedded inside a longer reply', () {
      final reply = '阶段结果看起来不错。\n'
          '我决定继续，[GATE_DECISION: continue]\n'
          '请进入下一阶段。';
      expect(parseGateDecision(reply)!.isProceed, isTrue);
    });

    test('returns null when no decision line present', () {
      expect(parseGateDecision('我觉得应该继续'), isNull);
      expect(parseGateDecision(''), isNull);
    });

    test('returns null for reassign without a target name', () {
      expect(parseGateDecision('[GATE_DECISION: reassign]'), isNull);
      expect(parseGateDecision('[GATE_DECISION: reassign:]'), isNull);
    });
  });

  group('renderStageGateStepLine', () {
    test('renders completed with output summary', () {
      final line = renderStageGateStepLine(_step(
        stage: 0,
        step: 2,
        status: StepExecutionStatus.completed,
        outputSummary: '实现基础架构\n二次换行',
      ));
      expect(line, contains('阶段1/步骤3'));
      expect(line, contains('成员Agent B'));
      expect(line, contains('✅ 完成'));
      expect(line, contains('实现基础架构'));
      expect(line, isNot(contains('\n')));
    });

    test('renders failed with error message', () {
      final line = renderStageGateStepLine(_step(
        stage: 1,
        step: 0,
        status: StepExecutionStatus.failed,
        errorMessage: '超时',
      ));
      expect(line, contains('阶段2/步骤1'));
      expect(line, contains('❌ 失败'));
      expect(line, contains('超时'));
    });

    test('renders skipped and unknown agent name', () {
      expect(
        renderStageGateStepLine(_step(
          status: StepExecutionStatus.skipped,
          agentName: '',
        )),
        contains('⏭ 跳过'),
      );
      expect(
        renderStageGateStepLine(_step(status: StepExecutionStatus.skipped)),
        contains('成员Agent B'),
      );
    });
  });

  group('buildStageGatePrompt', () {
    test('renders group, stage labels, results, roster and decision options',
        () {
      final prompt = buildStageGatePrompt(
        groupName: '研发群',
        stageIndex: 1,
        stageName: '架构设计',
        nextStageName: '编码实现',
        resultLines: [
          renderStageGateStepLine(_step(
            stage: 0,
            step: 0,
            agentName: 'Agent B',
            status: StepExecutionStatus.completed,
            outputSummary: '产出设计稿',
          )),
        ],
        currentMembers: [_agent('x', 'She'), _agent('b', 'Agent B')],
      );

      expect(prompt, contains('群聊「研发群」'));
      expect(prompt, contains('阶段 1「架构设计」'));
      expect(prompt, contains('阶段 2「编码实现」'));
      expect(prompt, contains('产出设计稿'));
      expect(prompt, contains('当前群成员（2 人）：She、Agent B'));
      expect(prompt, contains('[GATE_DECISION: continue]'));
      expect(prompt, contains('[GATE_DECISION: abort]'));
      expect(prompt, contains('[GATE_DECISION: reassign:新成员名]'));
    });

    test('falls back to plain stage labels when names are empty', () {
      final prompt = buildStageGatePrompt(
        groupName: 'G',
        stageIndex: 2,
        stageName: '',
        nextStageName: '',
        resultLines: const [],
        currentMembers: const [],
      );
      expect(prompt, contains('阶段 2'));
      expect(prompt, contains('阶段 3'));
      expect(prompt, contains('（本阶段无步骤结果）'));
    });
  });

  group('stageGateSystemPrompt', () {
    test('forbids tools and requires the decision line', () {
      expect(stageGateSystemPrompt, contains('[GATE_DECISION: ...]'));
      expect(stageGateSystemPrompt, contains('reassign:成员名'));
      expect(stageGateSystemPrompt, contains('group_dispatch'));
      expect(stageGateSystemPrompt, contains('不要调用任何 UI 工具'));
    });
  });

  group('stageGateBypassWarning (M1)', () {
    test('returns null when the stage has no failures', () {
      expect(
        stageGateBypassWarning(
          stageIdx: 1,
          reason: '管理员不可用',
          stageSteps: [
            _step(
              stage: 0,
              step: 0,
              status: StepExecutionStatus.completed,
              outputSummary: '完成',
            ),
          ],
        ),
        isNull,
      );
    });

    test('returns null for empty stage', () {
      expect(
        stageGateBypassWarning(
          stageIdx: 1,
          reason: '管理员不可用',
          stageSteps: const [],
        ),
        isNull,
      );
    });

    test('names failed members and the bypass reason', () {
      final warning = stageGateBypassWarning(
        stageIdx: 2,
        reason: '管理员回复无可解析的 [GATE_DECISION]',
        stageSteps: [
          _step(stage: 1, step: 0, status: StepExecutionStatus.completed),
          _step(
            stage: 1,
            step: 1,
            agentName: 'Agent B',
            status: StepExecutionStatus.failed,
            errorMessage: '超时',
          ),
        ],
      );
      expect(warning, isNotNull);
      expect(warning, contains('阶段 3')); // stageIdx 是 0-based → 显示 +1
      expect(warning, contains('Agent B'));
      expect(warning, contains('GATE_DECISION'));
      expect(warning, contains('继续'));
    });

    test('deduplicates failed member names', () {
      final warning = stageGateBypassWarning(
        stageIdx: 0,
        reason: '门闸回合执行异常',
        stageSteps: [
          _step(
            stage: 0,
            step: 0,
            agentName: 'Agent B',
            status: StepExecutionStatus.failed,
          ),
          _step(
            stage: 0,
            step: 1,
            agentName: 'Agent B',
            status: StepExecutionStatus.failed,
          ),
        ],
      );
      expect(warning, isNotNull);
      expect('Agent B'.allMatches(warning!).length, 1);
    });
  });
}
