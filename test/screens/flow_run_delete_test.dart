import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';

const _tree = [
  {'key': 'impl', 'id': 'impl', 'kind': 'task', 'status': 'done'},
];

HubFlow _host(
  StreamController<PeerControlEvent> bus, {
  required String status,
  void Function(Map<String, dynamic> frame)? onFrame,
}) =>
    HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        onFrame?.call(frame);
        Map<String, dynamic>? reply;
        switch (frame['type']) {
          case 'flow_run_get_req':
            reply = {
              'type': 'flow_run_get_resp',
              'success': true,
              'run_id': 'r1',
              'status': status,
              'tasks_used': 1,
              'tree': _tree,
            };
          case 'flow_run_delete_req':
            reply = {
              'type': 'flow_run_delete_resp',
              'success': true,
              'run_id': 'r1',
              'hidden_sessions': 2,
            };
        }
        if (reply != null) {
          bus.add(PeerControlEvent(
              peerId: peerId,
              data: {...reply, 'request_id': frame['request_id']}));
        }
        return true;
      },
    );

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('a finished run can be deleted and the screen closes',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    var deleted = false;
    await tester.pumpWidget(_app(FlowRunScreen(
      peerId: 'p1',
      runId: 'r1',
      client: _host(bus, status: 'succeeded', onFrame: sent.add),
      onDeleted: () => deleted = true,
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('run-delete')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-delete')));
    await tester.pumpAndSettle();
    // 先确认，再真的删。
    await tester.tap(find.text('删除运行'));
    await _settle(tester);

    expect(sent.any((f) => f['type'] == 'flow_run_delete_req'), isTrue);
    expect(deleted, isTrue);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('a running run has no delete button', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(FlowRunScreen(
      peerId: 'p1',
      runId: 'r1',
      client: _host(bus, status: 'running'),
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('run-delete')), findsNothing);
    // 在跑的是取消。
    expect(find.byTooltip('取消运行'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  test('the delete frame carries the run id', () {
    expect(HubFlow.deleteRunFrame('r1', requestId: 'x'),
        {'type': 'flow_run_delete_req', 'request_id': 'x', 'run_id': 'r1'});
  });
}
