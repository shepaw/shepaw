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

  test('peekRoleDefaults 读出模板自带的兜底 Agent', () {
    const yaml = 'flow: dev\nroles:\n  coder: {desc: 写}\n  reviewer: {desc: 审, default: codex-main}\n  owner: {default: "{{ inputs.agent }}"}\nsteps: []\n';
    expect(peekRoleDefaults(yaml), {'reviewer': 'codex-main'},
        reason: '模板值不是 Agent id，不能预填成绑定');
    expect(peekRoleDefaults('flow: dev\nsteps: []\n'), isEmpty);
    expect(peekRoleDefaults('::: not yaml'), isEmpty);
  });

  group('peekUsedRoles', () {
    test('模板节点全改成 agent：声明过的角色不再要求绑定', () {
      const yaml = '''
flow: dev
roles:
  coder: {desc: 写代码}
  reviewer: {desc: 审代码}
steps:
  - id: impl
    task: {agent: claude-main, prompt: 写}
  - id: review
    task: {agent: codex-main, prompt: 审}
''';
      expect(peekRoles(yaml), ['coder', 'reviewer']);
      expect(peekUsedRoles(yaml), isEmpty,
          reason: '节点已经绑好 Agent，开跑表单不该再挨个问角色');
    });

    test('嵌套容器里还在用 role 的节点照样要绑定', () {
      const yaml = '''
flow: dev
roles:
  coder: {desc: 写}
  reviewer: {desc: 审}
steps:
  - id: build
    loop:
      max: 3
      steps:
        - id: impl
          par:
            steps:
              - id: backend
                task: {role: coder, prompt: 后端}
        - id: review
          task: {role: reviewer, prompt: 审, output: {role: string}}
''';
      expect(peekUsedRoles(yaml), ['coder', 'reviewer'],
          reason: 'output.role 是输出字段名，不能被当成角色引用');
    });

    test('uses: role:<name> 和 plan.who 的角色名也算，owner 不算', () {
      const yaml = '''
flow: dev
roles:
  owner: {desc: 负责人}
  coder: {desc: 写}
steps:
  - id: impl
    task: {uses: "role:coder", prompt: 写}
  - id: dispatch
    plan: {who: coder, brief: 拆任务}
  - id: lead
    plan: {who: owner, brief: 主持}
''';
      // owner / user / she / agent:<id> 主机 judge_agent 自己会兜底。
      expect(peekUsedRoles(yaml), ['coder']);
    });

    test('节点手写了没在 roles 里声明的角色也要问一次绑定', () {
      const yaml = 'flow: dev\nsteps:\n  - id: impl\n    task: {role: ghost, prompt: 写}\n';
      expect(peekUsedRoles(yaml), ['ghost']);
    });

    test('只有部分角色还用着：只返回用上的那些', () {
      const yaml = '''
flow: dev
roles:
  coder: {desc: 写}
  reviewer: {desc: 审}
steps:
  - id: impl
    task: {role: reviewer, prompt: 写}
''';
      expect(peekUsedRoles(yaml), ['reviewer']);
    });

    test('坏 YAML / 没有步骤都不抛', () {
      expect(peekUsedRoles('::: not yaml'), isEmpty);
      expect(peekUsedRoles('flow: x\nsteps: []\n'), isEmpty);
    });
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
