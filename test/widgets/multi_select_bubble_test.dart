import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/widgets/multi_select_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBubble(
    WidgetTester tester,
    Map<String, dynamic> selectData, {
    void Function(String selectId, List<String> optionIds, String summary)?
        onSelectSubmitted,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiSelectBubble(
            selectData: selectData,
            onSelectSubmitted: onSelectSubmitted,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping one option toggles only that option', (tester) async {
    await pumpBubble(tester, {
      'select_id': 'features',
      'prompt': 'Pick some',
      'options': [
        {'id': 'a', 'label': 'Alpha'},
        {'id': 'b', 'label': 'Beta'},
      ],
    });

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
  });

  // Same Hub `value`-keyed payload as single_select: options must stay
  // independently toggleable instead of collapsing onto one empty id.
  testWidgets('hub payload keyed by value toggles only that option',
      (tester) async {
    List<String>? submittedIds;
    await pumpBubble(
      tester,
      {
        'confirmation_id': 'ix-1',
        'prompt': 'Pick some',
        'options': [
          {'label': 'Alpha', 'value': 'alpha'},
          {'label': 'Beta', 'value': 'beta'},
        ],
      },
      onSelectSubmitted: (selectId, optionIds, summary) {
        submittedIds = optionIds;
      },
    );

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(submittedIds, ['beta']);
  });
}
