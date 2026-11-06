import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_outline.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/widgets/flow/flow_outline_tree.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  final tree = [
    FlowNode(key: 'a', id: 'a', kind: 'task'),
    FlowNode(key: 'b', id: 'b', kind: 'task'),
  ];

  testWidgets('flashId 让那一行高亮，且每行都能拿到 GlobalKey 供滚动定位', (tester) async {
    final rows = buildFlowOutline(tree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    await tester.pumpWidget(_app(FlowOutlineTree(
      rows: rows,
      canEdit: false,
      rowKeys: keys,
      flashId: 'b',
    )));
    await tester.pump();

    for (final entry in keys.entries) {
      expect(entry.value.currentContext, isNotNull, reason: entry.key);
    }
    final containers = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(containers.length, 2);
    final scheme =
        Theme.of(tester.element(find.byType(FlowOutlineTree))).colorScheme;
    final flashing = containers.last.decoration! as BoxDecoration;
    expect(flashing.border!.top.color, scheme.primary);
    expect(flashing.border!.top.width, 2);
  });

  testWidgets('desktop 可编辑态才有拖拽手柄，手机只读没有', (tester) async {
    final rows = buildFlowOutline(tree);
    await _pumpTree(
      tester,
      FlowOutlineTree(
        rows: rows,
        canEdit: true,
        dragEnabled: true,
        tree: tree,
        onDrop: (_, __) {},
      ),
    );
    expect(find.byKey(const ValueKey('drag-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('drag-b')), findsOneWidget);

    await _pumpTree(
      tester,
      FlowOutlineTree(
          rows: rows, canEdit: false, dragEnabled: false, tree: tree),
    );
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });

  testWidgets('拖手柄到目标行的上 / 中 / 下区 → 发出正确的 move 落点', (tester) async {
    final rows = buildFlowOutline([
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(key: 'b', id: 'b', kind: 'seq'),
      FlowNode(key: 'c', id: 'c', kind: 'task'),
    ]);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    final drops = <(String, FlowDropTarget)>[];

    Future<void> pumpTree() => _pumpTree(
          tester,
          FlowOutlineTree(
            rows: rows,
            canEdit: true,
            dragEnabled: true,
            canMove: true,
            tree: [
              FlowNode(key: 'a', id: 'a', kind: 'task'),
              FlowNode(key: 'b', id: 'b', kind: 'seq'),
              FlowNode(key: 'c', id: 'c', kind: 'task'),
            ],
            rowKeys: keys,
            onDrop: (id, target) => drops.add((id, target)),
          ),
        );

    // 上 25% = before，中 50% = into（b 是 seq 容器），下 25% = after。
    for (final zone in <(String, double)>[
      ('before', 0.1),
      ('into', 0.5),
      ('after', 0.9),
    ]) {
      await pumpTree();
      await _dragTo(tester, keys, 'a', 'b', zone.$2);
      expect(drops, isNotEmpty, reason: '${zone.$1} 没发出落点');
      final (id, target) = drops.last;
      expect(id, 'a');
      if (zone.$1 == 'into') {
        expect(target.parentId, 'b');
        expect(target.index, isNull);
      } else {
        expect(target.parentId, '');
        // b 在根层 index 1；a 原本 index 0，同父下移各减 1：
        // before → 0（贴着 b 前，no-op），after → 1（挪到 b 后）。
        expect(target.index, zone.$1 == 'before' ? 0 : 1);
      }
      drops.clear();
    }
  });

  testWidgets('A2-3: 会断引用的落点 Tooltip 在 IgnorePointer 外层，能被触发', (tester) async {
    final dragTree = [
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(
        key: 'b',
        id: 'b',
        kind: 'task',
        fields: const {
          'task': {'prompt': '{{ a.text }}'},
        },
      ),
      FlowNode(
        key: 'box',
        id: 'box',
        kind: 'seq',
        children: [FlowNode(key: 'inner', id: 'inner', kind: 'task')],
      ),
    ];
    final rows = buildFlowOutline(dragTree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    await _pumpTree(
      tester,
      FlowOutlineTree(
        rows: rows,
        canEdit: true,
        dragEnabled: true,
        tree: dragTree,
        rowKeys: keys,
        onDrop: (_, __) {},
      ),
    );

    // 把 a 拖进 box：b 的 {{ a.text }} 会从「引用在前面」变成前向引用。
    final start = tester.getCenter(find.byKey(const ValueKey('drag-a')));
    final rect = tester.getRect(find.byKey(keys['box']!));
    final end =
        Offset(rect.left + rect.width * 0.5, rect.top + rect.height * 0.5);
    // 用鼠标拖：Tooltip 的 hover 触发依赖 MouseRegion 的命中测试。旧实现把
    // Tooltip 放在 IgnorePointer 里，MouseRegion 收不到 hover，提示永远不出现。
    final gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 8; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / 8)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump();
    // hover 触发后 Tooltip 走 overlay 显示。
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('{{ a.text }}'),
      ),
      findsOneWidget,
      reason: '预警 Tooltip 应该出现在落点高亮上',
    );
    expect(
      find.textContaining('{{ a.text }}'),
      findsOneWidget,
      reason: 'Tooltip 应能被 hover 触发并显示提示文本',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('A9 同一落点连续 move 不重复跑全树预检', (tester) async {
    final dragTree = [
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(key: 'b', id: 'b', kind: 'seq'),
    ];
    final rows = buildFlowOutline(dragTree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    await _pumpTree(
      tester,
      FlowOutlineTree(
        rows: rows,
        canEdit: true,
        dragEnabled: true,
        tree: dragTree,
        rowKeys: keys,
        onDrop: (_, __) {},
      ),
    );
    FlowOutlineTree.debugHoverWarningsComputed = 0;

    final start = tester.getCenter(find.byKey(const ValueKey('drag-a')));
    final rect = tester.getRect(find.byKey(keys['b']!));
    final end = Offset(
      rect.left + rect.width * 0.5,
      rect.top + rect.height * 0.9, // 下 25% = after 区
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 16));
    final afterEnter = FlowOutlineTree.debugHoverWarningsComputed;
    expect(afterEnter, greaterThan(0), reason: '进入新落点时应算一次');

    // 同一行、同一个区里的下一次 move：overId / zone / branch 都没变。
    await gesture.moveTo(end + const Offset(2, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      FlowOutlineTree.debugHoverWarningsComputed,
      afterEnter,
      reason: '落点没变时不该重跑 target / 全树预检',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('A4-2: 从手柄中心抓取，拖到行下四分之一拿到 after 而不是 into', (tester) async {
    final dragTree = [
      FlowNode(key: 'a', id: 'a', kind: 'task'),
      FlowNode(key: 'b', id: 'b', kind: 'seq'),
    ];
    final rows = buildFlowOutline(dragTree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    final drops = <(String, FlowDropTarget)>[];
    await _pumpTree(
      tester,
      FlowOutlineTree(
        rows: rows,
        canEdit: true,
        dragEnabled: true,
        tree: dragTree,
        rowKeys: keys,
        onDrop: (id, target) => drops.add((id, target)),
      ),
    );

    // 0.85 高：指针确实在下 1/4；若仍用 childDragAnchorStrategy，反馈原点
    // 会向上偏一个抓取偏移，落点会算成 into。
    await _dragTo(tester, keys, 'a', 'b', 0.85);
    expect(drops, hasLength(1));
    final (id, target) = drops.single;
    expect(id, 'a');
    expect(target.parentId, '', reason: '应落在 b 之后，而不是 b 内部');
    expect(target.index, 1);
  });

  testWidgets('A4-6: 拖拽中切到 busy（dragEnabled=false）会停掉自动滚动计时器', (tester) async {
    final rows = buildFlowOutline(tree);
    final keys = <String, GlobalKey>{
      for (final r in rows) r.node.id: GlobalKey(),
    };
    Widget buildTree(bool dragEnabled) => _app(FlowOutlineTree(
          rows: rows,
          canEdit: dragEnabled,
          dragEnabled: dragEnabled,
          tree: tree,
          rowKeys: keys,
          onDrop: (_, __) {},
        ));

    await tester.pumpWidget(buildTree(true));
    await tester.pump();

    final start = tester.getCenter(find.byKey(const ValueKey('drag-a')));
    final gesture = await tester.startGesture(start);
    // 移动超过 touch slop，真正进入拖拽态（_startDrag 被回调）。
    await gesture.moveTo(start + const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));

    FlowOutlineTree.debugAutoScrollTicks = 0;
    await tester.pump(const Duration(milliseconds: 32));
    expect(FlowOutlineTree.debugAutoScrollTicks, greaterThan(0),
        reason: '拖拽已开始，计时器应在跑（否则下面的断言没有意义）');

    FlowOutlineTree.debugAutoScrollTicks = 0;
    // 切到 busy：Draggable 被卸载，onDragEnd 不会回调。
    await tester.pumpWidget(buildTree(false));
    await tester.pump();
    final afterSwitch = FlowOutlineTree.debugAutoScrollTicks;
    await tester.pump(const Duration(milliseconds: 160));
    expect(FlowOutlineTree.debugAutoScrollTicks, afterSwitch,
        reason: 'didUpdateWidget 必须在 dragEnabled 变 false 时取消计时器');

    await gesture.up();
    await tester.pumpAndSettle();
  });
}

/// 宽一点的窗口，免得可编辑行的五个 IconButton 挤溢出。
Future<void> _pumpTree(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(child));
  await tester.pump();
}

/// 从 [from] 行的手柄拖到 [to] 行高的 [zone] 处，分多步移动让 DragTarget.onMove
/// 能收到，最后松手触发 onAcceptWithDetails。
Future<void> _dragTo(
  WidgetTester tester,
  Map<String, GlobalKey> keys,
  String from,
  String to,
  double zone,
) async {
  final start = tester.getCenter(find.byKey(ValueKey('drag-$from')));
  final rect = tester.getRect(find.byKey(keys[to]!));
  final end = Offset(
    rect.left + rect.width * 0.5,
    rect.top + rect.height * zone,
  );
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 1; i <= 8; i++) {
    await gesture.moveTo(Offset.lerp(start, end, i / 8)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}
