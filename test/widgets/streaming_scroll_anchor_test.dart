import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shepaw/widgets/chat/streaming_scroll_anchor.dart';

void main() {
  group('StreamingScrollAnchor.isAtBottom', () {
    test('returns true when positions are empty', () {
      final anchor = StreamingScrollAnchor();
      expect(anchor.isAtBottom(const []), isTrue);
    });

    test('returns true when index 0 bottom edge is at or above viewport bottom', () {
      final anchor = StreamingScrollAnchor();
      final positions = [
        const ItemPosition(
          index: 0,
          itemLeadingEdge: 0.02,
          itemTrailingEdge: 0.5,
        ),
        const ItemPosition(
          index: 1,
          itemLeadingEdge: 0.5,
          itemTrailingEdge: 0.8,
        ),
      ];
      expect(anchor.isAtBottom(positions), isTrue);
    });

    test(
      'returns false when user scrolled up inside a tall streaming bubble '
      '(index 0 still visible but bottom edge is below viewport)',
      () {
        final anchor = StreamingScrollAnchor();
        final positions = [
          const ItemPosition(
            index: 0,
            itemLeadingEdge: -0.35,
            itemTrailingEdge: 0.85,
          ),
          const ItemPosition(
            index: 1,
            itemLeadingEdge: 0.85,
            itemTrailingEdge: 1.2,
          ),
        ];
        expect(anchor.isAtBottom(positions), isFalse);
      },
    );

    test('returns false when index 0 is completely off screen', () {
      final anchor = StreamingScrollAnchor();
      final positions = [
        const ItemPosition(
          index: 3,
          itemLeadingEdge: -0.1,
          itemTrailingEdge: 0.4,
        ),
        const ItemPosition(
          index: 4,
          itemLeadingEdge: 0.4,
          itemTrailingEdge: 0.9,
        ),
      ];
      expect(anchor.isAtBottom(positions), isFalse);
    });
  });

  group('ChatStreamScrollPhysics + StreamingSizeTracker widget tests', () {
    testWidgets(
      'when at bottom (!isUserScrolledUp), streaming bubble growth keeps bottom edge pinned natively',
      (tester) async {
        final anchor = StreamingScrollAnchor();
        final positionsListener = ItemPositionsListener.create();
        final streamingHeight = ValueNotifier<double>(100);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: ScrollablePositionedList.builder(
                  reverse: true,
                  itemPositionsListener: positionsListener,
                  physics: ChatStreamScrollPhysics(anchor: anchor),
                  padding: const EdgeInsets.all(16),
                  itemCount: 10,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return StreamingSizeTracker(
                        key: const ValueKey('streaming_0'),
                        anchor: anchor,
                        child: ValueListenableBuilder<double>(
                          valueListenable: streamingHeight,
                          builder: (_, h, __) => SizedBox(
                            height: h,
                            width: double.infinity,
                            child: const ColoredBox(color: Colors.blue),
                          ),
                        ),
                      );
                    }
                    return SizedBox(
                      key: ValueKey('history_$index'),
                      height: 120,
                      width: double.infinity,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(anchor.isAtBottom(positionsListener.itemPositions.value), isTrue);

        // Grow the streaming bubble across multiple chunks without calling jumpTo.
        for (final h in <double>[180, 320, 520, 780]) {
          streamingHeight.value = h;
          await tester.pump();
          expect(
            anchor.isAtBottom(positionsListener.itemPositions.value),
            isTrue,
            reason: 'Bottom edge should remain pinned at h=$h',
          );
        }
      },
    );

    testWidgets(
      'when user scrolled up (isUserScrolledUp), streaming bubble growth does not shift visible history items',
      (tester) async {
        final anchor = StreamingScrollAnchor();
        final positionsListener = ItemPositionsListener.create();
        final streamingHeight = ValueNotifier<double>(120);
        final historyKey2 = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: ScrollablePositionedList.builder(
                  reverse: true,
                  itemPositionsListener: positionsListener,
                  physics: ChatStreamScrollPhysics(anchor: anchor),
                  padding: const EdgeInsets.all(16),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return StreamingSizeTracker(
                        key: const ValueKey('streaming_0'),
                        anchor: anchor,
                        child: ValueListenableBuilder<double>(
                          valueListenable: streamingHeight,
                          builder: (_, h, __) => SizedBox(
                            height: h,
                            width: double.infinity,
                            child: const ColoredBox(color: Colors.blue),
                          ),
                        ),
                      );
                    }
                    return SizedBox(
                      key: index == 2 ? historyKey2 : ValueKey('history_$index'),
                      height: 120,
                      width: double.infinity,
                      child: Text('Message $index'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // User drags down (scrolling up into history in a reverse list).
        await tester.drag(
          find.byType(ScrollablePositionedList),
          const Offset(0, 250),
        );
        anchor.isUserScrolledUp = true;
        await tester.pumpAndSettle();

        expect(anchor.isAtBottom(positionsListener.itemPositions.value), isFalse);

        final boxBefore =
            historyKey2.currentContext!.findRenderObject() as RenderBox;
        final topBefore = boxBefore.localToGlobal(Offset.zero).dy;

        // Streaming bubble grows significantly at the bottom while user is reading history.
        for (final h in <double>[200, 340, 500, 760]) {
          streamingHeight.value = h;
          await tester.pump();

          final boxNow =
              historyKey2.currentContext!.findRenderObject() as RenderBox;
          final topNow = boxNow.localToGlobal(Offset.zero).dy;
          expect(
            topNow,
            closeTo(topBefore, 0.5),
            reason: 'History message 2 should stay stationary when streaming bubble grows to $h',
          );
        }
      },
    );

    testWidgets(
      'active user drag is not interrupted when streaming bubble grows mid-gesture',
      (tester) async {
        final anchor = StreamingScrollAnchor();
        final positionsListener = ItemPositionsListener.create();
        final streamingHeight = ValueNotifier<double>(300);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: ScrollablePositionedList.builder(
                  reverse: true,
                  itemPositionsListener: positionsListener,
                  physics: ChatStreamScrollPhysics(anchor: anchor),
                  padding: const EdgeInsets.all(16),
                  itemCount: 15,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return StreamingSizeTracker(
                        key: const ValueKey('streaming_0'),
                        anchor: anchor,
                        child: ValueListenableBuilder<double>(
                          valueListenable: streamingHeight,
                          builder: (_, h, __) => SizedBox(
                            height: h,
                            width: double.infinity,
                          ),
                        ),
                      );
                    }
                    return SizedBox(
                      key: ValueKey('history_$index'),
                      height: 120,
                      width: double.infinity,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Start a user drag gesture (finger held down on screen).
        final gesture = await tester.startGesture(const Offset(200, 300));
        await gesture.moveBy(const Offset(0, 120));
        anchor.isUserScrolledUp = true;
        await tester.pump();

        expect(anchor.isAtBottom(positionsListener.itemPositions.value), isFalse);

        // Streaming chunk grows index 0 while user's finger is still down.
        streamingHeight.value = 460;
        await tester.pump();

        // Continue dragging with the same gesture — must still work and move further up.
        await gesture.moveBy(const Offset(0, 180));
        await tester.pump();

        final pos0 = positionsListener.itemPositions.value
            .where((p) => p.index == 0)
            .firstOrNull;
        // Bottom edge of index 0 should be well below the viewport (< -0.3).
        if (pos0 != null) {
          expect(pos0.itemLeadingEdge, lessThan(-0.3));
        }

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  });
}
