import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/widgets/chat/agent_session_folders.dart';
import 'package:shepaw/widgets/session_folders.dart';

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

/// 真实用法的外层：展开态由它持有，上方固定那一行折叠组（点一下收起）。
///
/// [AgentSessionFolders] 自己不再保存展开态（没有 [AgentSessionFolders.onToggle]
/// 就点不开），所以这两个用例按列表里的真实结构搭一层。
class _WithExpandedRow extends StatefulWidget {
  const _WithExpandedRow({
    required this.peerId,
    required this.remoteAgentId,
    required this.client,
    this.onForked,
    this.refresh,
  });

  final String peerId;
  final String remoteAgentId;
  final HubFoldedSessions client;
  final void Function(String sessionId)? onForked;
  final Future<void> Function(String, String)? refresh;

  @override
  State<_WithExpandedRow> createState() => _WithExpandedRowState();
}

class _WithExpandedRowState extends State<_WithExpandedRow> {
  SessionFolderSummary? _expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (_expanded != null)
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: SessionFolderTile(
              summary: _expanded!,
              expanded: true,
              onTap: () => setState(() => _expanded = null),
            ),
          ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: AgentSessionFolders(
                  peerId: widget.peerId,
                  remoteAgentId: widget.remoteAgentId,
                  client: widget.client,
                  onForked: widget.onForked,
                  refresh: widget.refresh,
                  expandedKind: _expanded?.kind,
                  onToggle: (summary) => setState(() {
                    _expanded =
                        _expanded?.kind == summary.kind ? null : summary;
                  }),
                ),
              ),
            ],
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
        body: _WithExpandedRow(
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
        body: _WithExpandedRow(
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
}
