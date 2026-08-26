import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 聊天正文里裸 `store://` URI 渲染成可点击链接。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const surface = Size(400, 800);
  const uri = 'store://workspaces/aaaaaaaaaaaaaaaa/group_x/snake-game.html';

  Message textMessage(String content) {
    return Message(
      id: 'm1',
      content: content,
      timestampMs: 0,
      from: MessageFrom(id: 'a-1', type: 'agent', name: 'Agent'),
      type: MessageType.text,
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

  testWidgets('bare store:// URI renders as basename link', (tester) async {
    await pumpBubble(tester, textMessage(uri));
    // 整个段落 plain text 就是 basename：证明已被链接化，而非原文输出。
    expect(find.text('snake-game.html', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('store://workspaces', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('URI inside existing markdown link stays one link',
      (tester) async {
    await pumpBubble(tester, textMessage('[点我]($uri)'));
    expect(find.text('点我', findRichText: true), findsOneWidget);
    // 不产生 basename 的第二个链接文本。
    expect(find.text('snake-game.html', findRichText: true), findsNothing);
  });

  testWidgets('inline code store URI is not linkified', (tester) async {
    await pumpBubble(tester, textMessage('用 `$uri` 打开'));
    // 代码 span 原文渲染，不出现链接 basename。
    expect(find.text('snake-game.html', findRichText: true), findsNothing);
  });
}
