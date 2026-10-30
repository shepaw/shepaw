import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_node_tree.dart';

void main() {
  testWidgets('a running gate shows its options and reports the choice',
      (tester) async {
    String? picked;
    const gate = FlowNode(
      key: 'seq/ok',
      id: 'ok',
      kind: 'gate',
      status: FlowNodeStatus.running,
      options: ['通过', '返工'],
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: FlowNodeTree(
            nodes: const [
              FlowNode(
                key: 'seq',
                id: 'seq',
                kind: 'seq',
                children: [
                  FlowNode(
                      key: 'seq/impl',
                      id: 'impl',
                      kind: 'task',
                      status: FlowNodeStatus.done),
                  gate,
                ],
              ),
            ],
            onAnswerGate: (node, choice) => picked = '${node.key}:$choice',
          ),
        ),
      ),
    ));
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('通过'), findsOneWidget);
    await tester.tap(find.text('返工'));
    expect(picked, 'seq/ok:返工');
  });

  testWidgets('a finished gate no longer offers its options', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FlowNodeTree(nodes: [
          FlowNode(
            key: 'ok',
            id: 'ok',
            kind: 'gate',
            status: FlowNodeStatus.done,
            options: ['通过'],
          ),
        ]),
      ),
    ));
    expect(find.text('通过'), findsNothing);
  });

  test('loop and par titles say what they are in plain words', () async {
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    const loop = FlowNode(key: 'l', id: 'l', kind: 'loop', rounds: 2);
    const par = FlowNode(key: 'p', id: 'p', kind: 'par', children: [
      FlowNode(key: 'p/a', id: 'a', kind: 'task'),
      FlowNode(key: 'p/b', id: 'b', kind: 'task'),
    ]);
    expect(flowKindTitle(zh, loop), '循环 · 第 2 轮');
    expect(flowKindTitle(zh, par), '并行 · 2 项');
    expect(flowKindTitle(en, par), 'Parallel · 2');
    expect(flowStatusLabel(en, FlowNodeStatus.done), 'Done');
  });
}
