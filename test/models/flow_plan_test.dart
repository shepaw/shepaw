import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/planning_models.dart';

void main() {
  // ---------------------------------------------------------------------------
  // FlowPlan.tryParse
  // ---------------------------------------------------------------------------
  group('FlowPlan.tryParse', () {
    const validJson = '''
[FLOW_PLAN]
{
  "title": "Test Flow",
  "summary": "A test flow plan",
  "stages": [
    {
      "stage_id": "s1",
      "label": "Analysis",
      "steps": [
        {
          "step_id": "s1_t1",
          "task_id": "task_1",
          "agent": "AgentA",
          "instruction": "Do analysis",
          "depends_on": [],
          "estimated_complexity": "medium"
        }
      ]
    },
    {
      "stage_id": "s2",
      "label": "Execution",
      "steps": [
        {
          "step_id": "s2_t1",
          "task_id": "task_2",
          "agent": "AgentB",
          "instruction": "Do execution",
          "depends_on": ["s1_t1"],
          "estimated_complexity": "high"
        },
        {
          "step_id": "s2_t2",
          "task_id": "task_3",
          "agent": "AgentC",
          "instruction": "Do another thing",
          "depends_on": [],
          "estimated_complexity": "low"
        }
      ]
    }
  ]
}
[/FLOW_PLAN]
Some natural language explanation here.
''';

    test('parses valid [FLOW_PLAN] block', () {
      final plan = FlowPlan.tryParse(validJson);
      expect(plan, isNotNull);
      expect(plan!.title, 'Test Flow');
      expect(plan.summary, 'A test flow plan');
      expect(plan.stages.length, 2);
      expect(plan.stages[0].stageId, 's1');
      expect(plan.stages[0].label, 'Analysis');
      expect(plan.stages[0].steps.length, 1);
      expect(plan.stages[0].steps[0].stepId, 's1_t1');
      expect(plan.stages[0].steps[0].agent, 'AgentA');
      expect(plan.stages[1].steps.length, 2);
    });

    test('returns null when no [FLOW_PLAN] block present', () {
      const text = 'This is just a normal message with no flow plan.';
      expect(FlowPlan.tryParse(text), isNull);
    });

    test('returns null for malformed JSON', () {
      const badJson = '[FLOW_PLAN]{ invalid json }[/FLOW_PLAN]';
      expect(FlowPlan.tryParse(badJson), isNull);
    });

    test('returns null when [PLAN] block used instead of [FLOW_PLAN]', () {
      const planText = '[PLAN]{"title":"x","summary":"y","tasks":[]}[/PLAN]';
      expect(FlowPlan.tryParse(planText), isNull);
    });

    test('parsing is case-insensitive for tags', () {
      const mixedCase = '[flow_plan]{"title":"T","summary":"S","stages":[]}[/flow_plan]';
      final plan = FlowPlan.tryParse(mixedCase);
      expect(plan, isNotNull);
      expect(plan!.title, 'T');
    });
  });

  // ---------------------------------------------------------------------------
  // FlowPlan.stripFlowPlanBlock
  // ---------------------------------------------------------------------------
  group('FlowPlan.stripFlowPlanBlock', () {
    test('strips [FLOW_PLAN] block, keeps surrounding text', () {
      const text = 'Intro text.\n[FLOW_PLAN]{"a":1}[/FLOW_PLAN]\nOutro text.';
      final stripped = FlowPlan.stripFlowPlanBlock(text);
      expect(stripped, isNot(contains('[FLOW_PLAN]')));
      expect(stripped, contains('Intro text.'));
      expect(stripped, contains('Outro text.'));
    });

    test('returns same string when no block present', () {
      const text = 'No block here.';
      expect(FlowPlan.stripFlowPlanBlock(text), text);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowPlan.toExecutionPlan (bridge method)
  // ---------------------------------------------------------------------------
  group('FlowPlan.toExecutionPlan', () {
    test('flattened PlanTask count equals total steps across all stages', () {
      final plan = FlowPlan(
        title: 'T',
        summary: 'S',
        stages: [
          FlowStage(
            stageId: 's1',
            label: 'Stage 1',
            steps: [
              FlowStep(stepId: 's1_t1', taskId: 't1', agent: 'A', instruction: 'Do X'),
              FlowStep(stepId: 's1_t2', taskId: 't2', agent: 'B', instruction: 'Do Y'),
            ],
          ),
          FlowStage(
            stageId: 's2',
            label: 'Stage 2',
            steps: [
              FlowStep(stepId: 's2_t1', taskId: 't3', agent: 'C', instruction: 'Do Z'),
            ],
          ),
        ],
      );

      final execPlan = plan.toExecutionPlan();
      expect(execPlan.tasks.length, 3);
      expect(execPlan.title, 'T');
      expect(execPlan.summary, 'S');
    });

    test('each PlanTask maps to the corresponding FlowStep', () {
      final step = FlowStep(
        stepId: 's1_t1',
        taskId: 'task_1',
        agent: 'AgentX',
        instruction: 'instruction text',
        estimatedComplexity: 'high',
      );
      final plan = FlowPlan(
        title: 'T',
        summary: 'S',
        stages: [FlowStage(stageId: 's1', label: 'L', steps: [step])],
      );

      final execPlan = plan.toExecutionPlan();
      final task = execPlan.tasks.first;
      expect(task.id, 's1_t1');
      expect(task.title, 'task_1');
      expect(task.description, 'instruction text');
      expect(task.assignee, 'AgentX');
      expect(task.estimatedComplexity, 'high');
    });

    test('empty stages produces empty tasks list', () {
      final plan = FlowPlan(title: 'T', summary: 'S', stages: []);
      expect(plan.toExecutionPlan().tasks, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowPlan.applySkippedStepIds
  // ---------------------------------------------------------------------------
  group('FlowPlan.applySkippedStepIds', () {
    test('marks matching steps as skipped', () {
      final step1 = FlowStep(stepId: 's1_t1', taskId: 't1', agent: 'A', instruction: 'I');
      final step2 = FlowStep(stepId: 's2_t1', taskId: 't2', agent: 'B', instruction: 'I');
      final plan = FlowPlan(
        title: 'T',
        summary: 'S',
        stages: [
          FlowStage(stageId: 's1', label: 'L', steps: [step1]),
          FlowStage(stageId: 's2', label: 'L', steps: [step2]),
        ],
      );

      plan.applySkippedStepIds({'s2_t1'});

      expect(step1.status, TaskStatus.pending);
      expect(step2.status, TaskStatus.skipped);
    });

    test('no-op when empty set passed', () {
      final step = FlowStep(stepId: 's1_t1', taskId: 't1', agent: 'A', instruction: 'I');
      final plan = FlowPlan(
        title: 'T',
        summary: 'S',
        stages: [FlowStage(stageId: 's1', label: 'L', steps: [step])],
      );
      plan.applySkippedStepIds({});
      expect(step.status, TaskStatus.pending);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowStage.isDone / hasFailed
  // ---------------------------------------------------------------------------
  group('FlowStage computed properties', () {
    test('isDone when all steps are done', () {
      final stage = FlowStage(
        stageId: 's1',
        label: 'L',
        steps: [
          FlowStep(stepId: 'a', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.done),
          FlowStep(stepId: 'b', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.skipped),
        ],
      );
      expect(stage.isDone, isTrue);
      expect(stage.hasFailed, isFalse);
    });

    test('isDone is false when a step is still pending', () {
      final stage = FlowStage(
        stageId: 's1',
        label: 'L',
        steps: [
          FlowStep(stepId: 'a', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.done),
          FlowStep(stepId: 'b', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.pending),
        ],
      );
      expect(stage.isDone, isFalse);
    });

    test('hasFailed when at least one step failed', () {
      final stage = FlowStage(
        stageId: 's1',
        label: 'L',
        steps: [
          FlowStep(stepId: 'a', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.done),
          FlowStep(stepId: 'b', taskId: 't', agent: 'A', instruction: 'I', status: TaskStatus.failed),
        ],
      );
      expect(stage.hasFailed, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowCtrlCommand.tryParse
  // ---------------------------------------------------------------------------
  group('FlowCtrlCommand.tryParse', () {
    test('parses pause action', () {
      const text = '[FLOW_CTRL]\n{"action": "pause"}\n[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd, isNotNull);
      expect(cmd!.action, FlowCtrlAction.pause);
    });

    test('parses resume action', () {
      const text = '[FLOW_CTRL]{"action": "resume"}[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd!.action, FlowCtrlAction.resume);
    });

    test('parses skip_step action with step_id', () {
      const text = '[FLOW_CTRL]{"action": "skip_step", "step_id": "s2_t1", "message": "not needed"}[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd!.action, FlowCtrlAction.skipStep);
      expect(cmd.targetStepId, 's2_t1');
      expect(cmd.message, 'not needed');
    });

    test('parses retry_task action', () {
      const text = '[FLOW_CTRL]{"action": "retry_task", "step_id": "s1_t2"}[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd!.action, FlowCtrlAction.retryTask);
      expect(cmd.targetStepId, 's1_t2');
    });

    test('parses inject_message action', () {
      const text = '[FLOW_CTRL]{"action": "inject_message", "message": "extra context"}[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd!.action, FlowCtrlAction.injectMessage);
      expect(cmd.message, 'extra context');
    });

    test('parses abort action', () {
      const text = '[FLOW_CTRL]{"action": "abort"}[/FLOW_CTRL]';
      final cmd = FlowCtrlCommand.tryParse(text);
      expect(cmd!.action, FlowCtrlAction.abort);
    });

    test('returns null when no [FLOW_CTRL] block present', () {
      expect(FlowCtrlCommand.tryParse('No control here.'), isNull);
    });

    test('returns null for unknown action string', () {
      const text = '[FLOW_CTRL]{"action": "unknown_action"}[/FLOW_CTRL]';
      expect(FlowCtrlCommand.tryParse(text), isNull);
    });

    test('returns null for malformed JSON', () {
      const text = '[FLOW_CTRL]{bad json}[/FLOW_CTRL]';
      expect(FlowCtrlCommand.tryParse(text), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowCtrlCommand.stripFlowCtrlBlock
  // ---------------------------------------------------------------------------
  group('FlowCtrlCommand.stripFlowCtrlBlock', () {
    test('removes [FLOW_CTRL] block from text', () {
      const text = 'Preamble.\n[FLOW_CTRL]{"action":"pause"}[/FLOW_CTRL]\nPostamble.';
      final stripped = FlowCtrlCommand.stripFlowCtrlBlock(text);
      expect(stripped, isNot(contains('[FLOW_CTRL]')));
      expect(stripped, contains('Preamble.'));
      expect(stripped, contains('Postamble.'));
    });
  });

  // ---------------------------------------------------------------------------
  // FlowStep.toPlanTask
  // ---------------------------------------------------------------------------
  group('FlowStep.toPlanTask', () {
    test('converts correctly to PlanTask', () {
      final step = FlowStep(
        stepId: 's1_t1',
        taskId: 'my_task',
        agent: 'AgentFoo',
        instruction: 'Do the thing',
        dependsOn: ['dep1'],
        estimatedComplexity: 'low',
        status: TaskStatus.inProgress,
      );
      final task = step.toPlanTask();
      expect(task.id, 's1_t1');
      expect(task.title, 'my_task');
      expect(task.description, 'Do the thing');
      expect(task.assignee, 'AgentFoo');
      expect(task.dependencies, ['dep1']);
      expect(task.estimatedComplexity, 'low');
      expect(task.status, TaskStatus.inProgress);
    });
  });

  // ---------------------------------------------------------------------------
  // FlowPlan JSON round-trip
  // ---------------------------------------------------------------------------
  group('FlowPlan JSON round-trip', () {
    test('toJson / fromJson preserves all fields', () {
      final original = FlowPlan(
        title: 'My Plan',
        summary: 'A summary',
        stages: [
          FlowStage(
            stageId: 's1',
            label: 'Phase 1',
            steps: [
              FlowStep(
                stepId: 's1_t1',
                taskId: 'task_a',
                agent: 'Bot',
                instruction: 'Execute',
                dependsOn: [],
                estimatedComplexity: 'high',
              ),
            ],
          ),
        ],
      );

      final json = original.toJson();
      final restored = FlowPlan.fromJson(json);

      expect(restored.title, original.title);
      expect(restored.summary, original.summary);
      expect(restored.stages.length, 1);
      expect(restored.stages[0].stageId, 's1');
      expect(restored.stages[0].steps[0].stepId, 's1_t1');
      expect(restored.stages[0].steps[0].agent, 'Bot');
    });
  });
}
