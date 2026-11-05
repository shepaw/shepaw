import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/widgets/chat/chat_queue_panel.dart';

Widget wrap(ValueNotifier<SessionState> state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChatQueuePanel(
          items: const [],
          state: state,
          onEdit: (_, __) {},
          onDelete: (_) {},
          onMove: (_, __) {},
          onClearAll: () {},
        ),
      ),
    );

SessionState withQueue(int count, {String content = '排队消息'}) => SessionState(
      sessionKey: 'agent:a:s1',
      revision: 7,
      generation: 3,
      isRunning: true,
      turnId: 't1',
      queue: List<QueuedItem>.generate(
        count,
        (index) => QueuedItem(
          requestId: 't${index + 2}',
          position: index + 1,
          preview: '截断预览',
          content: content,
        ),
        growable: false,
      ),
    );

void main() {
  testWidgets('队列为空时不渲染面板', (tester) async {
    final notifier =
        ValueNotifier<SessionState>(SessionState.empty('agent:a:s1'));
    addTearDown(notifier.dispose);
    await tester.pumpWidget(wrap(notifier));
    expect(find.byIcon(Icons.queue), findsNothing);
  });

  testWidgets('状态跃迁同帧刷新，不需要整页 setState 或手势', (tester) async {
    final notifier =
        ValueNotifier<SessionState>(SessionState.empty('agent:a:s1'));
    addTearDown(notifier.dispose);
    await tester.pumpWidget(wrap(notifier));
    expect(find.byIcon(Icons.queue), findsNothing);

    // 模拟主机 session.state / session_ack 到达：只改 notifier，外层没有
    // 任何 setState、没有滚动手势。旧实现会卡旧值直到用户手滑一下。
    notifier.value = withQueue(1);
    await tester.pump();

    expect(find.byIcon(Icons.queue), findsOneWidget);
  });

  testWidgets('队列清空后立即收起', (tester) async {
    final notifier = ValueNotifier<SessionState>(withQueue(2));
    addTearDown(notifier.dispose);
    await tester.pumpWidget(wrap(notifier));
    expect(find.byIcon(Icons.queue), findsOneWidget);

    notifier.value = const SessionState(
      sessionKey: 'agent:a:s1',
      revision: 9,
      generation: 3,
      isRunning: false,
      lastTerminal: SessionTerminal(
        turnId: 't1',
        reason: 'end_turn',
        atMs: 2000,
        revision: 9,
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.queue), findsNothing);
  });

  testWidgets('折叠态预览用完整正文，不拿截断的 preview', (tester) async {
    final long = '这是完整的排队正文，不能被截断' * 10;
    final notifier = ValueNotifier<SessionState>(withQueue(1, content: long));
    addTearDown(notifier.dispose);
    await tester.pumpWidget(wrap(notifier));
    expect(find.text(long), findsOneWidget);
    expect(find.text('截断预览'), findsNothing);
  });
}
