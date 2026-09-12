import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/widgets/chat/session_row_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Channel session() => Channel(
        id: 'dm_user1_agent1_1700000000000',
        name: 'Session name',
        type: 'dm',
        members: const [],
      );

  Future<void> openMenu(
    WidgetTester tester, {
    Channel? channel,
    String? sessionTitle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => showSessionRowMenu(
                  context,
                  session: channel ?? session(),
                  sessionTitle: sessionTitle ?? 'First sentence title',
                  isCurrentSession: true,
                ),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> flushToastTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  String? copiedText() {
    for (final call in platformCalls.reversed) {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is Map) return args['text'] as String?;
      }
    }
    return null;
  }

  testWidgets('长按菜单只提供一项复制会话信息', (tester) async {
    await openMenu(tester);
    expect(find.text('复制会话信息'), findsOneWidget);
    expect(find.text('复制会话标题'), findsNothing);
    expect(find.text('复制会话 ID'), findsNothing);
    expect(find.text('复制 Channel ID'), findsNothing);
  });

  testWidgets('复制会话信息按三行写入标题、会话 ID、channel ID', (tester) async {
    await openMenu(tester);
    await tester.tap(find.text('复制会话信息'));
    await tester.pumpAndSettle();
    expect(
      copiedText(),
      '标题：First sentence title\n'
      '会话 ID：dm_user1_agent1_1700000000000\n'
      'channel ID：dm_user1_agent1_1700000000000',
    );
    await flushToastTimers(tester);
  });

  testWidgets('群子会话的 channel ID 是群 id，会话 ID 是子会话 id', (tester) async {
    await openMenu(
      tester,
      channel: Channel(
        id: 'group_child-session',
        name: 'Child session',
        type: 'group',
        members: const [],
        parentGroupId: 'group_family-root',
      ),
      sessionTitle: '阶段讨论',
    );
    await tester.tap(find.text('复制会话信息'));
    await tester.pumpAndSettle();
    expect(
      copiedText(),
      '标题：阶段讨论\n'
      '会话 ID：group_child-session\n'
      'channel ID：group_family-root',
    );
    await flushToastTimers(tester);
  });
}
