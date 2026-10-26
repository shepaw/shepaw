import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/services/approval/pending_approval_hub.dart';
import 'package:shepaw/services/approval/pending_approval_item.dart';
import 'package:shepaw/services/route_gate.dart';
import 'package:shepaw/storage/pouch_session.dart';
import 'package:shepaw/widgets/approval/pending_approval_banner.dart';

MaterialPageRoute<void> _page(String? name) {
  return MaterialPageRoute<void>(
    settings: RouteSettings(name: name),
    builder: (_) => const SizedBox.shrink(),
  );
}

PouchSession _liveSession({int? expiresAtMs}) {
  return PouchSession(
    hubUrl: 'ws://127.0.0.1:18794/peer/ws',
    pouchId: 'pouch-a',
    pouchName: '书房',
    hostPeerId: 'peer-1',
    token: 'login-token',
    sessionId: 'sid-1',
    expiresAtMs:
        expiresAtMs ?? DateTime.now().millisecondsSinceEpoch + 60 * 1000,
  );
}

void main() {
  tearDown(() => RouteGateObserver.onGate.value = true);

  group('门页判定', () {
    test('登录 / 配对 / 启动门页', () {
      for (final route in [
        '/',
        '/setup',
        '/login',
        '/pouch',
        '/host-setup',
        '/pouch-init',
        '/pouch-unlock',
        '/remote-connect',
        '/phone-login',
      ]) {
        expect(isLoginGateRoute(route), isTrue, reason: '$route 是门页');
      }
    });

    test('主页、聊天和无名路由不算门页', () {
      expect(isLoginGateRoute('/home'), isFalse);
      expect(isLoginGateRoute(null), isFalse);
      expect(isLoginGateRoute('  '), isFalse);
    });
  });

  group('路由观察', () {
    test('进登录页收起，回主页放开', () {
      final observer = RouteGateObserver();
      RouteGateObserver.onGate.value = false;
      final login = _page('/phone-login');
      final home = _page('/home');

      observer.didPush(login, home);
      expect(RouteGateObserver.onGate.value, isTrue);

      observer.didPop(login, home);
      expect(RouteGateObserver.onGate.value, isFalse);
    });

    test('登录页上的弹窗不把审核条带出来', () {
      final observer = RouteGateObserver();
      RouteGateObserver.onGate.value = true;
      observer.didPush(_FakePopupRoute(), _page('/phone-login'));
      expect(RouteGateObserver.onGate.value, isTrue);
    });

    test('聊天的无名路由按登录后处理', () {
      final observer = RouteGateObserver();
      observer.didPush(_page(null), _page('/home'));
      expect(RouteGateObserver.onGate.value, isFalse);
    });
  });

  group('登录态监听', () {
    tearDown(PouchSessionStore.debugResetCache);

    test('保存有效会话后为 true，退出后为 false', () {
      PouchSessionStore.debugResetCache();
      expect(PouchSessionStore.loggedIn.value, isFalse);

      PouchSessionStore.remember(_liveSession());
      expect(PouchSessionStore.loggedIn.value, isTrue);

      PouchSessionStore.remember(null);
      expect(PouchSessionStore.loggedIn.value, isFalse);
    });

    test('过期的 token 不算登录态', () {
      PouchSessionStore.debugResetCache();
      PouchSessionStore.remember(
        _liveSession(
          expiresAtMs: DateTime.now().millisecondsSinceEpoch - 1,
        ),
      );
      expect(PouchSessionStore.loggedIn.value, isFalse);
    });
  });

  group('审核条渲染', () {
    setUp(() {
      PendingApprovalHub.instance.resetForTest();
      PouchSessionStore.remember(_liveSession());
    });

    tearDown(() {
      PendingApprovalHub.instance.resetForTest();
      PouchSessionStore.debugResetCache();
    });

    testWidgets('门页上不渲染，登录后的页面才渲染', (tester) async {
      PendingApprovalHub.instance.upsert(
        const PendingApprovalItem(
          id: 'plan:wf1',
          channelId: 'ch1',
          agentId: 'a1',
          agentName: 'Agent',
          kind: PendingApprovalKind.plan,
          createdAt: 1,
        ),
      );
      RouteGateObserver.onGate.value = true;

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PendingApprovalBanner(
            child: Scaffold(body: Text('gate-page')),
          ),
        ),
      );

      expect(find.text('gate-page'), findsOneWidget);
      expect(find.text('去审核'), findsNothing);

      RouteGateObserver.onGate.value = false;
      await tester.pump();

      expect(find.text('gate-page'), findsOneWidget);
      expect(find.text('去审核'), findsOneWidget);
    });
  });
}

/// 只用来验证 [PopupRoute] 分支，不会真的挂进 Navigator。
class _FakePopupRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const SizedBox.shrink();
}
