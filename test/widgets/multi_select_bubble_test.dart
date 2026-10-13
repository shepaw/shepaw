import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/interaction_closed_hint.dart';
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
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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

  Map<String, dynamic> data({
    List<String>? selectedOptionIds,
    String? closed,
  }) =>
      {
        'confirmation_id': 'ix-1',
        'prompt': 'Pick some',
        'options': [
          {'label': 'Alpha', 'value': 'alpha'},
          {'label': 'Beta', 'value': 'beta'},
        ],
        if (selectedOptionIds != null) 'selected_option_ids': selectedOptionIds,
        if (closed != null) 'closed': closed,
      };

  // 主机不再等这张卡时（超时 / 回合被停止 / 回合已结束），卡片要收起可点态
  // 并说明原因。留着能点的话，用户勾完按提交只会撞上「已失效」。
  testWidgets('作废后勾不动、也没有提交按钮，并说明原因', (tester) async {
    await pumpBubble(
      tester,
      data(closed: 'timeout'),
      onSelectSubmitted: (_, __, ___) => fail('作废的卡片不该还能提交'),
    );

    expect(find.text('已作废：没等到回答，主机已按默认继续'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);

    await tester.tap(find.text('Beta'), warnIfMissed: false);
    await tester.pumpAndSettle();
    // 本地那次未提交的勾选不能看着像选了 —— 它没送出去。
    expect(find.byIcon(Icons.check_box), findsNothing);
  });

  testWidgets('作答与作废都到了，按作答渲染', (tester) async {
    // 自己那一下点击，主机也会广播一条 `interaction.resolved` 回来。两条落地
    // 的先后不定，谁的先到都不能让用户的裁决看起来像「没答」。
    await pumpBubble(tester, data(selectedOptionIds: ['beta'], closed: 'answered_elsewhere'));

    expect(find.byType(InteractionClosedHint), findsNothing);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('未作废时照常能勾能提交', (tester) async {
    await pumpBubble(tester, data());
    expect(find.byType(InteractionClosedHint), findsNothing);
    expect(find.byType(ElevatedButton), findsOneWidget);
  });
}
