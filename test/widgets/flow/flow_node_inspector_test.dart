import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_executor.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_field_schema.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_field_editors.dart';
import 'package:shepaw/widgets/flow/flow_node_inspector.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

FlowSchema _schema() => FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {
        'task': [
          {'name': 'task.prompt', 'type': 'text', 'label': '提示词'},
        ],
      },
      'ops': [],
    })!;

FlowChoiceBundle _models({bool switchable = true}) => FlowChoiceBundle(
      models: FlowModelChoices(
        options: const [
          FlowModelChoice(value: 'm-fast', displayName: 'Fast'),
          FlowModelChoice(value: 'm-old', displayName: 'Old'),
        ],
        current: 'm-fast',
        switchable: switchable,
      ),
      modes: const FlowModelChoices(allowManual: true),
    );

/// 假的拉取器：计数、记住最后一次执行者，直接回一份可控候选，不碰数据库/主机。
class _FakeChoices {
  _FakeChoices(this.bundle);
  FlowChoiceBundle bundle;
  int calls = 0;
  FlowExecutor? last;

  Future<FlowChoiceBundle> load(
    FlowExecutor executor, {
    required String peerId,
    required Map<String, dynamic> roles,
    required void Function(FlowChoiceBundle cached) onCached,
  }) async {
    calls++;
    last = executor;
    return bundle;
  }
}

Widget _inspector({
  required Map<String, dynamic> fields,
  required FlowChoiceBundle bundle,
  required _FakeChoices fake,
  required void Function(Map<String, Object?>) onApply,
  Future<String?> Function()? onPickAgent,
  FlowAgentFace? Function(String id)? agentOf,
}) {
  return _app(FlowNodeInspector(
    node: FlowNode(key: 'impl', id: 'impl', kind: 'task', fields: fields),
    schema: _schema(),
    peerId: 'p1',
    roles: const [],
    choiceLoader: fake.load,
    onPickAgent: onPickAgent,
    agentOf: agentOf,
    onExecutorChanged: onApply,
    onFieldChanged: (_, __, {required immediate}) {},
  ));
}

