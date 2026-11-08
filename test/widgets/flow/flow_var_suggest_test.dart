import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_references.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_field_schema.dart';
import 'package:shepaw/widgets/flow/flow_field_editors.dart';

void main() {
  testWidgets('输入 {{ 后点 prev，接着列出它下面的步骤', (tester) async {
    const spec = FlowFieldSpec(
      path: 'task.prompt',
      shape: FlowFieldShape.text,
      group: 'what',
      labelZh: '提示词',
      labelEn: 'Prompt',
    );
    final roots = [
      const FlowVarNode(
        segment: 'prev',
        hint: '上一轮',
        children: [
          FlowVarNode(segment: 'review', hint: 'task'),
        ],
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FlowFieldEditor(
          spec: spec,
          current: '',
          varRoots: roots,
          onChanged: (_) {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('f:task.prompt')));
    await tester.pump();
    expect(find.byKey(const ValueKey('var-suggest')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '{{');
    await tester.pump();
    expect(find.byKey(const ValueKey('var-opt-prev')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('var-opt-prev')));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('f:task.prompt'))).controller!.text,
      '{{prev.',
    );
    expect(find.byKey(const ValueKey('var-opt-review')), findsOneWidget);
  });

  testWidgets('条件表达式获得焦点就列出变量，点选写入裸路径', (tester) async {
    await _pumpSuggest(
      tester,
      const FlowFieldSpec(
        path: 'loop.until',
        shape: FlowFieldShape.cond,
        group: 'loop',
        labelZh: '直到',
        labelEn: 'Until',
      ),
      '',
    );
    expect(find.byKey(const ValueKey('var-suggest')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('f:loop.until')));
    await tester.pump();
    expect(find.byKey(const ValueKey('var-opt-prev')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('var-opt-prev')));
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('f:loop.until')));
    expect(field.controller!.text, 'prev.');
    expect(find.byKey(const ValueKey('var-opt-review')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('var-opt-review')));
    await tester.pump();
    expect(field.controller!.text, 'prev.review');
    expect(find.byKey(const ValueKey('var-suggest')), findsNothing);
  });

  testWidgets('何时切到表达式后，焦点同样列出变量', (tester) async {
    await _pumpSuggest(
      tester,
      const FlowFieldSpec(
        path: 'when',
        shape: FlowFieldShape.cond,
        group: 'when',
        labelZh: '何时',
        labelEn: 'When',
      ),
      '',
    );
    await tester.tap(find.byKey(const ValueKey('f:when')));
    await tester.pump();
    expect(find.byKey(const ValueKey('var-suggest')), findsNothing);

    await tester.tap(find.text('表达式'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('f:when')));
    await tester.pump();
    expect(find.byKey(const ValueKey('var-opt-prev')), findsOneWidget);
  });

  testWidgets('次数输入 {{ 也列出变量', (tester) async {
    await _pumpSuggest(
      tester,
      const FlowFieldSpec(
        path: 'loop.max',
        shape: FlowFieldShape.intOrInput,
        group: 'loop',
        labelZh: '最多几轮',
        labelEn: 'Max',
      ),
      '',
    );
    await tester.enterText(find.byKey(const ValueKey('f:loop.max')), '{{');
    await tester.pump();
    expect(find.byKey(const ValueKey('var-opt-prev')), findsOneWidget);
  });

  testWidgets('变量值输入 {{ 也列出变量', (tester) async {
    await _pumpSuggest(
      tester,
      const FlowFieldSpec(
        path: 'set.vars',
        shape: FlowFieldShape.mapOf,
        group: 'vars',
        labelZh: '变量',
        labelEn: 'Vars',
      ),
      {'goal': ''},
    );
    await tester.enterText(find.byKey(const ValueKey('f:set.vars-v0')), '{{');
    await tester.pump();
    expect(find.byKey(const ValueKey('var-opt-prev')), findsOneWidget);
  });
}

Future<void> _pumpSuggest(
  WidgetTester tester,
  FlowFieldSpec spec,
  Object? current,
) {
  const roots = [
    FlowVarNode(
      segment: 'prev',
      hint: '上一轮',
      children: [FlowVarNode(segment: 'review', hint: 'task')],
    ),
  ];
  return tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: FlowFieldEditor(
        spec: spec,
        current: current,
        varRoots: roots,
        onChanged: (_) {},
      ),
    ),
  ));
}
