import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/progress_step.dart';
import 'package:shepaw/widgets/progress_steps_view.dart';

const _steps = [
  ProgressStep(
    id: 'th-1',
    type: ProgressStepType.thought,
    title: 'Thinking',
    status: ProgressStepStatus.completed,
    body: '先看一下目录',
  ),
  ProgressStep(
    id: 't1',
    type: ProgressStepType.tool,
    title: 'Bash',
    toolKind: 'execute',
    summary: 'pnpm test',
    status: ProgressStepStatus.completed,
  ),
  ProgressStep(
    id: 't2',
    type: ProgressStepType.tool,
    title: 'Read',
    toolKind: 'read',
    status: ProgressStepStatus.failed,
  ),
];

Widget _host({
  required List<ProgressStep> steps,
  required bool streaming,
  bool hasAnswer = false,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ProgressStepsView(
        steps: steps,
        isStreaming: streaming,
        hasAnswer: hasAnswer,
        autoCollapse: true,
        isMyMessage: false,
        bodyBuilder: (context, body, streaming) => Text(body),
      ),
    ),
  );
}

void main() {
  testWidgets('finished turn shows a one-line summary, collapsed',
      (tester) async {
    await tester.pumpWidget(_host(steps: _steps, streaming: false));
    await tester.pumpAndSettle();
    expect(find.text('Thought · 2 tool calls · 1 failed'), findsOneWidget);
    expect(find.textContaining('pnpm test'), findsNothing);
  });

  testWidgets(
      'tapping the header lists steps; tapping a thought shows its body',
      (tester) async {
    await tester.pumpWidget(_host(steps: _steps, streaming: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thought · 2 tool calls · 1 failed'));
    await tester.pump();
    expect(find.textContaining('pnpm test'), findsOneWidget);
    expect(find.text('先看一下目录'), findsNothing);

    await tester.tap(find.text('Thinking'));
    await tester.pump();
    expect(find.text('先看一下目录'), findsOneWidget);
  });

  testWidgets(
      'streaming shows the running step in the header and auto-collapses '
      'once the answer starts', (tester) async {
    const running = [
      ProgressStep(
        id: 't1',
        type: ProgressStepType.tool,
        title: 'Bash',
        summary: 'pnpm test',
        status: ProgressStepStatus.running,
      ),
    ];
    await tester.pumpWidget(_host(steps: running, streaming: true));
    await tester.pump();
    // 流式且还没有正文：默认展开，头部和步骤行里都能看到当前动作。
    expect(find.text('Bash: pnpm test'), findsOneWidget);
    expect(find.textContaining('pnpm test'), findsNWidgets(2));

    await tester.pumpWidget(_host(
      steps: const [
        ProgressStep(
          id: 't1',
          type: ProgressStepType.tool,
          title: 'Bash',
          summary: 'pnpm test',
          status: ProgressStepStatus.completed,
        ),
      ],
      streaming: false,
      hasAnswer: true,
    ));
    await tester.pump();
    expect(find.text('1 tool calls'), findsOneWidget);
    expect(find.textContaining('pnpm test'), findsNothing);
  });
}
