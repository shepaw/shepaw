import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
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
Widget _app(
  HubFlow client, {
  bool dark = false,
  Stream<PeerConnectionEvent>? connectionEvents,
}) =>
    MaterialApp(
      locale: const Locale('zh'),
      theme: dark ? AppTheme.dark : AppTheme.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        client: client,
        connectionEvents: connectionEvents,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// WCAG 相对亮度 / 对比度。只比较「用了哪个色角色」测不出可读性：
/// 亮色主题的 `onSurfaceVariant` 被压成 grey500，仍需靠实际比值挡住。
double _luminance(Color c) {
  // Flutter 3.41 起 Color.r/g/b 已是 0..1 的 double，不要再除 255。
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
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
  final card =
      tester.widget<Container>(find.byKey(const ValueKey('run-error-card')));
  final surface = (card.decoration! as BoxDecoration).color!;
  expect(
    _contrast(expected, surface) >= 4.5,
    isTrue,
    reason: '正文对比度要达 WCAG AA：$expected / $surface = '
        '${_contrast(expected, surface).toStringAsFixed(2)}:1',
  );
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
      _expectReadableForeground(tester, theme.colorScheme.onSurface);
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

  testWidgets('取消事件到达时先清掉运行中的旧 error，不冒充取消原因', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    // 初始帧：运行中，但主机已写过预算告警到 run.error。
    await tester.pumpWidget(_app(_host(
      bus,
      status: 'running',
      error: '超出 max_tasks 上限',
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing);

    // 主机侧看门狗收敛，只推状态帧；400ms 内 App 还没重拉到真值。
    bus.add(PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'flow.run.changed',
        'run_id': 'r1',
        'status': 'cancelled',
      },
    ));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byKey(const ValueKey('run-status-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing,
        reason: '旧告警不能在取消瞬间冒充取消原因');
    expect(find.text('超出 max_tasks 上限'), findsNothing);
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

  testWidgets('终态后重拉失败不崩，旧告警也不会冒充取消原因', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    var requests = 0;
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_get_req') {
          requests += 1;
          if (requests == 1) {
            bus.add(PeerControlEvent(
              peerId: peerId,
              data: {
                'type': 'flow_run_get_resp',
                'request_id': frame['request_id'],
                'success': true,
                'run_id': 'r1',
                'status': 'running',
                'tasks_used': 1,
                'tree': _tree,
                'error': '超出 max_tasks 上限',
              },
            ));
            return true;
          }
          // 第二次（终态事件后的重拉）发送失败：`_client.run` 返回 null。
          return false;
        }
        return true;
      },
    );
    await tester.pumpWidget(_app(client));
    await _settle(tester);
    expect(find.byKey(const ValueKey('run-status-strip')), findsOneWidget);

    bus.add(PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'flow.run.changed',
        'run_id': 'r1',
        'status': 'cancelled',
      },
    ));
    await tester.pump(const Duration(milliseconds: 30));
    // 400ms 后触发重拉；`_loadOnce` 拿到 null，不能把旧 error 放回来，
    // 也不能崩 / 把整屏换成加载失败。
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('run-status-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing);
    expect(find.text('超出 max_tasks 上限'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('终态后重拉失败，重连会再拉一次把原因补回来', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final conn = StreamController<PeerConnectionEvent>.broadcast();
    const reason = '运行超过 86400000 毫秒没有任何事件';
    var requests = 0;
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] != 'flow_run_get_req') return true;
        requests += 1;
        if (requests == 2) {
          // 终态事件后的那次重拉连不上：`_client.run` 返回 null。
          return false;
        }
        bus.add(PeerControlEvent(
          peerId: peerId,
          data: {
            'type': 'flow_run_get_resp',
            'request_id': frame['request_id'],
            'success': true,
            'run_id': 'r1',
            'status': requests == 1 ? 'running' : 'cancelled',
            'tasks_used': 1,
            'tree': _tree,
            // 第一次是运行中的旧告警；第三次（重连后）才是真原因。
            'error': requests == 1 ? '超出 max_tasks 上限' : reason,
          },
        ));
        return true;
      },
    );
    await tester.pumpWidget(_app(client, connectionEvents: conn.stream));
    await _settle(tester);

    bus.add(PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'flow.run.changed',
        'run_id': 'r1',
        'status': 'cancelled',
      },
    ));
    await tester.pump(const Duration(milliseconds: 30));
    // 400ms 后的重拉失败，`_onEvent` 已经把旧 error 清掉了，屏幕上没有原因。
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(requests, 2);
    expect(find.byKey(const ValueKey('run-error-card')), findsNothing);

    // 废连接重连成功：`_loadFailed` 置位后这次才会重新拉，把真原因补回来。
    conn.add(PeerConnectionEvent(
      peerId: 'p1',
      type: PeerConnectionEventType.connected,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(requests, 3, reason: '重连要触发一次新的 flow_run_get_req');
    expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(find.text('超出 max_tasks 上限'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
    await conn.close();
  });
}
