import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/message_long_press_handler.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 气泡文本选择与抽屉手势共存的回归锚点：
/// 空闲气泡不包 SelectionArea（其横向拖拽识别器会抢走抽屉打开手势），
/// 长按选中后才挂载 SelectionArea。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message textMessage(String id, String content) {
    return Message(
      id: id,
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
    );
  }

  Future<void> pumpBubble(WidgetTester tester, Message message) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MessageLongPressHandler(
              message: message,
              isGroupMode: false,
              hasSelectableText: true,
              onReply: () {},
              onRollback: () {},
              onReEdit: () {},
              onDelete: () {},
              builder: ({
                required textSelectionEnabled,
                required menuActive,
                required selectionAreaKey,
                required selectionFocusNode,
              }) =>
                  MessageBubble(
                message: message,
                isMyMessage: false,
                textSelectionEnabled: textSelectionEnabled,
                selectionAreaKey: selectionAreaKey,
                selectionFocusNode: selectionFocusNode,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('idle bubble has no SelectionArea so the drawer gesture is not stolen',
      (tester) async {
    await pumpBubble(tester, textMessage('m1', 'hello bubble text'));
    expect(find.byType(SelectionArea), findsNothing,
        reason: '空闲气泡不包 SelectionArea，选区的横向拖拽识别器不会抢走抽屉手势');
  });

  testWidgets('long-press still enables SelectionArea (selection works)',
      (tester) async {
    await pumpBubble(tester, textMessage('m2', 'hello selectable bubble'));
    expect(find.byType(SelectionArea), findsNothing,
        reason: '长按前为空闲态，无 SelectionArea');

    // 在气泡文字上长按（超过 400ms 的长按阈值）。
    final text = find.textContaining('hello', findRichText: true);
    expect(text, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(text));
    await tester.pump(const Duration(milliseconds: 450));
    // 长按触发后：menu 弹出 + textSelectionEnabled 置 true → 重建挂载 SelectionArea。
    await tester.pump();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget,
        reason: '长按选中后应挂载 SelectionArea（选区内拖拽/手柄优先，抽屉让位）');
  });
}
