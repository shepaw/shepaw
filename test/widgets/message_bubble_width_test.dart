import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);

  Message textMessage(String id, String content, {String fromType = 'agent'}) {
    return Message(
      id: id,
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: fromType, name: 'Agent'),
      type: MessageType.text,
    );
  }

  Future<void> pumpBubble(
    WidgetTester tester, {
    required Message message,
    required bool isMyMessage,
    bool stickySenderName = false,
    bool showAvatar = false,
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
            child: MessageBubble(
              message: message,
              isMyMessage: isMyMessage,
              showAvatar: showAvatar,
              showSenderName: stickySenderName,
              stickySenderName: stickySenderName,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walks up from [content] to the rounded chat bubble container.
  Size bubbleSizeFor(WidgetTester tester, Finder content) {
    final bubble = find.ancestor(
      of: content,
      matching: find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final decoration = w.decoration;
        if (decoration is! BoxDecoration) return false;
        final radius = decoration.borderRadius;
        return radius == BorderRadius.circular(16);
      }),
    );
    expect(bubble, findsWidgets);
    return tester.getSize(bubble.first);
  }

  testWidgets('DM incoming short text bubble shrinks below max width',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage('m1', 'Hi'),
      isMyMessage: false,
    );

    final size = bubbleSizeFor(tester, find.textContaining('Hi', findRichText: true));
    // Available row is ~400; short bubble must stay clearly under half.
    expect(size.width, lessThan(surface.width * 0.5));
    expect(size.width, greaterThan(20));
  });

  testWidgets('DM outgoing short text bubble shrinks below max width',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage('m2', 'Ok', fromType: 'user'),
      isMyMessage: true,
    );

    final size = bubbleSizeFor(tester, find.textContaining('Ok', findRichText: true));
    expect(size.width, lessThan(surface.width * 0.5));
  });

  testWidgets('group sticky short text bubble shrinks below max width',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage('m3', 'Yo'),
      isMyMessage: false,
      stickySenderName: true,
      showAvatar: true,
    );

    final size = bubbleSizeFor(tester, find.textContaining('Yo', findRichText: true));
    expect(size.width, lessThan(surface.width * 0.5));
  });

  testWidgets('long text bubble uses more width than short bubble',
      (tester) async {
    await pumpBubble(
      tester,
      message: textMessage('short', 'Hi'),
      isMyMessage: false,
    );
    final shortW =
        bubbleSizeFor(tester, find.textContaining('Hi', findRichText: true))
            .width;

    await pumpBubble(
      tester,
      message: textMessage(
        'long',
        'This is a much longer reply that should wrap across multiple lines '
            'and therefore produce a wider chat bubble than a short greeting.',
      ),
      isMyMessage: false,
    );
    final longW = bubbleSizeFor(
      tester,
      find.textContaining('This is a much longer', findRichText: true),
    ).width;

    expect(longW, greaterThan(shortW + 40));
  });
}
