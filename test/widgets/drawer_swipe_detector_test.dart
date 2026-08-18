import 'package:flutter/gestures.dart';
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
}
