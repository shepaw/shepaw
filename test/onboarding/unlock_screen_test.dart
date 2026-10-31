import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/onboarding/gate_entry.dart';
import 'package:shepaw/onboarding/unlock_screen.dart';
import 'package:shepaw/onboarding/widgets/gate_widgets.dart';
import 'package:shepaw/storage/pouch_login_client.dart';
import 'gate_controller_test.dart' as shared;

typedef Harness = shared.FakeDeps;

/// 把页面挂起来，顺手把 l10n 取出来给断言用。
Future<AppLocalizations> pumpUnlock(
  WidgetTester tester, {
  required UnlockArgs args,
  required shared.FakeDeps fake,
}) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          l10n = AppLocalizations.of(context);
          return UnlockScreen(key: ValueKey<Object>(args), args: args, deps: fake.build());
        },
      ),
    ),
  );
  await tester.pump();
  return l10n;
}

class Boom implements Exception {
  const Boom();

  @override
  String toString() => 'Boom';
}

void main() {
  testWidgets('只有一个密码框，没有袋子单选和袋子名输入', (tester) async {
    await pumpUnlock(
      tester,
      args: const UnlockArgs(hostPeerId: 'peer-1'),
      fake: Harness(current: shared.session()),
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(RadioListTile<String>), findsNothing);
  });

  testWidgets('欢迎语里是「欢迎回来」', (tester) async {
    await pumpUnlock(
      tester,
      args: const UnlockArgs(hostPeerId: 'peer-1'),
      fake: Harness(current: shared.session()),
    );
    expect(find.textContaining('欢迎回来'), findsOneWidget);
  });

  testWidgets('主机离线时给出说明和重试，不弹原始错误', (tester) async {
    await pumpUnlock(
      tester,
      args: const UnlockArgs(hostPeerId: 'peer-1'),
      fake: Harness(
        current: shared.session(),
        connectError: const Boom(),
        listError: const Boom(),
      ),
    );
    expect(find.byType(GateStatusCard), findsOneWidget);
    expect(find.textContaining('Boom'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('锁定后主按钮变成倒计时', (tester) async {
    await pumpUnlock(
      tester,
      args: const UnlockArgs(hostPeerId: 'peer-1'),
      fake: Harness(
        current: shared.session(),
        loginError: const PouchPasswordRequired(
          '试错太多次',
          code: 'locked',
          retryAfter: const Duration(seconds: 2),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'secret1');
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();
    expect(find.textContaining('秒后再试'), findsOneWidget);
    // 让倒计时的定时器走完，别留到 tearDown。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('原因条只在有理由时出现', (tester) async {
    final expected = <UnlockReason, bool>{
      UnlockReason.expired: false,
      UnlockReason.switched: false,
      UnlockReason.credentialRejected: true,
      UnlockReason.hostRestarted: true,
      UnlockReason.inviteInvalid: true,
    };
    for (final entry in expected.entries) {
      final l10n = await pumpUnlock(
        tester,
        args: UnlockArgs(hostPeerId: 'peer-1', reason: entry.key),
        fake: Harness(current: shared.session()),
      );
      final present = <bool>[
        find.text(l10n.unlock_whyCredential).evaluate().isNotEmpty,
        find.text(l10n.unlock_whyRestarted).evaluate().isNotEmpty,
        find.text(l10n.unlock_whyInvite).evaluate().isNotEmpty,
      ].any((found) => found);
      expect(present, entry.value, reason: '${entry.key}');
    }
  });
}
