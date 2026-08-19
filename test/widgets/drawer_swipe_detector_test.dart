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

    test('rejects vertical-dominant scrolls so list can win', () {
      expect(
        decideDrawerSwipe(dx: 10, dy: 30, touchSlop: 18),
        DrawerSwipeDecision.rejectAsVertical,
      );
      expect(
        decideDrawerSwipe(dx: 20, dy: 20, touchSlop: 18),
        DrawerSwipeDecision.rejectAsVertical,
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
      double touchSlop = kTouchSlop,
      double minOpenDistance = 36,
      double horizontalDominance = 1.25,
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
              onOpenGestureStart: (dx) => events.add(('start', dx)),
              onOpenGestureUpdate: (dx) => events.add(('update', dx)),
              onOpenGestureEnd: (velocity, dx) => events.add(('end', dx)),
              // 注意：子组件必须可命中（纯 SizedBox 的 hitTestSelf 为 false，
              // 指针事件不会沿路径送达识别器）。
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

      final gesture = await tester.startGesture(const Offset(300, 200));
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

  group('气泡共存（聊天页阈值 8/8/1.5，SelectionArea 在 |dx|>18 接受竞技场）', () {
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
      expect(events, isEmpty);
    });
  });
}
