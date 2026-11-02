import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/onboarding/app_lock_screen.dart';
import 'package:shepaw/services/app_lock_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppLockService.key: true,
    });
  });

  Widget app(AppLockService lock) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AppLockScreen(lock: lock),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  testWidgets('解锁清掉的是传进来的那个实例', (tester) async {
    final lock = AppLockService(
      authenticate: () async => true,
      deviceSupported: () async => true,
    );
    await lock.load();
    expect(lock.locked, isTrue);

    await tester.pumpWidget(app(lock));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(lock.locked, isFalse);
    // 成功后才离开锁屏。
    expect(find.byType(AppLockScreen), findsNothing);
  });

  testWidgets('认证失败时停在锁屏，实例保持锁着', (tester) async {
    final lock = AppLockService(
      authenticate: () async => false,
      deviceSupported: () async => true,
    );
    await lock.load();
    expect(lock.locked, isTrue);

    await tester.pumpWidget(app(lock));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(lock.locked, isTrue);
    expect(find.byType(AppLockScreen), findsOneWidget);
  });
}
