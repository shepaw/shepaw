import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/action_confirmation_buttons.dart';
import 'package:shepaw/widgets/interaction_closed_hint.dart';

/// 主机不再等这张卡时（`agent_interaction_closed`），按钮必须全部收起可点态。
///
/// 留着可点的下场是：用户点下去 → submitApproval 抛
/// PeerApprovalExpiredException → 弹一句「审批已失效」。这件事本来是可以预知
/// 的，就该在卡上直接说清楚。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> actionData({
    String? selectedActionId,
    String? closed,
  }) =>
      {
        'confirmation_id': 'appr-1',
        'prompt': '允许执行 rm -rf build？',
        'actions': [
          {'id': 'allow', 'label': '允许', 'style': 'primary'},
          {'id': 'deny', 'label': '拒绝', 'style': 'danger'},
        ],
        if (selectedActionId != null) 'selected_action_id': selectedActionId,
        if (closed != null) 'closed': closed,
      };

  Future<void> pumpCard(
    WidgetTester tester,
    Map<String, dynamic> data, {
    void Function(String, String, String)? onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ActionConfirmationButtons(
            actionData: data,
            onActionSelected:
                onSelected ?? (_, __, ___) => fail('作废的卡片不该还能点'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未作废时按钮可点', (tester) async {
    await pumpCard(tester, actionData());
    expect(find.byType(InteractionClosedHint), findsNothing);

    final allow = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '允许'),
    );
    expect(allow.onPressed, isNotNull);
  });

  testWidgets('作废后两个按钮都点不动，并说明原因', (tester) async {
    await pumpCard(tester, actionData(closed: 'timeout'));

    expect(find.text('已作废：没等到回答，主机已按默认继续'), findsOneWidget);

    // 全部落到 disabled 分支（OutlinedButton + onPressed == null）。
    expect(find.byType(ElevatedButton), findsNothing);
    for (final button in tester.widgetList<OutlinedButton>(
      find.byType(OutlinedButton),
    )) {
      expect(button.onPressed, isNull);
    }
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    await tester.tap(find.text('允许'), warnIfMissed: false);
    await tester.pump();
  });

  testWidgets('作废原因不同，说法不同', (tester) async {
    await pumpCard(tester, actionData(closed: 'cancelled'));
    expect(find.text('已作废：回合已停止'), findsOneWidget);

    await pumpCard(tester, actionData(closed: 'turn_ended'));
    expect(find.text('已作废：回合已结束，这张卡片不再有效'), findsOneWidget);
  });

  testWidgets('已作答的卡片不受作废影响', (tester) async {
    await pumpCard(tester, actionData(selectedActionId: 'allow'));

    expect(find.byType(InteractionClosedHint), findsNothing);
    // 用户的裁决留着：勾还在「允许」上。
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('作答与作废都到了，按作答渲染', (tester) async {
    // 自己那一下点击，主机也会广播一条 `interaction.resolved` 回来。两条
    // 落地的先后不定，谁的先到都不能让用户的裁决看起来像「没答」。
    await pumpCard(tester, actionData(selectedActionId: 'allow', closed: 'answered_elsewhere'));

    expect(find.byType(InteractionClosedHint), findsNothing);
    expect(find.text('已作废：这个问题已在别处作答'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('expired 哨兵加上作废原因，仍说明原因而不是当成已选', (tester) async {
    // 直连审批卡落库时会同时写 selected_action_id=expired 和 closed。
    // 前者是给对账用的，不能把提示吃掉。
    await pumpCard(
      tester,
      actionData(selectedActionId: 'expired', closed: 'timeout'),
    );

    expect(find.text('已作废：没等到回答，主机已按默认继续'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    for (final button in tester.widgetList<OutlinedButton>(
      find.byType(OutlinedButton),
    )) {
      expect(button.onPressed, isNull);
    }
  });

  testWidgets('在别处作答的卡片收起可点态', (tester) async {
    await pumpCard(tester, actionData(closed: 'answered_elsewhere'));

    expect(find.text('已作废：这个问题已在别处作答'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
  });
}
