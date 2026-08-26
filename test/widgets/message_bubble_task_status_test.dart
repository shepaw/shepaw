import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/group/group_task_status.dart';
import 'package:shepaw/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);

  Message memberMessage(String content, Map<String, dynamic>? metadata) {
    return Message(
      id: 'm1',
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: 'agent', name: 'Coder'),
      type: MessageType.text,
      metadata: metadata,
    );
  }

  Future<void> pumpBubble(WidgetTester tester, Message message) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: surface.width,
            child: MessageBubble(
              message: message,
              isMyMessage: false,
              stickySenderName: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('pending metadata shows chip and hides the raw tag', (tester) async {
    await pumpBubble(
      tester,
      memberMessage('还差一张图\n[TASK_STATUS: pending] 原因：缺图', {
        GroupTaskStatusParser.metadataStatusKey: 'pending',
        GroupTaskStatusParser.metadataReasonKey: '缺图',
      }),
    );

    expect(find.text('未完成'), findsOneWidget);
    expect(find.textContaining('还差一张图', findRichText: true), findsOneWidget);
    expect(find.textContaining('TASK_STATUS', findRichText: true), findsNothing);
  });

  testWidgets('content tag without metadata still badges and is stripped',
      (tester) async {
    await pumpBubble(
      tester,
      memberMessage('全文如下\n[TASK_STATUS: done]', null),
    );

    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('全文如下', findRichText: true), findsOneWidget);
    expect(find.textContaining('TASK_STATUS', findRichText: true), findsNothing);
  });

  testWidgets('old member reply without tag or metadata has no chip',
      (tester) async {
    await pumpBubble(tester, memberMessage('很久以前的回复', null));

    expect(find.text('已完成'), findsNothing);
    expect(find.text('未完成'), findsNothing);
    expect(find.text('未标注'), findsNothing);
    expect(find.textContaining('很久以前的回复', findRichText: true), findsOneWidget);
  });
}
