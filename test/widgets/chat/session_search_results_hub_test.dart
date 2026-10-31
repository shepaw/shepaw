import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/message_search_service.dart';
import 'package:shepaw/widgets/chat/session_search_results.dart';

/// 抽屉顶部的搜索框也要能搜到折叠组里的会话。
///
/// 那些会话（群聊 / 工作流 / 引擎客户端 / 引擎终端）本机没有副本 —— 主机的折叠
/// 视图只平铺私聊，本地那份镜像会被剪掉 —— 所以本机那一轮搜索之外，还要问一次
/// 主机，结果单独成一段、带来源角标。这段用例把「一处搜全部」钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 主机只回一条引擎终端的会话；`search` 打出去的关键词记下来。
  HubFoldedSessions host(
    StreamController<PeerControlEvent> bus,
    List<String> asked,
  ) =>
      HubFoldedSessions(
        events: bus.stream,
        send: (peerId, frame) async {
          asked.add(frame['query'] as String? ?? '');
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_sessions_search_resp',
            'request_id': frame['request_id'],
            'results': [
              {
                'agent_id': frame['agent_id'] ?? '',
                'session_id': 'term-1',
                'title': '在终端里跑测试',
                'updated_at': 1,
                'read_only': true,
                'origin': {'kind': 'terminal'},
                'snippet': '跑一下 cargo test',
              },
            ],
          }));
          return true;
        },
      );

  Widget results(
    HubFoldedSessions client, {
    String query = '测试',
    List<Channel>? sessions,
  }) =>
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SessionSearchResults(
            query: query,
            sessions: sessions ??
                [
                  Channel(
                    id: 's0',
                    name: '本机私聊',
                    type: 'dm',
                    members: const [],
                  ),
                ],
            searchService: MessageSearchService(LocalDatabaseService()),
            onSwitchSession: (_) {},
            onLocateMessage: (Message _, String? __) {},
            foldedTarget: (peerId: 'p1', remoteAgentId: 'ra1'),
            hubClient: client,
          ),
        ),
      );

  testWidgets('折叠组里的会话跟着本机结果一起出现，带来源角标', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final asked = <String>[];
    await tester.pumpWidget(results(host(bus, asked)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 关键词发给了主机，按折叠目标里的 agent 过滤。
    expect(asked, ['测试']);
    expect(find.text('在终端里跑测试'), findsOneWidget);
    // 来源角标：看得出这条只读记录来自哪个折叠组。
    expect(find.text('引擎终端'), findsOneWidget);
    await bus.close();
  });

  testWidgets('没有折叠目标时只搜本机，不打扰主机', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SessionSearchResults(
            query: '测试',
            sessions: [
              Channel(id: 's0', name: '本机私聊', type: 'dm', members: const []),
            ],
            searchService: MessageSearchService(LocalDatabaseService()),
            onSwitchSession: (_) {},
            onLocateMessage: (Message _, String? __) {},
            hubClient: host(bus, asked),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(asked, isEmpty);
    expect(find.text('在终端里跑测试'), findsNothing);
    await bus.close();
  });
}
