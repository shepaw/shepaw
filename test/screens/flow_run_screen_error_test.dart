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

/// 主机把 `Failed.error` 和 `Cancel.reason` 都写进 `flow_run_get_resp.error`。
HubFlow _host(
  StreamController<PeerControlEvent> bus, {
  required String status,
  String? error,
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
              'status': status,
              'tasks_used': 1,
              'tree': _tree,
              if (error != null) 'error': error,
            },
          ));
        }
        return true;
      },
    );

Widget _app(HubFlow client) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        client: client,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('失败运行显示主机给的原因', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      status: 'failed',
      error: '工作流日志写入失败：磁盘满了',
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
    expect(find.text('工作流日志写入失败：磁盘满了'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('取消运行也显示取消原因，且不用失败的错误色', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(
      bus,
      status: 'cancelled',
      error: '运行超过 86400000 毫秒没有任何事件，已按卡住收敛',
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
    expect(find.text('运行超过 86400000 毫秒没有任何事件，已按卡住收敛'), findsOneWidget);
    // 用户主动停止 / 看门狗收敛不该渲染成红色失败卡：图标用 info，
    // 底色用中性 surface，不是 errorContainer。
    final card =
        tester.widget<Container>(find.byKey(const ValueKey('run-error-card')));
    final decoration = card.decoration! as BoxDecoration;
    final theme = Theme.of(tester.element(find.byType(FlowRunScreen)));
    expect(decoration.color, theme.colorScheme.surfaceContainerHighest);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('成功运行没有原因时不渲染错误卡', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus, status: 'succeeded')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
