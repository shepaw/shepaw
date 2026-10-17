import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/chat/session_unread_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Size> badgeSize(WidgetTester tester, int count) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 48,
              child: Row(
                children: [SessionUnreadBadge(count: count)],
              ),
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(SessionUnreadBadge));
  }

  testWidgets('一位数未读在更高的行里仍是圆形', (tester) async {
    final size = await badgeSize(tester, 3);
    expect(size, const Size(18, 18));
  });

  testWidgets('多位数未读只在水平方向变长', (tester) async {
    final size = await badgeSize(tester, 12);
    expect(size.height, 18);
    expect(size.width, greaterThan(18));
  });
}
