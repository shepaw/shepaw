import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 用户发出的原文按原始字符串展示，不走 Markdown 预览。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);
  const markdownSource = '# 标题\n\n这是 **加粗** 和 `code`\n\n- 列表项';

  Message textMessage({
    required String content,
    required bool isMy,
  }) {
    return Message(
      id: isMy ? 'user-1' : 'agent-1',
      content: content,
      timestampMs: 0,
      from: MessageFrom(
        id: isMy ? 'user' : 'agent',
        type: isMy ? 'user' : 'agent',
        name: isMy ? '我' : 'Agent',
      ),
      type: MessageType.text,
    );
  }

  Future<void> pumpBubble(
    WidgetTester tester, {
    required Message message,
    required bool isMyMessage,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: surface.width,
            child: MessageBubble(message: message, isMyMessage: isMyMessage),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('outgoing user message shows raw markdown syntax as plain text',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage(content: markdownSource, isMy: true),
      isMyMessage: true,
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text(markdownSource), findsOneWidget);
    expect(find.text('标题'), findsNothing);
    expect(find.text('加粗'), findsNothing);
  });

  testWidgets('incoming agent message still renders markdown preview',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage(content: markdownSource, isMy: false),
      isMyMessage: false,
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text(markdownSource), findsNothing);
    expect(find.textContaining('标题', findRichText: true), findsOneWidget);
    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
  });
}
