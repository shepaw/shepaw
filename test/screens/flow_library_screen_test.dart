import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_library_screen.dart';

void main() {
  testWidgets('lists the library and starts a run with the flow name',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
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
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowLibraryScreen(peerId: 'p1', client: client),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('dev'), findsOneWidget);
    expect(find.text('第 3 版'), findsOneWidget);
    await tester.tap(find.text('运行'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    final start = sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['name'], 'dev');
    // 主机拒绝时把原因告诉用户，不跳走。
    expect(find.text('缺少输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
