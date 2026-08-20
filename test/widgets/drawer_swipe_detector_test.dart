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
  Future<List<(String, double)>> runGesture(
      WidgetTester tester,
      List<Offset> moves, {
      Widget? child,
      Offset startOffset = const Offset(300, 200),
      double touchSlop = kTouchSlop,
      double minOpenDistance = 36,
      double horizontalDominance = 1.25,
      double verticalDominance = 2.0,
      bool blockTrailingEdgeDrawerGesture = false,
      double? trailingEdgeBlockWidth,
    }) async {
      final events = <(String, double)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrawerSwipeDetector(
              direction: DrawerSwipeDirection.rightToLeft,
              touchSlop: touchSlop,
              minOpenDistance: minOpenDistance,
              horizontalDominance: horizontalDominance,
              verticalDominance: verticalDominance,
              blockTrailingEdgeDrawerGesture: blockTrailingEdgeDrawerGesture,
              trailingEdgeBlockWidth: trailingEdgeBlockWidth,
              onOpenGestureStart: (dx) => events.add(('start', dx)),
              onOpenGestureUpdate: (dx) => events.add(('update', dx)),
              onOpenGestureEnd: (velocity, dx) => events.add(('end', dx)),
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

  group('气泡共存（聊天页阈值 8/8/1.0/2.0，SelectionArea 在 |dx|>18 接受竞技场）', () {
    /// 模拟文本气泡：内容被 SelectionArea 包裹（message_bubble.dart 的做法），
    /// 其 TapAndDrag 识别器在 touchSlop(18px) 接受竞技场。
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

    testWidgets('气泡上左滑（SelectionArea 包裹）→ 抽屉手势胜出', (tester) async {
      final events = await runGesture(
        tester,
        const [
          Offset(-6, 0), // 累计 -6：未过 touchSlop 8，wait
          Offset(-10, 0), // 累计 -16：8px 阈值接受，且仍在 SelectionArea 的 18px 之前
          Offset(-60, 0), // 累计 -76：accept 后继续上报
        ],
        touchSlop: 8,
        minOpenDistance: 8,
        horizontalDominance: 1.5,
        child: selectionBubble(),
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '识别瞬间只回调一次 start',
      );
      expect(events.first.$2, closeTo(16, 1),
          reason: 'start 携带识别瞬间累计位移（16px，先于选区的 18px）');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(76, 1));
    });

    testWidgets('单帧大位移（极快滑动）→ 竞技场归 SelectionArea（已知边界）',
        (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-40, 0)], // 单帧跳过 8px 阈值直达 40px
        touchSlop: 8,
        minOpenDistance: 8,
        horizontalDominance: 1.5,
        child: selectionBubble(),
      );
      expect(events, isEmpty,
          reason: 'SelectionArea 路径更内层、先处理事件：|dx|>18 抢先接受，'
              '单帧位移 ≥10px 的极快滑动仍会被它抢走（框架竞技场限制，'
              '60Hz 下约 660px/s 以上的甩动才会触发）');
    });

    testWidgets('默认 36px 阈值在气泡上无法胜出（回归锚点）', (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-40, 0), Offset(-40, 0)],
        child: selectionBubble(),
      );
      expect(events, isEmpty,
          reason: 'SelectionArea 在 18px 接受，36px 阈值的抽屉永远等不到机会');
    });

    testWidgets('横向 SingleChildScrollView 上左滑 → 让位且滚动生效', (tester) async {
      final events = await runGesture(
        tester,
        const [Offset(-10, 0), Offset(-60, 0)],
        touchSlop: 8,
        minOpenDistance: 8,
        horizontalDominance: 1.5,
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
        minOpenDistance: 8,
        horizontalDominance: 1.5,
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
        minOpenDistance: 8,
        horizontalDominance: 1.5,
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

    testWidgets('带垂直分量的斜滑（39°，dy/dx=0.8）在气泡上 → 抽屉胜出（移动端复现）',
        (tester) async {
      // 真实手指/模拟器拖动几乎不可能完全水平。旧配置 horizontalDominance
      // 1.5（33.7° 锥）+「dy ≥ dx 即拒」会让 dy/dx=0.8 的手势永远等不到接受：
      // Android 上 SelectionArea 在 |dx|>18 抢先、iOS 上列表在 36px 抢先，
      // 抽屉基本滑不出来（用户实测）。horizontalDominance 降到 1.0（45° 锥）
      // 后，该角度在 8px 位移即接受，仍先于 SelectionArea 的 18px。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -4), // 累计 (-5,-4)：未过 touchSlop 8，wait
          Offset(-5, -4), // 累计 (-10,-8)：distance 12.8 ≥ 8，10 ≥ 8*1.0 → accept
          Offset(-5, -4),
          Offset(-5, -4),
          Offset(-5, -4),
          Offset(-5, -4), // 累计 (-30,-24)：accept 后继续上报
        ],
        touchSlop: 8,
        minOpenDistance: 8,
        horizontalDominance: 1.0,
        verticalDominance: 2.0,
        child: selectionBubble(),
      );

      expect(
        events.where((e) => e.$1 == 'start').length,
        1,
        reason: '识别瞬间只回调一次 start',
      );
      expect(events.first.$2, closeTo(10, 1),
          reason: 'start 携带识别瞬间累计位移（10px，先于选区的 18px）');
      expect(events.last.$1, 'end');
      expect(events.last.$2, closeTo(30, 1));
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
          Offset(-10, 0), // 累计 -16 → accept
          Offset(-60, 0),
        ],
        touchSlop: 8,
        minOpenDistance: 8,
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
      // dy/dx=1.6（58°）：drawer 判定永远 wait（openDx < dy×1.0），列表的
      // VerticalDrag 在 36px（18 hitSlop + 18 dragStartDistanceMotionThreshold）
      // 接管竞技场 → 滚动生效、抽屉不触发。真实垂直滚动通常 dy >> dx，不受影响。
      final events = await runGesture(
        tester,
        const [
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
          Offset(-5, -8),
        ],
        touchSlop: 8,
        minOpenDistance: 8,
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
          Offset(-60, 0),
        ],
        touchSlop: 8,
        minOpenDistance: 8,
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
          Offset(-60, 0),
        ],
        touchSlop: 8,
        minOpenDistance: 8,
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
