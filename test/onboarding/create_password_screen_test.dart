import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/onboarding/create_password_screen.dart';

void main() {
  testWidgets('只有一个密码框：没有「再输一次」', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CreatePasswordScreen(),
      ),
    );
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2)); // 称呼 + 密码
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.obscureText,
      ),
      findsOneWidget,
    );
  });

  testWidgets('称呼变了，提示跟着变', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CreatePasswordScreen(),
      ),
    );
    await tester.pump();
    // 没填称呼时不显示那行提示。
    expect(find.textContaining('会显示为'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Eden');
    await tester.pump();
    expect(find.textContaining('Eden'), findsWidgets);
  });

  testWidgets('密码少于 6 位时不提交', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CreatePasswordScreen(),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.obscureText,
      ),
      '123',
    );
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
    // 停在这一页，并给出「至少 6 位」。
    expect(find.byType(CreatePasswordScreen), findsOneWidget);
    expect(find.text('至少 6 位'), findsWidgets);
  });
}
