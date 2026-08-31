import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 指令集消息气泡：只展示指令标题，完整内容作为隐式消息不展示。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);
  const fullContent = '执行指令「沉淀指令」：\n将最近的任务总结为一个指令，方便下次唤醒你完成相同任务时，你能够直接理解';

  Message instructionMessage({required bool isMy}) {
    return Message(
      id: 'instr-1',
      content: fullContent,
      timestampMs: 0,
      from: MessageFrom(
        id: isMy ? 'user' : 'agent',
        type: isMy ? 'user' : 'agent',
        name: isMy ? '我' : 'Agent',
      ),
      type: MessageType.text,
      metadata: {'instruction': '沉淀指令'},
    );
  }

  Future<void> pumpBubble(WidgetTester tester, Message message,
      {required bool isMyMessage}) async {
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

  testWidgets('instruction bubble shows only the title, hides full content',
      (tester) async {
    await pumpBubble(tester, instructionMessage(isMy: true), isMyMessage: true);

    // 标题可见。
    expect(find.text('沉淀指令'), findsOneWidget);
    // 完整内容（含「执行指令「沉淀指令」：」前缀与正文）不作为文本渲染。
    expect(find.text(fullContent), findsNothing);
    expect(find.textContaining('将最近的任务总结为一个指令'), findsNothing);
    // 带指令图标。
    expect(find.byIcon(Icons.playlist_add_check_outlined), findsOneWidget);
  });

  testWidgets('instruction bubble also renders for non-my message',
      (tester) async {
    await pumpBubble(tester, instructionMessage(isMy: false), isMyMessage: false);

    expect(find.text('沉淀指令'), findsOneWidget);
    expect(find.text(fullContent), findsNothing);
    expect(find.textContaining('将最近的任务总结为一个指令'), findsNothing);
  });

  testWidgets('normal message without instruction metadata renders content',
      (tester) async {
    final normal = Message(
      id: 'm-1',
      content: '普通消息',
      timestampMs: 0,
      from: MessageFrom(id: 'user', type: 'user', name: '我'),
      type: MessageType.text,
    );
    await pumpBubble(tester, normal, isMyMessage: true);
    expect(find.text('普通消息'), findsOneWidget);
    expect(find.byIcon(Icons.playlist_add_check_outlined), findsNothing);
  });
}
