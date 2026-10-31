import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/session_search_screen.dart';

/// 两条结果：一条私聊（可以直接聊，带正文片段），一条工作流节点（只读）。
List<Map<String, dynamic>> get _results => [
      {
        'agent_id': 'a1',
        'session_id': 's1',
        'title': '聊聊登录',
        'source': 'shepaw',
        'updated_at': 200,
        'read_only': false,
        'origin': {'kind': 'private'},
        'snippet': '…验证码怎么发…',
      },
      {
        'agent_id': 'a1',
        'session_id': 'part-flow-r1-build',
        'title': '构建登录页',
        'source': 'flow',
        'updated_at': 100,
        'read_only': true,
        'origin': {'kind': 'flow', 'run_id': 'r1', 'node_key': 'build'},
      },
    ];

HubFoldedSessions _host(
  StreamController<PeerControlEvent> bus,
  List<Map<String, dynamic>> results,
  void Function(Map<String, dynamic> frame)? onFrame,
) =>
    HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        onFrame?.call(frame);
        if (frame['type'] != 'agent_sessions_search_req') return true;
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_search_resp',
          'request_id': frame['request_id'],
          'success': true,
          'results': results,
        }));
        return true;
      },
    );

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('searching shows hits with their origin badge', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(SessionSearchScreen(
      peerId: 'p1',
      agentId: 'a1',
      client: _host(bus, _results, sent.add),
      debounce: const Duration(milliseconds: 10),
    )));
    await tester.enterText(
        find.byKey(const ValueKey('session-search-field')), '登录');
    await _settle(tester);

    expect(sent.single['type'], 'agent_sessions_search_req');
    expect(sent.single['agent_id'], 'a1');
    // 一条带正文片段，一条带来源角标。
    expect(find.text('聊聊登录'), findsOneWidget);
    expect(find.text('…验证码怎么发…'), findsOneWidget);
    expect(find.text('构建登录页'), findsOneWidget);
    expect(find.text('工作流'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('no hits says so instead of showing an empty list',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(_app(SessionSearchScreen(
      peerId: 'p1',
      client: _host(bus, const [], null),
      debounce: const Duration(milliseconds: 10),
    )));
    await tester.enterText(
        find.byKey(const ValueKey('session-search-field')), '没有这个词');
    await _settle(tester);
    expect(find.text('没有找到匹配的会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  test('the search frame carries the query and the agent', () {
    expect(
        HubFoldedSessions.searchFrame('登录', agentId: 'a1', limit: 5,
            requestId: 'r'),
        {
          'type': 'agent_sessions_search_req',
          'request_id': 'r',
          'query': '登录',
          'agent_id': 'a1',
          'limit': 5,
        });
  });

  test('a hit knows whether it can be chatted in', () {
    final hit = SessionSearchHit.fromJson({
      'agent_id': 'a1',
      'session_id': 'part-flow-r1-build',
      'title': 'x',
      'source': 'flow',
      'read_only': true,
      'origin': {'kind': 'flow', 'run_id': 'r1'},
    });
    expect(hit.isPrivate, isFalse);
    expect(hit.readOnly, isTrue);
    expect(hit.origin.runId, 'r1');
    // 没有 origin 字段时按私聊处理（老主机的回包）。
    expect(SessionSearchHit.fromJson({'session_id': 's'}).isPrivate, isTrue);
  });
}
