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
    await tester.enterText(find.byKey(const ValueKey('f:set.vars-k0')), 'n');
    await tester.enterText(
        find.byKey(const ValueKey('f:set.vars-v0')), '{{ inputs.goal }}');
    await tester.pump();
    expect(value, {'n': '{{ inputs.goal }}'});
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('true').last);
    await tester.pumpAndSettle();
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
}
