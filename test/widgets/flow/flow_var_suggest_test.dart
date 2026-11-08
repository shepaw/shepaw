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
}
