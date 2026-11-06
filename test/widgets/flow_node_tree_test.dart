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

  testWidgets('P4: session entry appears only for nodes with session_id',
      (tester) async {
    await tester.pumpWidget(_treeApp(const [
      FlowNode(
        key: 'has',
        id: 'has',
        kind: 'task',
        status: FlowNodeStatus.done,
        sessionId: 'flow_deadbe12_has',
        agentId: 'agent-7',
      ),
      FlowNode(
        key: 'none',
        id: 'none',
        kind: 'task',
        status: FlowNodeStatus.done,
        session: 'flow:r1:none',
      ),
    ]));
    expect(find.byKey(const ValueKey('flow-node-session-has')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-session-none')), findsNothing);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-session-streaming')),
        findsNothing);
  });

  testWidgets('P4: tapping the session entry fires onOpenSession',
      (tester) async {
    FlowNode? opened;
    await tester.pumpWidget(_treeApp(
      const [
        FlowNode(
          key: 'impl',
          id: 'impl',
          kind: 'task',
          status: FlowNodeStatus.done,
          sessionId: 'flow_deadbe12_impl',
          agentId: 'agent-7',
        ),
      ],
      onOpenSession: (node) => opened = node,
    ));
    await tester.tap(find.byKey(const ValueKey('flow-node-session-impl')));
    await tester.pump();
    expect(opened?.sessionId, 'flow_deadbe12_impl');
    expect(opened?.agentId, 'agent-7');
  });

  testWidgets('P4: running node shows the streaming indicator', (tester) async {
    await tester.pumpWidget(_treeApp(const [
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.running,
        sessionId: 'flow_deadbe12_impl',
      ),
    ]));
    expect(find.byKey(const ValueKey('flow-node-session-streaming')),
        findsOneWidget);
  });

  testWidgets('P4: onOpenSession reaches nested seq and par children',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_treeApp(
      const [
        FlowNode(
          key: 'seq',
          id: 'seq',
          kind: 'seq',
          children: [
            FlowNode(
              key: 'seq/inner',
              id: 'inner',
              kind: 'task',
              sessionId: 'flow_deadbe12_inner',
            ),
          ],
        ),
        FlowNode(
          key: 'par',
          id: 'par',
          kind: 'par',
          children: [
            FlowNode(
              key: 'par/a',
              id: 'a',
              kind: 'task',
              sessionId: 'flow_deadbe12_a',
            ),
          ],
        ),
      ],
      onOpenSession: (node) => opened.add(node.key),
    ));
    await tester.tap(find.byKey(const ValueKey('flow-node-session-seq/inner')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('flow-node-session-par/a')));
    await tester.pump();
    expect(opened, ['seq/inner', 'par/a']);
  });
}

Widget _treeApp(List<FlowNode> nodes, {void Function(FlowNode)? onOpenSession}) =>
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: FlowNodeTree(nodes: nodes, onOpenSession: onOpenSession),
        ),
      ),
    );
