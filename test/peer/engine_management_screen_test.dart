import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/screens/engine_management_screen.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = PeerAgentClientService.instance;

  setUp(() => svc.debugResetPeerMetaForTest());
  tearDown(() => svc.debugResetPeerMetaForTest());

  testWidgets('引擎管理页显示汇总和每个引擎的占用', (tester) async {
    svc.debugSendControlOverride = (peerId, json) async {
      scheduleMicrotask(() {
        svc.debugInjectControlForTest(
          'engine_status_resp',
          {
            'request_id': json['request_id'],
            'ok': true,
            'scanned_at': 1730000000000,
            'engines': [
              {
                'id': 'alpha',
                'name': 'Alpha',
                'available': true,
                'instance_count': 2,
                'connections': 2,
                'active_conversations': 1,
              },
              {
                'id': 'beta',
                'name': 'Beta',
                'available': false,
                'unavailable_reason': '找不到命令 beta',
              },
            ],
            'summary': {
              'engines': 2,
              'available_engines': 1,
              'instances': 2,
              'enabled_instances': 2,
              'connections': 2,
              'active_conversations': 1,
            },
          },
          peerId: peerId,
        );
      });
      return true;
    };

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const EngineManagementScreen(peerId: 'host-1'),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 可用引擎排在前面。
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Beta')).dy),
    );
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2 个实例 · 2 个连接 · 1 个对话 · 0 排队'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('不可用'), findsOneWidget);

    // 页面关闭时取消 5 秒静默刷新定时器。
    await tester.pumpWidget(const SizedBox());
  });
}
