import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/widgets/chat/chat_app_bar.dart';
import 'package:shepaw/widgets/chat/chat_event_listen_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    EventBus.resetForTesting();
    EventBus.configure(EventBus());
  });

  tearDown(EventBus.resetForTesting);

  Future<void> pumpBadge(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatEventListenBadge(agentIds: ['agent-1']),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('无监听时不显示徽标', (tester) async {
    await pumpBadge(tester);
    expect(find.byIcon(Icons.sensors), findsNothing);
  });

  testWidgets('有订阅时显示数量，点击展开列表', (tester) async {
    EventBus.instance.addSubscription(
      agentId: 'agent-1',
      patterns: const [EventPattern(typeGlob: 'peer.pairing.inbound')],
      delivery: EventDelivery.active,
    );

    await pumpBadge(tester);
    expect(find.byIcon(Icons.sensors), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.textContaining('正在监听的事件'), findsOneWidget);
    expect(find.text('peer.pairing.inbound'), findsOneWidget);
    expect(find.textContaining('订阅'), findsOneWidget);

    final panel = tester.getSize(find.byKey(const Key('chat_event_listen_panel')));
    expect(panel.width, lessThanOrEqualTo(220));
    expect(panel.height, lessThan(200));
    expect(panel.height, greaterThan(40));
  });

  testWidgets('鼠标悬停徽标时展开面板', (tester) async {
    EventBus.instance.addSubscription(
      agentId: 'agent-1',
      patterns: const [EventPattern(typeGlob: 'peer.pairing.inbound')],
      delivery: EventDelivery.active,
    );

    await pumpBadge(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.sensors)));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('peer.pairing.inbound'), findsOneWidget);
  });

  testWidgets('事件数标记在标题状态栏，与在线状态同行', (tester) async {
    EventBus.instance.addSubscription(
      agentId: 'agent-1',
      patterns: const [EventPattern(typeGlob: 'peer.pairing.inbound')],
      delivery: EventDelivery.active,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(
            title: const ChatDMAppBarTitle(
              agentName: 'Shee',
              isProcessing: false,
              isCheckingHealth: false,
              isAgentOnline: true,
              agentId: 'agent-1',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.sensors), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);

    final nameY = tester.getCenter(find.text('Shee')).dy;
    final onlineY = tester.getCenter(find.text('在线')).dy;
    final badgeY = tester.getCenter(find.byIcon(Icons.sensors)).dy;
    expect(badgeY, greaterThan(nameY + 4));
    expect((badgeY - onlineY).abs(), lessThan(6));
  });
}
