import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lightweight smoke test — does not boot [MyApp] (needs AppBootstrap / plugins).
void main() {
  testWidgets('MaterialApp smoke renders a title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('ShePaw')),
        ),
      ),
    );

    expect(find.text('ShePaw'), findsOneWidget);
  });
}
