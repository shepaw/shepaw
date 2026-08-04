import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/collapsible_message_bubble.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBubble(WidgetTester tester, Message message) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageBubble(
            message: message,
            isMyMessage: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('progress collapsible stays visible with action_confirmation',
      (tester) async {
    const thinking = 'Let me think about this step by step…';
    const prompt = 'Allow running this command?';
    final message = Message(
      id: 'm1',
      content: prompt,
      timestampMs: 0,
      from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
      metadata: {
        'progress_content': thinking,
        'collapsible_title': 'Thinking',
        'action_confirmation': {
          'confirmation_id': 'cid-1',
          'prompt': prompt,
          'actions': [
            {'id': 'approve', 'label': 'Approve'},
            {'id': 'deny', 'label': 'Deny'},
          ],
        },
      },
    );

    await pumpBubble(tester, message);

    expect(find.byType(CollapsibleMessageBubble), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
  });

  testWidgets('progress collapsible stays visible after approval selection',
      (tester) async {
    const thinking = 'Analyzing repository structure…';
    final message = Message(
      id: 'm2',
      content: 'Done.',
      timestampMs: 0,
      from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
      metadata: {
        'progress_content': thinking,
        'collapsible_title': 'Thinking',
        'action_confirmation': {
          'confirmation_id': 'cid-2',
          'prompt': 'Continue?',
          'selected_action_id': 'approve',
          'actions': [
            {'id': 'approve', 'label': 'Approve'},
            {'id': 'deny', 'label': 'Deny'},
          ],
        },
      },
    );

    await pumpBubble(tester, message);

    expect(find.byType(CollapsibleMessageBubble), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
  });
}
