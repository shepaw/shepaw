import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/collapsible_message_bubble.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message longAnswer({Map<String, dynamic>? metadata}) => Message(
        id: 'm-long',
        content: '这是一段很长的回答。' * 400,
        timestampMs: 0,
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Agent'),
        type: MessageType.text,
        metadata: metadata,
      );

  Map<String, dynamic> thinkingMetadata() => {
        'progress_content': '先想一下',
        'collapsible_title': 'Thinking',
        'collapsible': true,
        'auto_collapse': true,
      };

  Future<void> pumpBubble(
    WidgetTester tester,
    Message message, {
    required bool isLatestMessage,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          // 展开的 4000 字回答比测试视口高；给纵向无界约束，避免
          // RenderFlex overflow 掩盖真正的断言。
          body: SingleChildScrollView(
            child: MessageBubble(
              message: message,
              isMyMessage: false,
              isLatestMessage: isLatestMessage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('历史里的长回答仍然折叠', (tester) async {
    await pumpBubble(tester, longAnswer(), isLatestMessage: false);

    expect(find.byType(CollapsibleMessageBubble), findsOneWidget);
  });

  testWidgets('最新一条长回答保持展开，回合结束不会突然消失', (tester) async {
    await pumpBubble(tester, longAnswer(), isLatestMessage: true);

    expect(find.byType(CollapsibleMessageBubble), findsNothing);
  });

  testWidgets('最新回答带 thinking 时只折叠 thinking，正文保持展开', (tester) async {
    await pumpBubble(
      tester,
      longAnswer(metadata: thinkingMetadata()),
      isLatestMessage: true,
    );

    expect(find.byType(CollapsibleMessageBubble), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
  });

  testWidgets('历史回答带 thinking 时 thinking 和正文都折叠', (tester) async {
    await pumpBubble(
      tester,
      longAnswer(metadata: thinkingMetadata()),
      isLatestMessage: false,
    );

    expect(find.byType(CollapsibleMessageBubble), findsNWidgets(2));
  });
}
