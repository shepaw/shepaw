import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';

const _tree = [
  {
    'key': 'impl',
    'id': 'impl',
    'kind': 'task',
    'status': 'done',
    'session': 'flow:r1:impl',
    'session_id': 'flow_deadbe12_impl',
    'agent_id': 'agent-7',
  },
];

HubFlow _host(
  StreamController<PeerControlEvent> bus, {
  List<dynamic>? tree,
}) =>
    HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_get_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'tasks_used': 1,
              'tree': tree ?? _tree,
            },
          ));
        }
        return true;
      },
    );

Widget _app(
  HubFlow client, {
  void Function(FlowNode node)? onOpenSession,
}) =>
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        client: client,
        onOpenSession: onOpenSession,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  final opened = <({String channelId, String? agentId})>[];

  setUp(() {
    opened.clear();
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
  });

  tearDown(() => debugOpenFlowSessionChannel = null);

  testWidgets('P4: card session entry opens psess_<session_id> by default',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-session-impl')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-node-session-impl')));
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    expect(opened.single.agentId, 'agent-7');
    // 卡片本身的点开详情不该被会话按钮连带触发。
    expect(find.byKey(const ValueKey('node-view-session')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P4: flow.node.changed session_id adds the entry without a refetch',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(
      _host(
        bus,
        tree: const [
          {
            'key': 'impl',
            'id': 'impl',
            'kind': 'task',
            'status': 'pending',
          },
        ],
      ),
    ));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-node-session-impl')), findsNothing);

    bus.add(PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'flow.node.changed',
        'run_id': 'r1',
        'node': 'impl',
        'status': 'running',
        'attempt': 1,
        'session_id': 'flow_deadbe12_impl',
        'agent_id': 'agent-7',
      },
    ));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byKey(const ValueKey('flow-node-session-impl')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P4: node sheet 查看会话 works without an onOpenSession caller',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus)));
    await _settle(tester);

    // 点卡片本身仍是打开节点详情弹层。
    await tester.tap(find.text('impl'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('node-view-session')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('node-view-session')));
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('P4: an explicit onOpenSession override still wins',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final overridden = <String>[];
    await tester.pumpWidget(_app(
      _host(bus),
      onOpenSession: (node) => overridden.add(node.sessionId!),
    ));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('flow-node-session-impl')));
    await _settle(tester);
    expect(overridden, ['flow_deadbe12_impl']);
    expect(opened, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
