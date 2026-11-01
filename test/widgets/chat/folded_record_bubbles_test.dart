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
}
