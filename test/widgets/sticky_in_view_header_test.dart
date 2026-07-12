import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shepaw/widgets/chat/sticky_in_view_header.dart';

void main() {
  testWidgets('StickyInViewHeader pins header within item bounds while scrolling',
      (tester) async {
    final controller = ScrollController();
    final viewportKey = GlobalKey();
    const headerText = 'Author';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeyedSubtree(
            key: viewportKey,
            child: ListView(
              controller: controller,
              children: [
                const SizedBox(height: 400),
                StickyInViewHeader(
                  viewportKey: viewportKey,
                  header: const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.person, size: 24),
                        SizedBox(width: 8),
                        Text(headerText),
                      ],
                    ),
                  ),
                  child: Container(
                    height: 800,
                    color: Colors.grey.shade200,
                    alignment: Alignment.topLeft,
                    child: const Text('BODY'),
                  ),
                ),
                const SizedBox(height: 800),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.jumpTo(450);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final headerDy = tester.getTopLeft(find.text(headerText)).dy;
    expect(headerDy, greaterThanOrEqualTo(-1));
    expect(headerDy, lessThan(40));
    expect(find.byIcon(Icons.person), findsOneWidget);

    controller.jumpTo(1400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text(headerText), findsNothing);
  });

  testWidgets(
      'overlay mode shows avatar+name when tall reverse item is clipped',
      (tester) async {
    final positions = ItemPositionsListener.create();
    final viewportKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeyedSubtree(
            key: viewportKey,
            child: ScrollablePositionedList.builder(
              reverse: true,
              itemPositionsListener: positions,
              itemCount: 1,
              itemBuilder: (context, index) {
                return StickyInViewHeader(
                  showHeaderInFlow: false,
                  viewportKey: viewportKey,
                  scrollListenables: [positions.itemPositions],
                  header: const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.smart_toy, size: 24),
                        SizedBox(width: 8),
                        Text('Agent Bot'),
                      ],
                    ),
                  ),
                  child: Container(
                    height: 900,
                    color: Colors.grey.shade200,
                    child: const Text('LONG BODY'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Agent Bot'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    final headerDy = tester.getTopLeft(find.text('Agent Bot')).dy;
    expect(headerDy, greaterThanOrEqualTo(-1));
    expect(headerDy, lessThan(40));
  });
}
