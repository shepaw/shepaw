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

  group('cursorModelFilledLayout', () {
    test('宽屏不改成贴边铺满', () {
      expect(cursorModelFilledLayout(screenWidth: 1200), isNull);
      expect(cursorModelFilledLayout(screenWidth: 480), isNull);
    });

    test('手机上一级贴左、二级贴右，两级铺满内容区', () {
      final layout = cursorModelFilledLayout(screenWidth: 390)!;
      expect(layout.panelLeft, 8);
      expect(layout.panelWidth, closeTo(162.8, 0.1));
      expect(layout.sideWidth, closeTo(207.2, 0.1));
      expect(layout.panelLeft + layout.panelWidth + 4 + layout.sideWidth, 382);
      expect(layout.sideLeft(390, 0), closeTo(174.8, 0.1));

      final narrow = cursorModelFilledLayout(screenWidth: 320)!;
      expect(narrow.panelLeft, 8);
      expect(
        narrow.panelLeft + narrow.panelWidth + 4 + narrow.sideWidth,
        312,
      );
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

  testWidgets('手机上展开二级时两级贴边铺满屏幕', (tester) async {
    const surface = Size(390, 800);
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final anchorKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(key: anchorKey, width: 120, height: 32),
          ),
        ),
      ),
    );

    final handle = showCursorModelPanel(
      context: tester.element(find.byType(Scaffold)),
      anchorKey: anchorKey,
      panel: (_, submenuOpen) => CursorModelSettings(
        submenuOpen: submenuOpen,
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
    );
    addTearDown(handle.close);
    await tester.pump();

    final closed = tester.getRect(find.byType(CursorModelSettings));
    expect(closed.width, closeTo(cursorModelPanelWidth(390), 0.5));
    expect(closed.left, greaterThan(8));

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    expect(find.text('Sonnet'), findsOneWidget);

    final layout = cursorModelFilledLayout(screenWidth: 390)!;
    final panel = tester.getRect(find.byType(CursorModelSettings));
    expect(panel.left, closeTo(layout.panelLeft, 0.5));
    expect(panel.width, closeTo(layout.panelWidth, 0.5));

    final menu = tester.getRect(
      find
          .ancestor(of: find.text('Sonnet'), matching: find.byType(InkWell))
          .first,
    );
    expect(menu.left, closeTo(panel.right + 4, 1));
    expect(menu.right, closeTo(390 - 8, 1));
    expect(_sideMenuWidth(tester, 'Sonnet'), closeTo(layout.sideWidth, 1));
  });

  testWidgets('submenu stays above conversation list and session list', (tester) async {
    // 桌面：左侧对话列表，右栏是带 ClipRect 的嵌套 Navigator。会话列表先插在
    // 根 Overlay 上，盖住二级菜单要伸进去的那一块。菜单后弹出，应该盖住两者。
    const surface = Size(1200, 800);
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final anchorKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(
              width: 700,
              child: ColoredBox(
                color: Color(0xFF101010),
                child: Center(child: Text('对话列表')),
              ),
            ),
            Expanded(
              child: ClipRect(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => Align(
                      alignment: Alignment.bottomLeft,
                      child: SizedBox(key: anchorKey, width: 80, height: 32),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final sessionEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        width: 540,
        bottom: 0,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _noop,
          child: const ColoredBox(
            color: Color(0xFF202020),
            child: Align(
              alignment: Alignment.topLeft,
              child: Text('会话列表'),
            ),
          ),
        ),
      ),
    );
    Overlay.of(
      tester.element(find.byKey(anchorKey)),
      rootOverlay: true,
    ).insert(sessionEntry);
    addTearDown(sessionEntry.remove);
    await tester.pump();

    final handle = showCursorModelPanel(
      context: tester.element(find.byKey(anchorKey)),
      anchorKey: anchorKey,
      panel: (_, submenuOpen) => CursorModelSettings(
        submenuOpen: submenuOpen,
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
    );
    addTearDown(handle.close);
    await tester.pump();

    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('Sonnet'));
    expect(menu.center.dx, lessThan(540));
    expect(find.text('Sonnet').hitTestable(), findsOneWidget);
    expect(find.text('会话列表'), findsOneWidget);
    expect(find.text('对话列表'), findsOneWidget);
  });
}

void _noop() {}
