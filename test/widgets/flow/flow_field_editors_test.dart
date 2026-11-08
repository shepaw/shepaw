import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_field_schema.dart';
import 'package:shepaw/widgets/flow/flow_field_editors.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_app(child));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

FlowFieldSpec _spec(String path, FlowFieldShape shape,
        {List<String> options = const [], bool required = false}) =>
    FlowFieldSpec(
      path: path,
      shape: shape,
      labelZh: path,
      labelEn: path,
      options: options,
      required: required,
    );

void main() {
  testWidgets('listOf 把每一行编成字符串列表，空的给 null', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('gate.options', FlowFieldShape.listOf),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add:gate.options')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('f:gate.options-0')), '通过');
    await tester.pump();
    expect(value, ['通过']);
  });

  testWidgets('mapOf 编成键值映射', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('set.vars', FlowFieldShape.mapOf),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add:set.vars')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('f:set.vars-k0')), 'n');
    await tester.enterText(
        find.byKey(const ValueKey('f:set.vars-v0')), '{{ inputs.goal }}');
    await tester.pump();
    expect(value, {'n': '{{ inputs.goal }}'});
  });

  testWidgets('mapOf 重名时不把两行收成一个值', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('set.vars', FlowFieldShape.mapOf),
        current: {'keep': '1', 'other': '2'},
        onChanged: (v) => value = v,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('f:set.vars-k1')), 'keep');
    await tester.pump();
    expect(value, isA<List>());
    expect(value, isNot(isA<Map>()));
  });

  testWidgets('boolean 三态：不选 / true / false', (tester) async {
    Object? value = 'unset';
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('plan.allow_empty', FlowFieldShape.boolean),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    expect(value, 'unset'); // 没动过就不发
    await tester.tap(find.byKey(const ValueKey('f:plan.allow_empty')));
    await tester.pump();
    expect(value, true);
  });

  testWidgets('outputMap 枚举值编成 {enum: [...]}', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('task.output', FlowFieldShape.outputMap),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add:task.output')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('f:task.output-k0')), 'verdict');
    await tester.pump();
    // 类型/枚举下拉。
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('枚举').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('f:task.output-enum0')), 'pass, revise');
    await tester.pump();
    expect(value, {
      'verdict': {
        'enum': ['pass', 'revise'],
      }
    });
  });

  testWidgets('cond 让人判断编成 {judge, ask}', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('when', FlowFieldShape.cond),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.text('让人判断'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('f:when')), 'owner');
    await tester.pump();
    expect(value, {'judge': 'owner', 'ask': ''});
  });

  testWidgets('int 形状解析失败时不发字符串', (tester) async {
    Object? value = 'unset';
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('retry.max', FlowFieldShape.int),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('f:retry.max')), 'abc');
    await tester.pump();
    // 发出去会让主机 M1.5 拒掉整批。
    expect(value, isNull);
    await tester.enterText(find.byKey(const ValueKey('f:retry.max')), '3');
    await tester.pump();
    expect(value, 3);
  });

  testWidgets('intOrInput 的数字写成 int，引用写成模板串', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('loop.max', FlowFieldShape.intOrInput, required: true),
        current: null,
        onChanged: (v) => value = v,
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('f:loop.max')), '5');
    await tester.pump();
    expect(value, 5);
    await tester.enterText(
        find.byKey(const ValueKey('f:loop.max')), '{{ inputs.rounds }}');
    await tester.pump();
    expect(value, '{{ inputs.rounds }}');
  });

  testWidgets('outputMap 未编辑的行原样保留结构化值', (tester) async {
    const original = {
      'verdict': {
        'enum': ['pass', 'reject, revise'],
      },
      'score': 'int',
    };
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('task.output', FlowFieldShape.outputMap),
        current: original,
        onChanged: (v) => value = v,
      ),
    );
    // 「加一行」会触发一次整表编码；未动过的两行必须原样带回。
    await tester.tap(find.byKey(const ValueKey('add:task.output')));
    await tester.pump();
    expect(value, original);
  });

  testWidgets('flowRef 可以从流程库里选，不用手敲引用', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('call.flow', FlowFieldShape.flowRef),
        current: null,
        flowRefChoices: const ['lib/helper', 'lib/review'],
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('pick:call.flow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-ref-lib/helper')));
    await tester.pumpAndSettle();
    expect(value, 'lib/helper');
  });

  testWidgets('长文本随内容自动长高，短 id 标量仍旧单行', (tester) async {
    // text：提示词 / 说明这类长文本。
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('task.prompt', FlowFieldShape.text),
        current: '短',
        onChanged: (_) {},
      ),
    );
    final prompt = find.byKey(const ValueKey('f:task.prompt'));
    expect(tester.widget<TextField>(prompt).maxLines, isNull,
        reason: '长文本不能限死行数');
    expect(tester.widget<TextField>(prompt).minLines, 4);
    final before = tester.getSize(prompt).height;
    await tester.enterText(prompt, '一\n二\n三\n四\n五\n六');
    await tester.pump();
    expect(tester.getSize(prompt).height, greaterThan(before));

    // string：task.uses / call.group / plan.who 这类 id，放开多行会把换行
    // 原样发给主机（agent:<id>\n 解析不出 Agent）。
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('task.uses', FlowFieldShape.string),
        current: 'agent:claude-main',
        onChanged: (_) {},
      ),
    );
    final uses = find.byKey(const ValueKey('f:task.uses'));
    expect(tester.widget<TextField>(uses).maxLines, 1);
    expect(tester.widget<TextField>(uses).keyboardType,
        isNot(TextInputType.multiline));
  });

  testWidgets('当前值变了靠值派生 key 重新播种', (tester) async {
    Object? value;
    Widget editor(Object? current) => FlowFieldEditor(
          key: ValueKey('editor-$current'),
          spec: _spec('task.prompt', FlowFieldShape.text),
          current: current,
          onChanged: (v) => value = v,
        );

    await _pump(tester, editor('旧值'));
    expect(find.text('旧值'), findsOneWidget);
    await tester.pumpWidget(_app(editor('新值')));
    await tester.pump();
    expect(find.text('新值'), findsOneWidget);
    // 重播种不该当成用户改动发出去。
    expect(value, isNull);
  });

  testWidgets('intOrInput 能从输入里挑一个引用', (tester) async {
    Object? value;
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('loop.max', FlowFieldShape.intOrInput, required: true),
        current: null,
        intInputNames: const ['rounds'],
        onChanged: (v) => value = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('int-input:loop.max')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('inputs.rounds').last);
    await tester.pumpAndSettle();
    expect(value, '{{ inputs.rounds }}');
  });

  testWidgets('modelRef 只有在 allowManual && switchable 时才给手动输入', (tester) async {
    FlowFieldEditor editor(FlowModelChoices choices) => FlowFieldEditor(
          spec: _spec('task.model', FlowFieldShape.modelRef),
          current: null,
          choices: choices,
          onChanged: (_) {},
        );
    const options = [FlowModelChoice(value: 'm-1')];

    // switchable=false：模型由远端配置，手输等于绕过它 —— 入口完全隐藏。
    await _pump(
      tester,
      editor(const FlowModelChoices(
        options: options,
        switchable: false,
        allowManual: true,
      )),
    );
    expect(
        find.byKey(const ValueKey('choice-manual:task.model')), findsNothing);

    // allowManual=false：不允许手输时也不露出按钮。
    await _pump(
      tester,
      editor(const FlowModelChoices(
        options: options,
        allowManual: false,
      )),
    );
    expect(
        find.byKey(const ValueKey('choice-manual:task.model')), findsNothing);

    // 两者都满足才显示（role / unset 的手输兜底）。
    await _pump(
      tester,
      editor(const FlowModelChoices(
        options: options,
        allowManual: true,
      )),
    );
    expect(
        find.byKey(const ValueKey('choice-manual:task.model')), findsOneWidget);
  });

  testWidgets('modelRef 下拉写入模型 id，「跟随默认」写 null', (tester) async {
    Object? value = 'unset';
    const choices = FlowModelChoices(
      options: [
        FlowModelChoice(value: 'm-1', displayName: '一'),
        FlowModelChoice(value: 'm-2', displayName: '二'),
      ],
      current: 'm-1',
    );
    await _pump(
      tester,
      FlowFieldEditor(
        spec: _spec('task.model', FlowFieldShape.modelRef),
        current: null,
        choices: choices,
        onChanged: (v) => value = v,
      ),
    );
    expect(value, 'unset'); // 没动过不发
    await tester.tap(find.byKey(const ValueKey('f:task.model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('二').last);
    await tester.pumpAndSettle();
    // 写入的是 value（模型 id），不是显示名。
    expect(value, 'm-2');

    await tester.tap(find.byKey(const ValueKey('f:task.model')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('跟随 agent 默认').last);
    await tester.pumpAndSettle();
    expect(value, isNull);
  });
}
