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

  Future<void> openMenu(WidgetTester tester) async {
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
                  session: session(),
                  sessionTitle: 'First sentence title',
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

  testWidgets('长按菜单提供复制会话标题和 ID、以及 Channel ID', (tester) async {
    await openMenu(tester);
    expect(find.text('复制会话标题和 ID'), findsOneWidget);
    expect(find.text('复制 Channel ID'), findsOneWidget);
  });

  testWidgets('复制会话标题和 ID 写入标题与 channel id', (tester) async {
    await openMenu(tester);
    await tester.tap(find.text('复制会话标题和 ID'));
    await tester.pumpAndSettle();
    expect(
      copiedText(),
      'First sentence title\ndm_user1_agent1_1700000000000',
    );
    await flushToastTimers(tester);
  });

  testWidgets('复制 Channel ID 只写入 channel id', (tester) async {
    await openMenu(tester);
    await tester.tap(find.text('复制 Channel ID'));
    await tester.pumpAndSettle();
    expect(copiedText(), 'dm_user1_agent1_1700000000000');
    await flushToastTimers(tester);
  });
}
