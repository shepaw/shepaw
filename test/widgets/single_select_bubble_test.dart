import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/interaction_closed_hint.dart';
import 'package:shepaw/widgets/message_bubble.dart';
import 'package:shepaw/widgets/single_select_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBubble(
    WidgetTester tester,
    Map<String, dynamic> selectData, {
    void Function(String selectId, String optionId, String optionLabel)?
        onSelectSubmitted,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleSelectBubble(
            selectData: selectData,
            onSelectSubmitted: onSelectSubmitted,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping one option selects exactly one', (tester) async {
    await pumpBubble(tester, {
      'select_id': 'scope',
      'prompt': 'Pick one',
      'options': [
        {'id': 'a', 'label': 'Alpha'},
        {'id': 'b', 'label': 'Beta'},
        {'id': 'c', 'label': 'Gamma'},
      ],
    });

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));
  });

  // Hub `interaction.pending` payloads carry `value`, not `id`. Reading only
  // `id` gave every option the same empty identity, so one tap lit up the
  // whole list (and submitted an empty id).
  testWidgets('hub payload keyed by value selects exactly one', (tester) async {
    String? submittedId;
    String? submittedLabel;
    await pumpBubble(
      tester,
      {
        'confirmation_id': 'ix-1791767853798-7',
        'interaction_id': 'ix-1791767853798-7',
        'prompt': 'shepaw 仓库保留哪个 agent 在群里？',
        'options': [
          {'label': 'claude-code 版（aa99befe）', 'value': 'aa99befe'},
          {'label': 'cursor 版（f729b795）', 'value': 'f729b795'},
          {'label': '两个都踢，换个新的来负责 shepaw', 'value': 'replace'},
        ],
      },
      onSelectSubmitted: (selectId, optionId, optionLabel) {
        submittedId = optionId;
        submittedLabel = optionLabel;
      },
    );

    await tester.tap(find.text('cursor 版（f729b795）'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(submittedId, 'f729b795');
    expect(submittedLabel, 'cursor 版（f729b795）');
  });

  testWidgets('renders inside a message bubble from hub metadata',
      (tester) async {
    final message = Message(
      id: 'm1',
      content: 'shepaw 仓库保留哪个 agent 在群里？',
      timestampMs: 0,
      from: MessageFrom(id: 'she-builtin-agent-001', type: 'agent', name: '惜宝'),
      type: MessageType.text,
      metadata: {
        'hub_interaction': {
          'host_peer_id': 'host-1',
          'interaction_id': 'ix-1791767853798-7',
          'interaction_type': 'single_select',
        },
        'single_select': {
          'confirmation_id': 'ix-1791767853798-7',
          'interaction_id': 'ix-1791767853798-7',
          'prompt': 'shepaw 仓库保留哪个 agent 在群里？',
          'options': [
            {'label': 'claude-code 版（aa99befe）', 'value': 'aa99befe'},
            {'label': 'cursor 版（f729b795）', 'value': 'f729b795'},
          ],
        },
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MessageBubble(message: message, isMyMessage: false)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('cursor 版（f729b795）'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsOneWidget);
  });

  testWidgets('options without any identity still select exactly one',
      (tester) async {
    await pumpBubble(tester, {
      'select_id': 'scope',
      'prompt': 'Pick one',
      'options': [
        {'label': 'Alpha'},
        {'label': 'Beta'},
        {'label': 'Gamma'},
      ],
    });

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));
  });

  Map<String, dynamic> data({String? selectedOptionId, String? closed}) => {
        'confirmation_id': 'ix-1',
        'prompt': 'Pick one',
        'options': [
          {'label': 'Alpha', 'value': 'alpha'},
          {'label': 'Beta', 'value': 'beta'},
        ],
        if (selectedOptionId != null) 'selected_option_id': selectedOptionId,
        if (closed != null) 'closed': closed,
      };

  // 主机不再等这张卡时（超时 / 回合被停止 / 回合已结束），卡片要收起可点态
  // 并说明原因。留着能点的话，用户选完按确认只会撞上「已失效」。
  testWidgets('作废后选不动、也没有确认按钮，并说明原因', (tester) async {
    await pumpBubble(
      tester,
      data(closed: 'timeout'),
      onSelectSubmitted: (_, __, ___) => fail('作废的卡片不该还能提交'),
    );

    expect(find.text('已作废：没等到回答，主机已按默认继续'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);

    await tester.tap(find.text('Beta'), warnIfMissed: false);
    await tester.pumpAndSettle();
    // 本地那次未提交的点击不能看着像选了 —— 它没送出去。
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
  });

  testWidgets('作答与作废都到了，按作答渲染', (tester) async {
    // 自己那一下点击，主机也会广播一条 `interaction.resolved` 回来。两条落地
    // 的先后不定，谁的先到都不能让用户的裁决看起来像「没答」。
    await pumpBubble(tester, data(selectedOptionId: 'beta', closed: 'answered_elsewhere'));

    expect(find.byType(InteractionClosedHint), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('未作废时照常能选能确认', (tester) async {
    await pumpBubble(tester, data());
    expect(find.byType(InteractionClosedHint), findsNothing);
    expect(find.byType(ElevatedButton), findsOneWidget);
  });
}
