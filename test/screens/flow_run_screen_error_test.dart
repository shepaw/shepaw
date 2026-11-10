import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/theme/app_theme.dart';

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

/// 用真实主题，否则 MaterialApp 默认主题的 `outline` 是深灰，掩盖了
/// 「把边框灰当正文色」这种对比度问题。
Widget _app(HubFlow client, {bool dark = false}) => MaterialApp(
      locale: const Locale('zh'),
      theme: dark ? AppTheme.dark : AppTheme.light,
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

/// 卡片里的正文 / 图标颜色必须是可读的前景，不能是 `outline`（分隔灰）。
void _expectReadableForeground(WidgetTester tester, Color expected) {
  final theme = Theme.of(tester.element(find.byType(FlowRunScreen)));
  final text = tester.widget<SelectableText>(find.descendant(
    of: find.byKey(const ValueKey('run-error-card')),
    matching: find.byType(SelectableText),
  ));
  expect(text.style?.color, expected);
  final icon = tester.widget<Icon>(find.descendant(
    of: find.byKey(const ValueKey('run-error-card')),
    matching: find.byType(Icon),
  ));
  expect(icon.color, expected);
  // 显式断言没退回 outline：亮色下 #E3E5E8 当正文色几乎不可见。
  expect(expected, isNot(theme.colorScheme.outline));
}

void main() {
  for (final dark in [false, true]) {
    final label = dark ? '暗色' : '亮色';

    testWidgets('$label · 失败运行显示原因，用错误色', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      await tester.pumpWidget(_app(
        _host(bus, status: 'failed', error: '工作流日志写入失败：磁盘满了'),
        dark: dark,
      ));
      await _settle(tester);

      expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
      expect(find.text('工作流日志写入失败：磁盘满了'), findsOneWidget);
      final theme = Theme.of(tester.element(find.byType(FlowRunScreen)));
      final card = tester
          .widget<Container>(find.byKey(const ValueKey('run-error-card')));
      expect((card.decoration! as BoxDecoration).color,
          theme.colorScheme.errorContainer);
      _expectReadableForeground(tester, theme.colorScheme.error);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });

    testWidgets('$label · 取消运行显示原因，用中性可读色', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      await tester.pumpWidget(_app(
        _host(bus, status: 'cancelled', error: '运行超过 86400000 毫秒没有任何事件'),
        dark: dark,
      ));
      await _settle(tester);

      expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
      expect(find.text('运行超过 86400000 毫秒没有任何事件'), findsOneWidget);
      // 用户主动停止 / 看门狗收敛不该渲染成红色失败卡。
      final theme = Theme.of(tester.element(find.byType(FlowRunScreen)));
      final card = tester
          .widget<Container>(find.byKey(const ValueKey('run-error-card')));
      expect((card.decoration! as BoxDecoration).color,
          theme.colorScheme.surfaceContainerHighest);
      _expectReadableForeground(tester, theme.colorScheme.onSurfaceVariant);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });
  }

  // 主机在非终态也会写 `run.error`（on_error: continue 的失败分支、
  // 宽限期、预算告警），这些状态不能挂一张「失败原因」卡。
  for (final status in ['running', 'succeeded']) {
    testWidgets('$status 运行即使带 error 也不渲染原因卡', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      await tester.pumpWidget(_app(_host(
        bus,
        status: status,
        error: '超出 max_tasks 上限',
      )));
      await _settle(tester);
      expect(find.byKey(const ValueKey('run-error-card')), findsNothing);
      expect(find.text('超出 max_tasks 上限'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });
  }

  testWidgets('成功运行没有原因时不渲染错误卡', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(_host(bus, status: 'succeeded')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
