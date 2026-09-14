import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/screens/event_management/event_inbox_tab.dart';
import 'package:shepaw/screens/event_management/event_listen_tab.dart';
import 'package:shepaw/screens/event_management/event_recent_tab.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  const agentId = SheService.sheId;
  late EventBus bus;

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() {
    EventBus.resetForTesting();
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
    EventBus.configure(bus);
  });

  tearDown(EventBus.resetForTesting);

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  /// 投一条 `test.event.ping` 到 [agentId] 的收件箱。
  void deliverPing({String correlation = 'cid_ui_1'}) {
    bus.addSubscription(
      agentId: agentId,
      patterns: const [EventPattern(typeGlob: 'test.event.ping')],
    );
    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.ping',
      payload: const {'summary': '握手'},
      correlationId: correlation,
    );
  }

  group('EventInboxTab', () {
    testWidgets('收件箱行显示本地化类型名 + 原始 type', (tester) async {
      deliverPing();
      await pump(tester, const EventInboxTab(agentId: agentId));

      expect(find.text('测试事件 Ping'), findsOneWidget);
      expect(find.text('test.event.ping'), findsOneWidget);
      // payload 走 EventPayloadView（SelectableText 渲染整段 JSON）。
      expect(find.textContaining('握手'), findsOneWidget);
      expect(find.text('确认收到'), findsOneWidget);
    });

    testWidgets('空收件箱显示空态', (tester) async {
      await pump(tester, const EventInboxTab(agentId: agentId));
      expect(find.text('收件箱为空'), findsOneWidget);
    });

    testWidgets('超过一页时游标分页，翻页后新事件只提示不打断', (tester) async {
      for (var i = 0; i < EventInboxTab.pageSize + 1; i++) {
        deliverPing(correlation: 'cid_ui_page_$i');
      }
      await pump(tester, const EventInboxTab(agentId: agentId));
      expect(find.textContaining('20 条'), findsOneWidget);

      // 第 21 条在首屏之外，滚到底才建出「加载更多」。
      // 每行 payload 里还有一个 SingleChildScrollView，必须指定外层列表。
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pump();

      expect(find.text('加载更多'), findsNothing);
      expect(find.textContaining('21 条'), findsOneWidget);

      // 已翻页：不把用户弹回顶部，只在顶部提示有新内容。
      deliverPing(correlation: 'cid_ui_page_new');
      await tester.pump();
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.textContaining('21 条'), findsOneWidget);
    });

    testWidgets('未翻页时新事件自动出现', (tester) async {
      deliverPing(correlation: 'cid_ui_auto_1');
      await pump(tester, const EventInboxTab(agentId: agentId));
      expect(find.text('测试事件 Ping'), findsOneWidget);

      deliverPing(correlation: 'cid_ui_auto_2');
      await tester.pump();
      expect(find.text('测试事件 Ping'), findsNWidgets(2));
    });

    testWidgets('ack 走 CLI 后行变成已确认', (tester) async {
      deliverPing(correlation: 'cid_ui_ack');
      await pump(tester, const EventInboxTab(agentId: agentId));

      await tester.tap(find.text('确认收到'));
      await tester.pumpAndSettle();

      expect(find.text('已确认'), findsOneWidget);
      expect(find.text('确认收到'), findsNothing);
      expect(
        bus.inboxFor(agentId, unreadOnly: true),
        isEmpty,
        reason: 'CLI ack 应真的写回 store',
      );
    });
  });

  group('EventListenTab', () {
    testWidgets('订阅行显示家族名 + 本地化档位', (tester) async {
      bus.addSubscription(
        agentId: agentId,
        patterns: const [EventPattern(typeGlob: 'chat.group.*')],
      );
      await pump(tester, const EventListenTab(agentId: agentId));

      expect(find.text('群聊编排 · *'), findsOneWidget);
      expect(find.text('chat.group.*'), findsOneWidget);
      expect(find.text('轮询'), findsOneWidget);
    });

    testWidgets('别人的订阅不显示', (tester) async {
      bus.addSubscription(
        agentId: 'someone-else',
        patterns: const [EventPattern(typeGlob: 'chat.group.*')],
      );
      await pump(tester, const EventListenTab(agentId: agentId));

      expect(find.text('群聊编排 · *'), findsNothing);
      expect(find.text('暂无订阅'), findsOneWidget);
    });

    testWidgets('等待租约行显示到期时间并可取消', (tester) async {
      bus.openWaitLease(
        agentId: agentId,
        correlationId: 'cid_ui_lease',
        typePatterns: ['peer.pairing.inbound'],
        timeout: const Duration(seconds: 30),
      );
      await pump(tester, const EventListenTab(agentId: agentId));

      expect(find.text('设备配对请求'), findsOneWidget);
      expect(find.text('peer.pairing.inbound'), findsOneWidget);
      expect(find.textContaining('cid_ui_lease'), findsOneWidget);
    });

    testWidgets('取消无人 await 的租约不产生未捕获异步异常', (tester) async {
      final lease = bus.openWaitLease(
        agentId: agentId,
        typePatterns: ['peer.pairing.inbound'],
        timeout: const Duration(minutes: 5),
      );
      await pump(tester, const EventListenTab(agentId: agentId));

      // 管理页能取消别人开的租约：`WaitLease.cancel()` 会
      // `completeError`，若没有 waitOnLease 在 await，未捕获异常会让本测试
      // 失败 —— 这正是 `_guardUnawaitedLease` 存在的理由。
      await tester.tap(find.byKey(Key('event_lease_cancel_${lease.leaseId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event_lease_cancel_confirm')));
      await tester.pumpAndSettle();

      expect(bus.activeWaitLeases, isEmpty);
      expect(find.text('暂无等待租约'), findsOneWidget);
      // 让 cancel() 派发的异步错误有机会冒出来。
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('EventRecentTab', () {
    testWidgets('空态', (tester) async {
      await pump(tester, const EventRecentTab());
      expect(find.text('本次运行还没有事件'), findsOneWidget);
    });

    testWidgets('emit 后实时出现（验证 emitListenable）', (tester) async {
      await pump(tester, const EventRecentTab());
      expect(find.text('测试事件 Ping'), findsNothing);

      deliverPing(correlation: 'cid_ui_recent');
      await tester.pump();

      expect(find.text('测试事件 Ping'), findsOneWidget);
      expect(find.text('test.event.ping'), findsOneWidget);
    });
  });
}
