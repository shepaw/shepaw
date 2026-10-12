import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
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
}
