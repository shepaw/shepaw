import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/widgets/chat/cursor_model_panel.dart';

PeerAgentModel _grok() {
  return PeerAgentModel(
    value: 'grok-4.7',
    displayName: 'Grok 4.7',
    options: const [
      PeerModelOption(
        id: 'fast',
        displayName: 'Fast',
        values: ['false', 'true'],
        defaultValue: 'true',
      ),
      PeerModelOption(
        id: 'context',
        displayName: 'Context',
        values: ['256k', '500k'],
        labels: ['256K', '500K'],
        defaultValue: '256k',
      ),
      PeerModelOption(
        id: 'reasoning_effort',
        displayName: 'Effort',
        values: ['low', 'high'],
        labels: ['Low', 'High'],
        defaultValue: 'high',
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Size surface,
}) async {
  // 用 view 尺寸，不用 setSurfaceSize：后者只改布局尺寸，MediaQuery 仍是默认的
  // 800x600，二级菜单按「屏幕宽度」算宽度时会和实际布局对不上。
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          // 和 showCursorModelPanel 用同一个宽度，测试才反映真机排布。
          child: SizedBox(
            width: cursorModelPanelWidth(surface.width),
            child: CursorModelSettings(
              models: [
                _grok(),
                PeerAgentModel(value: 'sonnet', displayName: 'Sonnet'),
              ],
              currentModel: 'grok-4.7',
              optionValues: const {},
              modelLabel: '模型',
              onFastChanged: (_) {},
              onOptionChanged: (_, __) {},
              onModelChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Rect _row(WidgetTester tester, String title) {
  return tester.getRect(
    find.ancestor(
      of: find.text(title),
      matching: find.byType(CompositedTransformTarget),
    ),
  );
}

/// 二级菜单的整块宽度。菜单行是撑满宽度的 [InkWell]，量它最省事。
double _sideMenuWidth(WidgetTester tester, String label) {
  return tester
      .getRect(
        find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first,
      )
      .width;
}

double _gap(Rect row, Rect menu) {
  if (menu.left >= row.right - 1) return menu.left - row.right;
  return row.left - menu.right;
}

void main() {
  group('cursorModelPanelWidth', () {
    test('宽屏沿用固定宽度，手机收窄到半屏以内', () {
      expect(cursorModelPanelWidth(1200), 216);
      expect(cursorModelPanelWidth(480), 216);
      expect(cursorModelPanelWidth(430), closeTo(197.8, 0.1));
      expect(cursorModelPanelWidth(390), closeTo(179.4, 0.1));
      // 再窄也不低于下限。
      expect(cursorModelPanelWidth(320), 176);
    });
  });

  testWidgets('submenu sits against the row and replaces the previous one', (tester) async {
    await _pump(tester, surface: const Size(1200, 800));

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(find.text('500K'), findsOneWidget);

    final contextGap = _gap(_row(tester, 'Context'), tester.getRect(find.text('500K')));
    expect(contextGap, inInclusiveRange(0, 48));

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    expect(find.text('500K'), findsNothing);
    expect(find.text('Sonnet'), findsOneWidget);

    final modelGap = _gap(_row(tester, '模型'), tester.getRect(find.text('Sonnet')));
    expect(modelGap, inInclusiveRange(0, 48));
  });

  testWidgets('narrow layout keeps the submenu next to the panel', (tester) async {
    await _pump(tester, surface: const Size(390, 800));

    await tester.tap(find.text('Effort'));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsOneWidget);

    final gap = _gap(_row(tester, 'Effort'), tester.getRect(find.text('Low')));
    expect(gap, inInclusiveRange(0, 48));

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsNothing);
    expect(find.text('500K'), findsOneWidget);
  });

  testWidgets('手机上两级菜单宽度均衡且都不出屏', (tester) async {
    await _pump(tester, surface: const Size(390, 800));

    final panel = tester.getRect(find.byType(CursorModelSettings));
    expect(panel.width, closeTo(cursorModelPanelWidth(390), 0.5));

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    expect(find.text('Sonnet'), findsOneWidget);

    final menuWidth = _sideMenuWidth(tester, 'Sonnet');
    // 二级菜单不再被挤成 120 上下，长模型名放得下。
    expect(menuWidth, greaterThanOrEqualTo(160));
    expect(menuWidth, lessThanOrEqualTo(240));
    // 一级 179 / 二级 ~203：都在屏内，且没有一边倒。
    expect((menuWidth - panel.width).abs(), lessThan(60));

    final menu = tester.getRect(
      find
          .ancestor(of: find.text('Sonnet'), matching: find.byType(InkWell))
          .first,
    );
    expect(menu.left, greaterThanOrEqualTo(0));
    expect(menu.right, lessThanOrEqualTo(390));
  });
}
