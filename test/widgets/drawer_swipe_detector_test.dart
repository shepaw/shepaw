import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/drawer_swipe_detector.dart';

void main() {
  group('decideDrawerSwipe', () {
    test('waits below touch slop', () {
      expect(
        decideDrawerSwipe(dx: 8, dy: 2, touchSlop: kTouchSlop),
        DrawerSwipeDecision.wait,
      );
    });

    test('rejects clearly vertical-dominant scrolls so list can win', () {
      expect(
        decideDrawerSwipe(dx: 10, dy: 30, touchSlop: 18),
        DrawerSwipeDecision.rejectAsVertical,
      );
      // dy > 2×dx（约 63° 以上）才算「明显垂直」。
      expect(
        decideDrawerSwipe(dx: 20, dy: 41, touchSlop: 18),
        DrawerSwipeDecision.rejectAsVertical,
      );
    });

    test('45° diagonal waits instead of instantly dying (real swipes carry '
        'vertical drift)', () {
      // dy == dx（45°）：不再立即拒绝，保持 wait 让列表 36px 阈值自然接管。
      expect(
        decideDrawerSwipe(dx: 20, dy: 20, touchSlop: 18),
        DrawerSwipeDecision.wait,
      );
      // 45°~63° 斜向滑动同样 wait。
      expect(
        decideDrawerSwipe(dx: 30, dy: 40, touchSlop: 18),
        DrawerSwipeDecision.wait,
      );
    });

    test('rejects leftward horizontal swipes', () {
      expect(
        decideDrawerSwipe(dx: -40, dy: 4, touchSlop: 18),
        DrawerSwipeDecision.rejectAsHorizontal,
      );
    });

    test('accepts clear rightward open swipes from middle area', () {
      expect(
        decideDrawerSwipe(
          dx: 40,
          dy: 8,
          touchSlop: 18,
          horizontalDominance: 1.25,
          minOpenDistance: 36,
        ),
        DrawerSwipeDecision.acceptOpen,
      );
    });

    test('waits when rightward but still short of open distance', () {
      expect(
        decideDrawerSwipe(
          dx: 24,
          dy: 4,
          touchSlop: 18,
          horizontalDominance: 1.25,
          minOpenDistance: 36,
        ),
        DrawerSwipeDecision.wait,
      );
    });

    test('waits when horizontal bias is not yet clear', () {
      expect(
        decideDrawerSwipe(
          dx: 30,
          dy: 28,
          touchSlop: 18,
          horizontalDominance: 1.25,
          minOpenDistance: 36,
        ),
        DrawerSwipeDecision.wait,
      );
    });
  });

  group('decideDrawerSwipe rightToLeft (chat right drawer)', () {
    test('accepts clear leftward open swipes', () {
      expect(
        decideDrawerSwipe(
          dx: -40,
          dy: 8,
          touchSlop: 18,
          direction: DrawerSwipeDirection.rightToLeft,
        ),
        DrawerSwipeDecision.acceptOpen,
      );
    });

    test('rejects rightward swipes in rightToLeft mode', () {
      expect(
        decideDrawerSwipe(
          dx: 40,
          dy: 4,
          touchSlop: 18,
          direction: DrawerSwipeDirection.rightToLeft,
        ),
        DrawerSwipeDecision.rejectAsHorizontal,
      );
    });

    test('waits when leftward but short of open distance', () {
      expect(
        decideDrawerSwipe(
          dx: -24,
          dy: 4,
          touchSlop: 18,
          horizontalDominance: 1.25,
          minOpenDistance: 36,
          direction: DrawerSwipeDirection.rightToLeft,
        ),
        DrawerSwipeDecision.wait,
      );
    });

    test('vertical-dominant scrolls still win in rightToLeft mode', () {
      expect(
        decideDrawerSwipe(
          dx: -10,
          dy: 30,
          touchSlop: 18,
          direction: DrawerSwipeDirection.rightToLeft,
        ),
        DrawerSwipeDecision.rejectAsVertical,
      );
    });
  });

  /// 记录识别后的事件：('start'|'update'|'end', openDx)。
  /// start 事件额外记录第三元组值：实际生效的打开阈值（文本上可能更低）。
  Future<List<(String, double, double?)>> runGesture(
      WidgetTester tester,
      List<Offset> moves, {
      Widget? child,
      Offset startOffset = const Offset(300, 200),
      double touchSlop = kTouchSlop,
      double minOpenDistance = 36,
      double? minOpenDistanceOnSelectableText,
      double horizontalDominance = 1.25,
      double verticalDominance = 2.0,
      bool blockTrailingEdgeDrawerGesture = false,
      double? trailingEdgeBlockWidth,
    }) async {
      final events = <(String, double, double?)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrawerSwipeDetector(
              direction: DrawerSwipeDirection.rightToLeft,
              touchSlop: touchSlop,
              minOpenDistance: minOpenDistance,
              minOpenDistanceOnSelectableText: minOpenDistanceOnSelectableText,
              horizontalDominance: horizontalDominance,
              verticalDominance: verticalDominance,
              blockTrailingEdgeDrawerGesture: blockTrailingEdgeDrawerGesture,
              trailingEdgeBlockWidth: trailingEdgeBlockWidth,
              onOpenGestureStart: (dx, threshold) =>
                  events.add(('start', dx, threshold)),
              onOpenGestureUpdate: (dx) => events.add(('update', dx, null)),
              onOpenGestureEnd: (velocity, dx) => events.add(('end', dx, null)),
              // 注意：识别器已用 HitTestBehavior.opaque 全区域参与竞技场，
              // 不再依赖子组件命中。
              child: child ??
                  Container(
                    width: 400,
                    height: 400,
                    color: Colors.white,
                  ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(startOffset);
      for (final move in moves) {
        await gesture.moveBy(move);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      return events;
    }

  group('gesture mode (跟手打开回调)', () {
    testWidgets('accept 后持续上报 update，抬手回调 end', (tester) async {
      final events = await runGesture(tester, const [
        Offset(-10, 0), // 累计 -10：未过 touchSlop，wait
        Offset(-60, 0), // 累计 -70：≥ minOpenDistance → accept
        Offset(-30, 0), // 累计 -100：accept 后继续上报
      ]);

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '识别瞬间只回调一次 start',
      );
      expect(events.first.$1, 'start');
      expect(events.first.$2, closeTo(70, 1), reason: 'start 携带识别瞬间累计位移');

      final updates = events.where((e) => e.$1 == 'update').toList();
      expect(updates, isNotEmpty);
      expect(updates.last.$2, closeTo(100, 1), reason: 'update 上报到最终位移');

      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(100, 1));
    });

    testWidgets('未达识别条件（垂直主导）时无任何回调', (tester) async {
      final events = await runGesture(tester, const [
        Offset(0, 40), // 垂直主导 → 拒绝，让位给列表滚动
        Offset(0, 20),
      ]);
      expect(events, isEmpty);
    });

    testWidgets('识别前抬手（短滑）无任何回调', (tester) async {
      final events = await runGesture(tester, const [
        Offset(-15, 0), // 未过 minOpenDistance
      ]);
      expect(events, isEmpty);
    });
  });

  group('聊天页配置（阈值 30/8/1.0/2.0，SelectionArea 在 |dx|>18 抢先）', () {
    /// 模拟文本气泡：内容被 SelectionArea 包裹（message_bubble.dart 的做法），
    /// 其 TapAndDrag 识别器在 |dx| > touchSlop(18px) 抢先接受竞技场。
    Widget selectionBubble() {
      return Container(
        width: 400,
        height: 400,
        color: Colors.white,
        child: SelectionArea(
          child: SizedBox(
            width: 400,
            height: 400,
            child: Center(
              child: Text(
                '气泡内容（可长按选择）',
                style: const TextStyle(fontSize: 24),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('气泡上左滑（未配置文本阈值）→ 让位给选区拖拽，保持旧行为',
        (tester) async {
      // 未配置 minOpenDistanceOnSelectableText 时，文本与普通区域同一阈值
      // 30px：SelectionArea 的横向拖拽识别器在 |dx|>18 抢先接受，抽屉手势
      // 等不到 30px —— 气泡上的左滑仍交给文字拖选（长按选择不受影响）。
      final events = await runGesture(
        tester,
        const [
          Offset(-6, 0), // 累计 -6：未过 touchSlop 8，wait
          Offset(-10, 0), // 累计 -16：仍低于 18px 与 30px，wait
          Offset(-60, 0), // 累计 -76：|dx|>18 时选区已抢先接受
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: selectionBubble(),
      );
      expect(events, isEmpty,
          reason: '未配置文本阈值时，SelectionArea 在 |dx|>18 接受，抽屉等不到 30px');
    });

    testWidgets('气泡上左滑（文本阈值 16 < 选区的 18）→ 抽屉打开', (tester) async {
      // down 命中 RenderParagraph（气泡文字，从 (400,300) 文字中心起手）→
      // 改用 16px 阈值，抢在选区的 |dx|>18 之前接受竞技场。累计 -16 即
      // accept，而选区此刻 |dx|=16<18 还未接受 —— 气泡上的左滑也能打开抽屉。
      final events = await runGesture(
        tester,
        const [
          Offset(-6, 0), // 累计 -6：未过 touchSlop 8，wait
          Offset(-10, 0), // 累计 -16：达文本阈值 16 → accept
        ],
        startOffset: const Offset(300, 200),
        touchSlop: 8,
        minOpenDistance: 30,
        minOpenDistanceOnSelectableText: 16,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: selectionBubble(),
      );

      expect(events.where((e) => e.$1 == 'start').length, 1,
          reason: '气泡上左滑超过 16px 应打开抽屉');
      expect(events.first.$2, closeTo(16, 1),
          reason: 'start 携带识别瞬间累计位移（16px）');
      expect(events.first.$3, 16,
          reason: 'start 上报实际生效的文本阈值 16（而非 30）');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(16, 1));
    });

    testWidgets('气泡上斜滑（dy>dx，>45°）→ 不触发抽屉，保持 wait 让位',
        (tester) async {
      // dy/dx=1.6（58°）在文本上：openDx < dy×1.0 永远 wait，drawer 不
      // 接受；选区的横向拖拽在 |dx|>18 后照常接管文字拖选 —— 只有横向主导
      // （<45°）的左滑才打开抽屉。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8), // 累计 (-30,-48)：纵向主导，wait / 拒绝
        ],
        startOffset: const Offset(300, 200),
        touchSlop: 8,
        minOpenDistance: 30,
        minOpenDistanceOnSelectableText: 16,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: selectionBubble(),
      );
      expect(events, isEmpty,
          reason: '文本上 dy>dx 的斜滑不应打开抽屉（纵向让位/选区接管）');
    });

    testWidgets('气泡上单帧大位移（极快滑动）→ 竞技场归 SelectionArea（已知边界）',
        (tester) async {
      // 单帧直接从 0 跳到 -40：SelectionArea 路径更内层、先处理事件，
      // |dx|=40>18 抢先接受，抽屉的 16px 阈值在此帧内没有机会 —— 极快
      // 滑动仍会被选区抢走（框架竞技场限制，与阈值配置无关）。
      final events = await runGesture(
        tester,
        const [Offset(-40, 0)],
        startOffset: const Offset(300, 200),
        touchSlop: 8,
        minOpenDistance: 30,
        minOpenDistanceOnSelectableText: 16,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: selectionBubble(),
      );
      expect(events, isEmpty,
          reason: '单帧大位移的极快滑动仍会被 SelectionArea 抢走');
    });

    testWidgets('非气泡区域左滑 30px → 抽屉打开并跟手', (tester) async {
      final events = await runGesture(
        tester,
        const [
          Offset(-10, 0), // 累计 -10：未达 30px，wait
          Offset(-10, 0), // 累计 -20：wait
          Offset(-10, 0), // 累计 -30：达到触发阈值 → accept
          Offset(-10, 0), // 累计 -40：accept 后继续上报
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '识别瞬间只回调一次 start',
      );
      expect(events.first.$2, closeTo(30, 1),
          reason: 'start 携带识别瞬间累计位移（30px，即触发阈值）');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(40, 1));
    });

    testWidgets('带垂直分量的斜滑（39°，dy/dx=0.8）非气泡区域 → 30px 后打开',
        (tester) async {
      // 真实手指/模拟器拖动几乎不可能完全水平：horizontalDominance 1.0
      //（45° 锥）+ verticalDominance 2.0 下，dy/dx=0.8 的手势在 30px 位移
      // 即接受（旧值 1.5（33.7° 锥）会把这类手势全部误杀）。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -4), // 累计 (-5,-4)：未过 touchSlop 8，wait
          Offset(-5, -4), // 累计 (-10,-8)：distance 12.8 ≥ 8，未达 30px，wait
          Offset(-5, -4),
          Offset(-5, -4),
          Offset(-5, -4),
          Offset(-5, -4), // 累计 (-30,-24)：30px ≥ 阈值 → accept
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '识别瞬间只回调一次 start',
      );
      expect(events.first.$2, closeTo(30, 1),
          reason: 'start 携带识别瞬间累计位移（30px）');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(30, 1));
    });

    testWidgets('滚动误触回归：左向漂移起手后转垂直 → 让位给列表，抽屉不触发',
        (tester) async {
      // 旧配置（阈值 8px）下，滚动起手时 dy/dx<1 的轻微左向漂移在 ~10px
      // 就接受打开手势，抽屉跟着滚动被误开。30px 阈值下，漂移段（累计
      // (-15,-12)）仍在 wait，随后纵向主导（dy > 2×dx）立即拒绝，列表在
      // dy ≥ 18px 接管滚动 —— 上下滑动完全不受影响。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -4),
          Offset(-5, -4),
          Offset(-5, -4), // 累计 (-15,-12)：左向主导但未达 30px，wait
          Offset(-2, -30), // 累计 (-17,-42)：dy 42 > 2×17 → 拒绝，列表接管
          Offset(0, -20), // 拒绝后指针归列表：滚动继续生效
          Offset(0, -20),
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: Container(
          width: 400,
          height: 400,
          color: Colors.white,
          child: ListView.builder(
            itemCount: 50,
            itemExtent: 80,
            itemBuilder: (_, index) => Container(color: Colors.blue),
          ),
        ),
      );

      expect(events, isEmpty, reason: '滚动漂移不应触发抽屉');
      final scrollable = tester
          .state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.pixels, greaterThan(0),
          reason: '列表确实滚动了');
    });

    testWidgets('跟手回滑：accept 后向左继续上报、向右回滑递减，抬手带最终位移',
        (tester) async {
      final events = await runGesture(
        tester,
        const [
          Offset(-10, 0), // 累计 -10：wait
          Offset(-10, 0), // 累计 -20：wait
          Offset(-10, 0), // 累计 -30 → accept
          Offset(-10, 0), // 累计 -40：继续左滑，update(40)
          Offset(4, 0), // 累计 -36
          Offset(4, 0), // 累计 -32
          Offset(4, 0), // 累计 -28：缩回 30px 阈值之下
          Offset(4, 0),
          Offset(4, 0),
          Offset(4, 0),
          Offset(4, 0),
          Offset(4, 0), // 累计 -8：继续回滑
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
      );

      expect(events.first.$1, 'start');
      expect(events.first.$2, closeTo(30, 1));
      final updates = events.where((e) => e.$1 == 'update').map((e) => e.$2).toList();
      expect(updates.first, closeTo(40, 1), reason: '回滑前上报最大位移');
      expect(updates.last, closeTo(8, 1), reason: '回滑后递减到最终位移');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(8, 1),
          reason: '抬手携带最终位移（已缩回阈值之下 → 收尾应关闭）');
    });

    testWidgets('横向 SingleChildScrollView 上左滑 → 让位且滚动生效', (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-10, 0), Offset(-60, 0)],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: Container(
          width: 400,
          height: 400,
          color: Colors.white,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(width: 800, height: 400, color: Colors.blue),
          ),
        ),
      );

      expect(events, isEmpty, reason: '横向滚动优先，抽屉手势让位');
      final scrollable = tester
          .state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.pixels, greaterThan(0),
          reason: '横向列表确实滚动了');
    });

    testWidgets('横向 ListView（输入区附件条样式）上左滑 → 让位', (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-10, 0), Offset(-60, 0)],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: Container(
          width: 400,
          height: 400,
          color: Colors.white,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 5,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) =>
                Container(width: 80, height: 400, color: Colors.teal),
          ),
        ),
      );
      expect(events, isEmpty);
    });

    testWidgets('输入框（TextField）上左滑 → 让位给文本编辑', (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-10, 0), Offset(-60, 0)],
        // 从输入框内起手（Center 内 300x48 的 TextField 位于 250..550, 276..324）。
        startOffset: const Offset(400, 300),
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: const Center(
          child: SizedBox(
            width: 300,
            height: 48,
            child: TextField(),
          ),
        ),
      );
      expect(events, isEmpty, reason: 'down 命中可编辑文本，识别器让位');
    });

    testWidgets('空聊天页（无消息、无滚动列表）空白区域左滑 → 抽屉手势仍生效',
        (tester) async {
      // 空状态内容不铺满全屏：Center 里只有一个窄 Column，周边大片区域没有
      // 可命中控件。RawGestureDetector 默认 deferToChild，指针落在空白处时
      // 识别器根本不加入竞技场 → 左滑无响应（用户实测「刚新建的空聊天页面
      // 无法左滑」）。测试从内容列上方的空白区（300,200）起手，opaque 后
      // 全区域可命中，识别器总是参与竞技场。
      final events = await runGesture(
        tester,
        const [
          Offset(-6, 0), // 累计 -6：未过 touchSlop 8，wait
          Offset(-10, 0), // 累计 -16：未达 30px，wait
          Offset(-60, 0), // 累计 -76 ≥ 30 → accept
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 80, height: 80), // 头像占位
              SizedBox(height: 16),
              Text('AI Agent'),
              SizedBox(height: 8),
              Text('Send a message to start chatting'),
            ],
          ),
        ),
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '空白区域左滑也能触发抽屉',
      );
    });

    testWidgets('45°~63° 斜滑在真实垂直列表上 → 让位给滚动', (tester) async {
      // dy/dx=1.6（58°）：drawer 判定永远 wait（openDx < dy×1.0），随后
      // dy > 2×dx 拒绝让位，列表在 dy ≥ 18px（verticalScrollSlop）接管
      // 竞技场 → 滚动生效、抽屉不触发。真实垂直滚动通常 dy >> dx，不受影响。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8), // 累计 (-30,-48)：dy > 2×30 → 拒绝，列表接管
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: Container(
          width: 400,
          height: 400,
          color: Colors.white,
          child: ListView.builder(
            itemCount: 50,
            itemExtent: 80,
            itemBuilder: (_, index) => Container(color: Colors.blue),
          ),
        ),
      );

      expect(events, isEmpty, reason: '斜滑让位给列表滚动，抽屉不触发');
      final scrollable = tester
          .state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.pixels, greaterThan(0),
          reason: '列表确实滚动了');
    });

    testWidgets('右边缘系统手势区内的左滑 → 让位给系统返回', (tester) async {
      // Android 手势返回 = 右边缘向左滑，与右抽屉打开手势同方向。
      // blockTrailingEdgeDrawerGesture 生效时，down 在 [宽-40, 宽) 区内
      // 的指针整体让出（不加入竞技场），系统返回不被抢。
      // 默认测试表面宽 800：区带为 [760, 800)。
      final events = await runGesture(
        tester,
        const [
          Offset(-10, 0),
          Offset(-60, 0), // 累计 -70：即使越过 30px 阈值，区带内也不触发
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        blockTrailingEdgeDrawerGesture: true,
        trailingEdgeBlockWidth: 40,
        startOffset: const Offset(780, 200),
        // 识别器边界随子组件尺寸：必须铺满全屏，区带测试才真正经过识别器
        // 的 addAllowedPointer（而非指针落在组件外根本没进竞技场）。
        child: const SizedBox.expand(),
      );

      expect(events, isEmpty, reason: '右边缘系统手势区内的左滑不应触发抽屉');
    });

    testWidgets('右边缘系统手势区外（40px 以内之外）左滑照常打开',
        (tester) async {
      // 区带外（<760）不受影响：从 750 起手，抽屉正常识别。
      final events = await runGesture(
        tester,
        const [
          Offset(-10, 0),
          Offset(-60, 0), // 累计 -70 ≥ 30 → accept
        ],
        touchSlop: 8,
        minOpenDistance: 30,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        blockTrailingEdgeDrawerGesture: true,
        trailingEdgeBlockWidth: 40,
        startOffset: const Offset(750, 200),
        // 铺满全屏：见区带测试的说明。
        child: const SizedBox.expand(),
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '区带外左滑正常打开抽屉',
      );
    });
  });
}
