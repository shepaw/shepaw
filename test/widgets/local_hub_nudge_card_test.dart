import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/widgets/local_agent_hub_prompt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpCard(
    WidgetTester tester, {
    required VoidCallback onAction,
    required VoidCallback onDismiss,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LocalHubNudgeCard(
            title: '本机 Agent Hub',
            body: '已安装。加入后会出现在通讯录。',
            actionLabel: '加入',
            dismissTooltip: '不再提示',
            onAction: onAction,
            onDismiss: onDismiss,
          ),
        ),
      ),
    );
  }

  testWidgets('nudge card shows copy and join', (tester) async {
    var joined = false;
    await pumpCard(tester, onAction: () => joined = true, onDismiss: () {});

    expect(find.text('本机 Agent Hub'), findsOneWidget);
    expect(find.text('已安装。加入后会出现在通讯录。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '加入'));
    expect(joined, isTrue);
  });

  testWidgets('close means do not ask again', (tester) async {
    var dismissed = false;
    await pumpCard(tester, onAction: () {}, onDismiss: () => dismissed = true);

    await tester.tap(find.byTooltip('不再提示'));
    expect(dismissed, isTrue);
  });
}
