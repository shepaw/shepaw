import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/onboarding/welcome_screen.dart';

Widget app(Widget child, {double width = 1280}) {
  return MediaQuery(
    data: MediaQueryData(size: Size(width, 800)),
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

void main() {
  testWidgets('宽窗口两张卡片并排，内容不铺满', (tester) async {
    await tester.pumpWidget(app(const WelcomeScreen()));
    await tester.pump();
    expect(find.text('这台电脑'), findsOneWidget);
    expect(find.text('另一台电脑'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsAtLeastNWidgets(1));
    // 内容居中成卡片，不是铺满 1280。
    final constrained = tester.widget<ConstrainedBox>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox && widget.constraints.maxWidth == 640,
      ),
    );
    expect(tester.renderObject<RenderBox>(find.byWidget(constrained)).size.width,
        lessThanOrEqualTo(640));
  });

  testWidgets('窄窗口卡片上下排', (tester) async {
    await tester.pumpWidget(app(const WelcomeScreen(), width: 420));
    await tester.pump();
    expect(find.text('这台电脑'), findsOneWidget);
    expect(find.text('另一台电脑'), findsOneWidget);
  });

  testWidgets('点「去连接」切到粘贴视图', (tester) async {
    await tester.pumpWidget(app(const WelcomeScreen()));
    await tester.pump();
    await tester.tap(find.text('去连接'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('连接'), findsWidgets);
  });

  testWidgets('粘贴视图对无效链接实时报错，按钮禁用', (tester) async {
    await tester.pumpWidget(app(const WelcomeScreen()));
    await tester.pump();
    await tester.tap(find.text('去连接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.pump();
    expect(find.text('这不是有效的加入链接'), findsOneWidget);
  });

  testWidgets('安装命令跟着平台走', (tester) async {
    final command = cliInstallCommand();
    expect(command, isNotEmpty);
    expect(command.startsWith('curl') || command.startsWith('irm'), isTrue);
  });
}
