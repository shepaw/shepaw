import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/screens/session_history_screen.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
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

/// 摘要之外还答得出组明细：用来试「就地展开」。
HubFoldedSessions _hostWithItems(StreamController<PeerControlEvent> bus) =>
    HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        final id = frame['request_id'];
        if (frame['folder'] != null) {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_sessions_resp',
            'request_id': id,
            'agent_id': 'a1',
            'folder': frame['folder'],
            'sessions': [
              {
                'session_id': 'part-group-g1-s1',
                'title': '周会',
                'updated_at': 1,
                'origin': {
                  'kind': 'group',
                  'group_id': 'g1',
                  'session_id': 's1'
                },
              },
            ],
          }));
          return true;
        }
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_resp',
          'request_id': id,
          'agent_id': 'a1',
          'sessions': [],
          'folders': [
            {'kind': 'group', 'count': 6, 'latest_title': '最新一条'},
          ],
        }));
        return true;
      },
    );

/// 真实用法的外层：展开态由它持有（[AgentSessionFolders] 自己没有展开态，
/// 没有 [AgentSessionFolders.onToggle] 就点不开）。
///
/// 面板里还会在「展开那一行滑出可视区」时盖一行上去，那是面板自己的事；
/// 这两个用例只关心就地展开 / 收起。
class _WithExpandedState extends StatefulWidget {
  const _WithExpandedState({
    required this.peerId,
    required this.remoteAgentId,
    required this.client,
    this.refresh,
  });

  final String peerId;
  final String remoteAgentId;
  final HubFoldedSessions client;
  final Future<void> Function(String, String)? refresh;

  @override
  State<_WithExpandedState> createState() => _WithExpandedStateState();
}

class _WithExpandedStateState extends State<_WithExpandedState> {
  SessionFolderSummary? _expanded;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: AgentSessionFolders(
            peerId: widget.peerId,
            remoteAgentId: widget.remoteAgentId,
            client: widget.client,
            refresh: widget.refresh,
            expandedKind: _expanded?.kind,
            onToggle: (summary) => setState(() {
              _expanded = _expanded?.kind == summary.kind ? null : summary;
            }),
          ),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('tapping a folder expands it in place, no new page',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: _WithExpandedState(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: _hostWithItems(bus),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('群聊 · 6'), findsOneWidget);
    // 收着的时候组里的会话不出现。
    expect(find.text('周会'), findsNothing);

    await tester.tap(find.text('群聊 · 6'));
    await tester.pumpAndSettle();
    expect(find.text('周会'), findsOneWidget);
    // 就地展开：没有推新页面（新页面会带自己的 AppBar）。
    expect(find.byType(AppBar), findsNothing);
    // 展开后那一行折叠组固定在列表上方，会话行在它下面；列表里不再重复画
    // 这一组。
    expect(
      tester.getRect(find.text('周会')).top,
      greaterThan(tester.getRect(find.text('群聊 · 6')).top),
    );

    // 点固定那一行收起 —— 不用滑回最顶部。
    await tester.tap(find.text('群聊 · 6'));
    await tester.pumpAndSettle();
    expect(find.text('周会'), findsNothing);
    await bus.close();
  });

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
            if (frame['type'] == 'agent_group_view_req') {
              bus.add(PeerControlEvent(peerId: peerId, data: {
                'type': 'agent_group_view_resp',
                'agent_id': 'a1',
                'group_id': 'g1',
                'session_id': 's1',
                'read_only': true,
                'total': 1,
                'messages': [
                  {
                    'role': 'agent',
                    'content': '我在群里说的话',
                    'message_id': 'm1',
                    'created_at': '2026-10-31T00:00:00.000Z',
                  }
                ],
              }));
              return true;
            }
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
        body: _WithExpandedState(
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('群里的话'));
    // 等路由动画走完：转场途中按钮还在屏幕外面，点不到。
    await tester.pumpAndSettle();
    await tester.tap(find.text('分叉到私聊'));
    await tester.pumpAndSettle();

    expect(forkAsked, 1);

    // 分叉之后立刻对齐一次主机名单：新私聊不用等下一次同步才出现。
    expect(refreshed, ['p1|a1']);
    // 折叠组也顺手重刷了。
    expect(summariesAsked, 2);
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('A7-9: 折叠会话用 fromAgent，而不是抽屉的 agent', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final client = HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        final id = frame['request_id'];
        if (frame['folder'] != null) {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_sessions_resp',
            'request_id': id,
            'agent_id': 'a1',
            'folder': frame['folder'],
            'sessions': [
              {
                'session_id': 'flow_deadbe12_impl',
                'title': '节点会话',
                'updated_at': 1,
                'origin': {
                  'kind': 'flow',
                  'run_id': 'deadbe12',
                  'node_key': 'impl',
                  'from_agent': 'agent-node',
                },
              },
            ],
          }));
          return true;
        }
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_resp',
          'request_id': id,
          'agent_id': 'a1',
          'sessions': [],
          'folders': [
            {'kind': 'flow', 'count': 1, 'latest_title': '最新一条'},
          ],
        }));
        return true;
      },
    );
    final opened = <({String channelId, String? agentId})>[];
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    addTearDown(() => debugOpenFlowSessionChannel = null);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: _WithExpandedState(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: client,
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('工作流 · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('节点会话'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    expect(opened.single.agentId, 'agent-node',
        reason: '多 agent 流程里 fromAgent 才是该节点的 agent');
    await bus.close();
  });

  testWidgets('A9-3: delegated 条目用抽屉 agent，而不是 from_agent 发起方', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(Map<String, dynamic>.from(frame));
        if (frame['type'] == 'agent_session_fork_req') {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_session_fork_resp',
            'request_id': frame['request_id'],
            'ok': true,
            'session_id': 'forked-r9',
          }));
          return true;
        }
        if (frame['folder'] != null) {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_sessions_resp',
            'request_id': frame['request_id'],
            'agent_id': 'a1',
            'folder': frame['folder'],
            'sessions': [
              {
                'session_id': 'session-r9-delegated',
                'title': '别的 Agent 发起的会话',
                'updated_at': 1,
                'origin': {
                  'kind': 'delegated',
                  // 主机把发起方硬编码成惜宝 id；它不是这个会话的归属 agent。
                  'from_agent': 'she-builtin-agent-001',
                },
              },
            ],
          }));
          return true;
        }
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_resp',
          'request_id': frame['request_id'],
          'agent_id': 'a1',
          'sessions': [],
          'folders': [
            {'kind': 'delegated', 'count': 1, 'latest_title': '转交给我的'},
          ],
        }));
        return true;
      },
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: _WithExpandedState(
          peerId: 'p1',
          remoteAgentId: 'a1',
          client: client,
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.textContaining('转交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('别的 Agent 发起的会话'));
    // 历史页有加载中的 spinner，pumpAndSettle 不会收敛；用有界 pump。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final history = tester.widget<SessionHistoryScreen>(
      find.byType(SessionHistoryScreen),
    );
    // 会话历史 / 分叉请求里的 agent 就是打开历史页用的归属 agent。
    await history.fork!();
    final fork = sent.firstWhere(
      (frame) => frame['type'] == 'agent_session_fork_req',
    );
    expect(fork['agent_id'], 'a1',
        reason: 'delegated/history 条目必须用抽屉当前选中的 agent');
    expect(fork['agent_id'], isNot('she-builtin-agent-001'));
    // flow 分支仍用 fromAgent，由上面的 A7-9 用例钉住。
    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