void main() {
  testWidgets('执行者显示 Agent 头像和名称，不显示 id', (tester) async {
    const id = 'fb1d3f94-78f6-43fc-9ea6-07207c604a2d';
    final fake = _FakeChoices(_models());
    await tester.pumpWidget(_inspector(
      fields: {
        'task': {'prompt': '写', 'agent': id}
      },
      bundle: fake.bundle,
      fake: fake,
      onApply: (_) {},
      agentOf: (agentId) => agentId == id
          ? const FlowAgentFace(name: '审稿', avatar: '🦊')
          : null,
    ));
    await _settle(tester);
    expect(find.text('审稿'), findsOneWidget);
    expect(find.text(id), findsNothing);
    expect(find.text('🦊'), findsOneWidget);
  });

  testWidgets('点 Agent 直接选人，父级刷新不会把还没写回的选择清掉', (tester) async {
    final fake = _FakeChoices(_models());
    Map<String, Object?>? applied;
    final fields = {
      'task': {'prompt': '写'},
    };
    Widget page() => _inspector(
          fields: fields,
          bundle: fake.bundle,
          fake: fake,
          onApply: (ops) => applied = ops,
          onPickAgent: () async => 'agent-y',
          agentOf: (id) => id == 'agent-y'
              ? const FlowAgentFace(name: '审稿', avatar: '🦊')
              : null,
        );
    await tester.pumpWidget(page());
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('exec-agent')));
    await _settle(tester);
    expect(applied?['task.agent'], 'agent-y');
    expect(find.text('审稿'), findsOneWidget);

    await tester.pumpWidget(page());
    await _settle(tester);
    expect(find.text('审稿'), findsOneWidget);
    expect(find.text('先选择执行者'), findsNothing);
  });

  testWidgets('换 agent 会重新拉模型并清空已选的 model', (tester) async {
    final fake = _FakeChoices(_models());
    Map<String, Object?>? applied;
    await tester.pumpWidget(_inspector(
      fields: {
        'task': {'prompt': '写', 'agent': 'agent-x', 'model': 'm-old'}
      },
      bundle: fake.bundle,
      fake: fake,
      onApply: (changes) => applied = changes,
      onPickAgent: () async => 'agent-y',
    ));
    await _settle(tester);
    expect(fake.calls, 1);
    // 初始选中的是 m-old（显示名 Old）。
    expect(find.text('Old'), findsOneWidget);

    // 点「Agent」那一行 → onPickAgent 返回一个不同的 agent。
    await tester.tap(find.byKey(const ValueKey('exec-value')));
    await _settle(tester);
    expect(fake.calls, 2, reason: '换 agent 后应重新拉一次');
    expect(fake.last?.value, 'agent-y');
    // 已选 model 被清空，下拉回到「跟随 agent 默认」。
    expect(find.text('Old'), findsNothing);
    expect(find.textContaining('跟随 agent 默认'), findsWidgets);

    // 换执行者立刻提交，model 清成 null，和执行者在同一批里。
    expect(applied, isNotNull);
    expect(applied!.containsKey('task.model'), isTrue);
    expect(applied!['task.model'], isNull);
    expect(applied!['task.agent'], 'agent-y');
  });

  testWidgets('换 agent 保留 {{ inputs.model }} 模板值，不发 set(null)', (tester) async {
    final fake = _FakeChoices(_models());
    Map<String, Object?>? applied;
    await tester.pumpWidget(_inspector(
      fields: {
        'task': {
          'prompt': '写',
          'agent': 'agent-x',
          'model': '{{ inputs.model }}',
        }
      },
      bundle: fake.bundle,
      fake: fake,
      onApply: (changes) => applied = changes,
      onPickAgent: () async => 'agent-y',
    ));
    await _settle(tester);
    // 模板值走文本模式。
    expect(find.text('{{ inputs.model }}'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('exec-value')));
    await _settle(tester);
    expect(fake.calls, 2, reason: '换 agent 后仍要重新拉一次候选');
    // 模板值和具体 agent 无关，换 agent 不能把它清掉。
    expect(find.text('{{ inputs.model }}'), findsOneWidget);

    expect(applied, isNotNull);
    expect(applied!.containsKey('task.model'), isFalse,
        reason: '值没变，不能发一条 set(null) 把模板清掉');
    expect(applied!['task.agent'], 'agent-y');
  });

  testWidgets('A3-3 换 agent 后、异步结果回来前不再显示旧 agent 的模型', (tester) async {
    final first = _models();
    final lateBundle = Completer<FlowChoiceBundle>();
    var calls = 0;
    FlowExecutor? last;
    Future<FlowChoiceBundle> load(
      FlowExecutor executor, {
      required String peerId,
      required Map<String, dynamic> roles,
      required void Function(FlowChoiceBundle cached) onCached,
    }) {
      calls++;
      last = executor;
      if (executor.value == 'agent-y') return lateBundle.future;
      return Future.value(first);
    }

    await tester.pumpWidget(_app(FlowNodeInspector(
      node: const FlowNode(key: 'impl', id: 'impl', kind: 'task', fields: {
        'task': {'agent': 'agent-x', 'model': 'm-old'}
      }),
      schema: _schema(),
      peerId: 'p1',
      roles: const [],
      choiceLoader: load,
      onPickAgent: () async => 'agent-y',
      onExecutorChanged: (_) {},
    )));
    await _settle(tester);
    expect(calls, 1);
    expect(find.text('Old'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('exec-value')));
    await _settle(tester);
    // 新 agent 的请求还挂着：旧列表必须已经清掉，不能继续让用户选。
    expect(calls, 2);
    expect(last?.value, 'agent-y');
    expect(find.text('Old'), findsNothing, reason: '异步结果回来前必须先把旧 agent 的模型清掉');
    expect(find.text('正在加载模型…'), findsWidgets);

    // 新结果回来后才显示新 agent 的模型。
    lateBundle.complete(const FlowChoiceBundle(
      models: FlowModelChoices(
        options: [FlowModelChoice(value: 'm-new', displayName: 'New')],
        current: 'm-new',
      ),
      modes: FlowModelChoices(),
    ));
    await _settle(tester);
    expect(find.text('Old'), findsNothing);
    expect(find.text('正在加载模型…'), findsNothing, reason: '新结果回来后不该还在 loading');
    // 当前值已经换成新 agent 的 m-new（下拉收起时显示「跟随 agent 默认」那一项）。
    expect(find.textContaining('m-new'), findsWidgets);
  });

  testWidgets('switchable=false 时模型下拉禁用并给出提示', (tester) async {
    final fake = _FakeChoices(_models(switchable: false));
    await tester.pumpWidget(_inspector(
      fields: {
        'task': {'prompt': '写', 'agent': 'agent-x', 'model': 'm-old'}
      },
      bundle: fake.bundle,
      fake: fake,
      onApply: (_) {},
    ));
    await _settle(tester);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('f:task.model')),
    );
    expect(dropdown.onChanged, isNull);
    expect(find.text('这个 agent 不支持切换模型'), findsOneWidget);
  });

  testWidgets('模板值 {{ inputs.model }} 走文本模式', (tester) async {
    final fake = _FakeChoices(_models());
    Object? emitted;
    await tester.pumpWidget(_app(FlowFieldEditor(
      spec: const FlowFieldSpec(
        path: 'task.model',
        shape: FlowFieldShape.modelRef,
        labelZh: '模型',
        labelEn: 'Model',
      ),
      current: '{{ inputs.model }}',
      choices: fake.bundle.models,
      onChanged: (v) => emitted = v,
    )));
    await _settle(tester);
    // 文本模式：是一个可直接编辑的 TextField，不是下拉。
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('f:task.model'))),
      isNotNull,
    );
    expect(find.text('{{ inputs.model }}'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('choice-pick:task.model')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('f:task.model')), '{{ inputs.other }}');
    await tester.pump();
    expect(emitted, '{{ inputs.other }}');
  });

  testWidgets('YAML 里的值已不在列表里时显示「不可用」红条目', (tester) async {
    final fake = _FakeChoices(_models());
    await tester.pumpWidget(_inspector(
      fields: {
        'task': {'prompt': '写', 'agent': 'agent-x', 'model': 'm-retired'}
      },
      bundle: fake.bundle,
      fake: fake,
      onApply: (_) {},
    ));
    await _settle(tester);
    expect(find.text('m-retired（不可用）'), findsOneWidget);
  });

  testWidgets('A8-7: 空候选 + allowManual 时仍能手输模板', (tester) async {
    final fake = _FakeChoices(const FlowChoiceBundle(
      models: FlowModelChoices(allowManual: true),
      modes: FlowModelChoices(allowManual: true),
    ));
    Object? emitted;
    await tester.pumpWidget(_app(FlowNodeInspector(
      node: const FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        fields: {
          'task': {'prompt': '写', 'agent': 'agent-x'},
        },
      ),
      schema: _schema(),
      peerId: 'p1',
      roles: const [],
      choiceLoader: fake.load,
      onExecutorChanged: (_) {},
    )));
    await _settle(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('choice-manual:task.model')));
    await tester.tap(find.byKey(const ValueKey('choice-manual:task.model')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('f:task.model')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('f:task.model')), '{{ inputs.model }}');
    await tester.pump();
    expect(find.text('{{ inputs.model }}'), findsOneWidget);
    expect(emitted, isNull);
  });

  testWidgets('A8-8: switchable=false + 模板值只读，不给可编辑输入框', (tester) async {
    Object? emitted = 'unset';
    await tester.pumpWidget(_app(FlowFieldEditor(
      spec: const FlowFieldSpec(
        path: 'task.model',
        shape: FlowFieldShape.modelRef,
        labelZh: '模型',
        labelEn: 'Model',
      ),
      current: '{{ inputs.model }}',
      choices: const FlowModelChoices(
        switchable: false,
        allowManual: true,
        options: [FlowModelChoice(value: 'm-locked')],
      ),
      onChanged: (v) => emitted = v,
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('f:task.model')), findsNothing,
        reason: '不可切换的 agent 不能被模板值绕过锁定');
    expect(find.byKey(const ValueKey('choice-manual:task.model')), findsNothing,
        reason: '手动入口同样要遵守 switchable=false');
    expect(find.byKey(const ValueKey('choice-pick:task.model')), findsNothing);
    expect(find.text('{{ inputs.model }}'), findsOneWidget,
        reason: '模板值仍应只读展示');
    expect(find.text('这个 agent 不支持切换模型'), findsOneWidget);
    expect(emitted, 'unset', reason: '只读展示不该发出任何改动');
  });
}
