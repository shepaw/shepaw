import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_executor.dart';

void main() {
  group('FlowExecutor.of', () {
    test('认得 role / agent / 惜宝', () {
      expect(
        FlowExecutor.of({
          'task': {'role': 'coder', 'prompt': '写'}
        }).mode,
        FlowExecutorMode.role,
      );
      expect(
        FlowExecutor.of({
          'task': {'agent': 'claude-main', 'prompt': '写'}
        }).mode,
        FlowExecutorMode.agent,
      );
      expect(
        FlowExecutor.of({
          'task': {'uses': 'she', 'prompt': '写'}
        }).mode,
        FlowExecutorMode.she,
      );
    });

    test('`uses: agent:<id>` 按 Agent 呈现', () {
      final executor = FlowExecutor.of({
        'task': {'uses': 'agent:claude-main', 'prompt': '写'}
      });
      expect(executor.mode, FlowExecutorMode.agent);
      expect(executor.value, 'claude-main');
    });

    test('什么都没写就是未设置', () {
      expect(FlowExecutor.of({'task': {'prompt': '写'}}).mode,
          FlowExecutorMode.unset);
      expect(FlowExecutor.of(null).mode, FlowExecutorMode.unset);
    });
  });

  group('ops', () {
    test('选了角色就把另外两个清掉', () {
      expect(FlowExecutor.role('coder').ops(), {
        'task.role': 'coder',
        'task.agent': null,
        'task.uses': null,
      });
    });

    test('选了惜宝就写 uses: she，清掉角色和 Agent', () {
      expect(FlowExecutor.she.ops(), {
        'task.role': null,
        'task.agent': null,
        'task.uses': 'she',
      });
    });

    test('选了 Agent 就清掉角色', () {
      expect(FlowExecutor.agent('claude-main').ops(), {
        'task.role': null,
        'task.agent': 'claude-main',
        'task.uses': null,
      });
    });
  });

  test('peekRoles 只读出角色名', () {
    expect(
      peekRoles('flow: dev\nroles:\n  coder: {desc: 写代码}\n  reviewer: {desc: 审}\nsteps: []\n'),
      ['coder', 'reviewer'],
    );
    // 没有 roles、或者根本不是 YAML，都给空列表而不是抛。
    expect(peekRoles('flow: dev\nsteps: []\n'), isEmpty);
    expect(peekRoles('::: not yaml'), isEmpty);
  });

  test('peekInputs 读出类型、必填和默认值', () {
    final specs = peekInputs(
      'flow: dev\ninputs:\n  goal: {type: string, required: true}\n  rounds: {type: int, default: 3}\nsteps: []\n',
    );
    expect(specs.map((s) => s.name), ['goal', 'rounds']);
    expect(specs.first.type, 'string');
    expect(specs.first.required, isTrue);
    expect(specs.last.type, 'int');
    expect(specs.last.defaultValue, '3');
  });

  test('FlowHeaderPeek 读 description / limits / outputs', () {
    const yaml = 'flow: dev\ndescription: 先设计再实现\nlimits: {max_tasks: 30, timeout: 2h}\noutputs:\n  report: "{{ summary.text }}"\nsteps: []\n';
    expect(FlowHeaderPeek.description(yaml), '先设计再实现');
    expect(FlowHeaderPeek.limits(yaml).maxTasks, 30);
    expect(FlowHeaderPeek.limits(yaml).timeout, '2h');
    expect(FlowHeaderPeek.outputs(yaml), {'report': '{{ summary.text }}'});
    // 没写就给安全默认值，不抛。
    expect(FlowHeaderPeek.description('flow: x\n'), '');
    expect(FlowHeaderPeek.limits('flow: x\n').maxTasks, 0);
    expect(FlowHeaderPeek.outputs('flow: x\n'), isEmpty);
    expect(FlowHeaderPeek.limits('::: not yaml').maxTasks, 0);
  });
}
