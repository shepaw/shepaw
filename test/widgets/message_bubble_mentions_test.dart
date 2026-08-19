import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);

  Message mentionMessage(
    String id,
    String content,
    Map<String, dynamic>? metadata,
  ) {
    return Message(
      id: id,
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
      metadata: metadata,
    );
  }

  Future<void> pumpBubble(WidgetTester tester, Message message) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: surface.width,
            child: MessageBubble(message: message, isMyMessage: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('notify mention renders @name without (cc)', (tester) async {
    await pumpBubble(
      tester,
      mentionMessage('m1', '请 @张三 帮忙', {
        'mentions': [
          {'id': 'a1', 'name': '张三', 'notify': true},
        ],
      }),
    );
    expect(find.textContaining('@张三', findRichText: true), findsOneWidget);
    expect(find.textContaining('(cc)', findRichText: true), findsNothing);
  });

  testWidgets('cc-only mention gets (cc) suffix', (tester) async {
    await pumpBubble(
      tester,
      mentionMessage('m1', '已抄送 @Reviewer', {
        'mentions': [
          {'id': 'a3', 'name': 'Reviewer', 'notify': false},
        ],
      }),
    );
    expect(
        find.textContaining('@Reviewer(cc)', findRichText: true), findsOneWidget);
  });

  testWidgets('boundary: @Tommy is not annotated as member Tom',
      (tester) async {
    await pumpBubble(
      tester,
      mentionMessage('m1', '@Tommy 你好', {
        'mentions': [
          {'id': 'a4', 'name': 'Tom', 'notify': true},
        ],
      }),
    );
    expect(find.textContaining('@Tommy', findRichText: true), findsOneWidget);
    expect(find.textContaining('(cc)', findRichText: true), findsNothing);
  });

  testWidgets('no metadata → content unchanged', (tester) async {
    await pumpBubble(tester, mentionMessage('m1', '普通消息 @张三', null));
    expect(find.textContaining('@张三', findRichText: true), findsOneWidget);
    expect(find.textContaining('(cc)', findRichText: true), findsNothing);
  });
}
