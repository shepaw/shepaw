import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/widgets/chat/agent_session_folders.dart';

HubFoldedSessions _host(
        StreamController<PeerControlEvent> bus, Object? folders) =>
    HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_resp',
          'request_id': frame['request_id'],
          'agent_id': 'a1',
          'sessions': [],
          'folders': folders,
        }));
        return true;
      },
    );

void main() {
  testWidgets('non-empty folders show as rows with their counts',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentSessionFolders(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: _host(bus, [
            {'kind': 'group', 'count': 6, 'latest_title': '周会'},
            {'kind': 'flow', 'count': 2, 'latest_title': 'review'},
          ]),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('群聊 · 6'), findsOneWidget);
    expect(find.text('工作流 · 2'), findsOneWidget);
    expect(find.text('周会'), findsOneWidget);
    await bus.close();
  });

  testWidgets('an old host without folders leaves the list untouched',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentSessionFolders(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: _host(bus, null),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(ListTile), findsNothing);
    await bus.close();
  });

  testWidgets('forking a folded session refreshes the flat list right away',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    var forkAsked = 0;
    var summariesAsked = 0;
    final client = HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        final id = frame['request_id'];
        switch (frame['type']) {
          case 'agent_session_fork_req':
            forkAsked++;
            bus.add(PeerControlEvent(peerId: peerId, data: {
              'type': 'agent_session_fork_resp',
              'request_id': id,
              'ok': true,
              'session_id': 'new-1',
            }));
          case 'agent_sessions_req':
            // 带 folder 的是组明细；不带的是摘要。
            if (frame['folder'] == null) {
              summariesAsked++;
              bus.add(PeerControlEvent(peerId: peerId, data: {
                'type': 'agent_sessions_resp',
                'request_id': id,
                'agent_id': 'a1',
                'sessions': [],
                'folders': [
                  {'kind': 'group', 'count': 1, 'latest_title': '周会'},
                ],
              }));
            } else {
              bus.add(PeerControlEvent(peerId: peerId, data: {
                'type': 'agent_sessions_resp',
                'request_id': id,
                'agent_id': 'a1',
                'folder': frame['folder'],
                'sessions': [
                  {
                    'session_id': 'part-group-g1-s1',
                    'title': '群里的话',
                    'updated_at': 1,
                    'origin': {
                      'kind': 'group',
                      'group_id': 'g1',
                      'session_id': 's1'
                    },
                  },
                ],
              }));
            }
        }
        return true;
      },
    );
    final refreshed = <String>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentSessionFolders(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: client,
          refresh: (peerId, remoteAgentId) async {
            refreshed.add('$peerId|$remoteAgentId');
          },
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('群聊 · 1'), findsOneWidget);
    expect(summariesAsked, 1);

    // 进组明细 → 打开群聊视角 → 分叉（标题栏的按钮一定点得到）。
    await tester.tap(find.text('群聊 · 1'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('群里的话'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 群聊视角的"分叉到私聊"在 AppBar 右侧。这一屏的 AppBar 比视口宽
    // （SelectableText 撑开的既有问题），坐标命中打不到，直接调按钮的回调。
    final forkButton = tester.widget<TextButton>(find.ancestor(
      of: find.text('分叉到私聊'),
      matching: find.byType(TextButton),
    ));
    await tester.runAsync(() async {
      forkButton.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(forkAsked, 1);
    // 请求那条 10 秒的超时计时器还在：推掉它，免得用例结尾报 pending timer。
    await tester.pump(const Duration(seconds: 11));

    // 分叉之后立刻对齐一次主机名单：新私聊不用等下一次同步才出现。
    expect(refreshed, ['p1|a1']);
    // 折叠组也顺手重刷了。
    expect(summariesAsked, 2);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
