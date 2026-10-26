import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/services/route_gate.dart';
import 'package:shepaw/widgets/pouch_relogin_banner.dart';

void main() {
  tearDown(() => RouteGateObserver.onGate.value = true);

  Future<void> pumpBanner(
    WidgetTester tester, {
    required ValueNotifier<bool> required,
    VoidCallback? onSignIn,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PouchReloginBanner(
          required: required,
          onSignIn: onSignIn,
          child: const Scaffold(body: Text('chat-page')),
        ),
      ),
    );
  }

  testWidgets('不需要密码时不出现', (tester) async {
    RouteGateObserver.onGate.value = false;
    final required = ValueNotifier<bool>(false);
    addTearDown(required.dispose);
    await pumpBanner(tester, required: required);
    expect(find.text('chat-page'), findsOneWidget);
    expect(find.text('主机要求重新登录'), findsNothing);
  });

  testWidgets('主机要密码时出现在聊天页顶部，点一下去登录', (tester) async {
    RouteGateObserver.onGate.value = false;
    final required = ValueNotifier<bool>(true);
    addTearDown(required.dispose);
    var taps = 0;
    await pumpBanner(tester, required: required, onSignIn: () => taps += 1);
    expect(find.text('chat-page'), findsOneWidget);
    expect(find.text('主机要求重新登录'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);

    await tester.tap(find.text('去登录'));
    expect(taps, 1);

    required.value = false;
    await tester.pump();
    expect(find.text('主机要求重新登录'), findsNothing);
  });

  testWidgets('登录页上不显示', (tester) async {
    RouteGateObserver.onGate.value = true;
    final required = ValueNotifier<bool>(true);
    addTearDown(required.dispose);
    await pumpBanner(tester, required: required);
    expect(find.text('主机要求重新登录'), findsNothing);
  });
}
