import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_node_tree.dart';

/// P6：等用户回答的节点要露出「去回答」入口 + 红点 + 「等你回答」状态；
/// 关卡按钮和 P4 的会话入口不能被抢。
Widget _app(List<FlowNode> nodes, {void Function(FlowNode)? onOpenSession}) =>
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

void main() {
  testWidgets('P6: waiting_user 节点显示去回答按钮 / 等你回答 / 红点',
      (tester) async {
    await tester.pumpWidget(_app(const [
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.waitingUser,
        sessionId: 'flow_deadbe12_impl',
        agentId: 'agent-7',
      ),
    ]));

    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsOneWidget);
    expect(find.text('去回答'), findsOneWidget);
    expect(find.text('等你回答'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-session-waiting')),
        findsOneWidget);
    // P4 的会话入口仍在。
    expect(find.byKey(const ValueKey('flow-node-session-impl')), findsOneWidget);
  });

  testWidgets('P6: 点去回答触发 onOpenSession', (tester) async {
    FlowNode? opened;
    await tester.pumpWidget(_app(
      const [
        FlowNode(
          key: 'impl',
          id: 'impl',
          kind: 'task',
          status: FlowNodeStatus.waitingUser,
          sessionId: 'flow_deadbe12_impl',
        ),
      ],
      onOpenSession: (node) => opened = node,
    ));

    await tester
        .tap(find.byKey(const ValueKey('flow-node-goto-answer-impl')));
    await tester.pump();
    expect(opened?.sessionId, 'flow_deadbe12_impl');
  });

  testWidgets('P6: 没有节点会话时不出去回答按钮', (tester) async {
    await tester.pumpWidget(_app(const [
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.waitingUser,
      ),
    ]));
    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsNothing);
    expect(find.text('等你回答'), findsOneWidget);
  });

  testWidgets('P6: 已完成的节点没有去回答 / 红点（回归）', (tester) async {
    await tester.pumpWidget(_app(const [
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.done,
        sessionId: 'flow_deadbe12_impl',
      ),
    ]));
    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsNothing);
    expect(find.byKey(const ValueKey('flow-node-session-waiting')),
        findsNothing);
  });

  testWidgets('P6: halted 节点也按等人回答露出入口（防御）', (tester) async {
    await tester.pumpWidget(_app(const [
      FlowNode(
        key: 'impl',
        id: 'impl',
        kind: 'task',
        status: FlowNodeStatus.halted,
        sessionId: 'flow_deadbe12_impl',
      ),
    ]));
    expect(find.byKey(const ValueKey('flow-node-goto-answer-impl')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-session-waiting')),
        findsOneWidget);
  });

  testWidgets('P6: 运行中的 gate 仍显示选项按钮（回归）', (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FlowNodeTree(
          nodes: const [
            FlowNode(
              key: 'ok',
              id: 'ok',
              kind: 'gate',
              status: FlowNodeStatus.running,
              options: ['通过', '返工'],
            ),
          ],
          onAnswerGate: (node, choice) => picked = choice,
        ),
      ),
    ));
    expect(find.text('通过'), findsOneWidget);
    await tester.tap(find.text('返工'));
    expect(picked, '返工');
  });
}
