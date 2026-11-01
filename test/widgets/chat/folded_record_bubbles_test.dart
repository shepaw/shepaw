import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/screens/session_history_screen.dart';
import 'package:shepaw/widgets/message_bubble.dart';

/// 折叠组里那份只读记录的正文，走的是私聊同一套气泡（[MessageBubble]）。
///
/// 早先这里自己画彩色方块 + [SelectableText]，和私聊长得完全不是一回事。
void main() {
  PeerHistoryPage page() => PeerHistoryPage(
        completed: true,
        messages: [
          PeerHistoryMessage(role: 'user', content: '跑一下测试'),
          PeerHistoryMessage(role: 'agent', content: '测试通过了'),
        ],
      );

  testWidgets('只读记录的正文走私聊的气泡', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SessionHistoryScreen(
        title: '终端会话',
        recordId: 's1',
        loadPage: (_) async => page(),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(MessageBubble), findsNWidgets(2));
    // 内容还在：气泡里渲染的是同一份正文。
    expect(find.text('跑一下测试'), findsWidgets);
    expect(find.text('测试通过了'), findsWidgets);
  });

  testWidgets('气泡里不显示引擎内置标记，只留内容', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SessionHistoryScreen(
        title: '终端会话',
        recordId: 's1',
        loadPage: (_) async => PeerHistoryPage(
          completed: true,
          messages: [
            PeerHistoryMessage(
              role: 'user',
              content:
                  '<command-name>/model</command-name>\n<local-command-stdout>已切换</local-command-stdout>',
            ),
            PeerHistoryMessage(
              role: 'agent',
              content:
                  '<local-command-caveat>这条命令在本机执行过</local-command-caveat>',
            ),
          ],
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 标记本身不出现。
    expect(find.textContaining('<local-command-caveat>'), findsNothing);
    expect(find.textContaining('<command-name>'), findsNothing);
    expect(find.textContaining('<local-command-stdout>'), findsNothing);
    // 被包住的内容照常显示。
    expect(find.textContaining('这条命令在本机执行过'), findsOneWidget);
    expect(find.textContaining('已切换'), findsOneWidget);
  });
}
