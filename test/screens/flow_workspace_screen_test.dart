import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_workspace_screen.dart';

void main() {
  testWidgets('lists the library and starts a run with the flow name',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('第 3 版'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
    await _settle(tester);
    final start = harness.sent
        .firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['name'], 'dev');
    // 主机拒绝时把原因告诉用户，不跳走。
    expect(find.text('缺少输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a retry state when the host does not answer',
      (tester) async {
    final harness = _Harness(reachable: false);
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    expect(find.text('主机没有回应'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a flow opens its design view in the detail pane',
      (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 右栏出现设计视图（标题带流程名）。
    expect(find.text('设计：dev'), findsOneWidget);
    // 进详情要先把定义取回来。
    expect(harness.sent.any((f) => f['type'] == 'flow_get_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}

/// 假主机：按帧类型回一份固定应答，并把请求记下来。
class _Harness {
  _Harness({this.reachable = true});

  final bool reachable;
  final StreamController<PeerControlEvent> bus =
      StreamController<PeerControlEvent>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  HubFlow get client => HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          sent.add(frame);
          if (!reachable) return false;
          final reply = switch (frame['type']) {
            'flow_list_req' => {
                'type': 'flow_list_resp',
                'success': true,
                'flows': [
                  {'name': 'dev', 'latest': 3},
                ],
              },
            'flow_run_start_req' => {
                'type': 'flow_run_start_resp',
                'success': false,
                'error': '缺少输入',
              },
            'flow_get_req' => {
                'type': 'flow_get_resp',
                'success': true,
                'revision': 3,
                'yaml': 'flow: dev\nsteps: []\n',
              },
            'flow_schema_req' => {
                'type': 'flow_schema_resp',
                'success': true,
                'common': [],
                'kinds': {},
              },
            'flow_validate_req' => {
                'type': 'flow_validate_resp',
                'success': true,
                'yaml': 'flow: dev\nsteps: []\n',
                'tree': [],
                'diagnostics': [],
              },
            _ => null,
          };
          if (reply != null) {
            bus.add(PeerControlEvent(
                peerId: peerId,
                data: {...reply, 'request_id': frame['request_id']}));
          }
          return true;
        },
      );

  Future<void> close() async {
    await bus.close();
  }
}

Future<void> _pump(WidgetTester tester, HubFlow client) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: FlowWorkspaceScreen(peerId: 'p1', client: client),
  ));
  await _settle(tester);
}

/// 页面里有 spinner 和计时器，`pumpAndSettle` 不会收敛，用有界 pump。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}
