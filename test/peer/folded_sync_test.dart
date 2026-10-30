import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/session_history_screen.dart';

PeerControlEvent _resp(Map<String, dynamic> extra) => PeerControlEvent(
      peerId: 'p1',
      data: {
        'type': 'agent_sessions_resp',
        'agent_id': 'a1',
        'sessions': <Object>[],
        ...extra,
      },
    );

void main() {
  final svc = PeerAgentClientService.instance;

  tearDown(() => svc.debugMarkFolded('p1', 'a1', false));

  test('a reply with folders marks the host folded; a plain one clears it', () {
    expect(svc.isHostFolded('p1', 'a1'), isFalse);
    svc.debugHandleControl(_resp({'folders': <Object>[]}));
    expect(svc.isHostFolded('p1', 'a1'), isTrue);
    svc.debugHandleControl(_resp({}));
    expect(svc.isHostFolded('p1', 'a1'), isFalse);
  });

  test('folder pages (with request_id) never touch the sync state', () {
    svc.debugHandleControl(_resp({'folders': <Object>[]}));
    svc.debugHandleControl(_resp({'request_id': 'r', 'folder': 'ide'}));
    expect(svc.isHostFolded('p1', 'a1'), isTrue);
  });

  test('on a folded host, client sessions missing from the list are dropped',
      () {
    final local = [
      Channel.withMemberIds(
        id: 'psess_mine',
        name: 'mine',
        type: 'dm',
        memberIds: const ['u', 'l'],
        isPrivate: true,
      ),
      Channel.withMemberIds(
        id: 'psess_term',
        name: 'term',
        type: 'dm',
        memberIds: const ['u', 'l'],
        isPrivate: true,
        sessionOrigin: 'terminal',
      ),
    ];
    // 折叠主机：preserveClientSessions 被强制关掉，终端副本跟着清掉。
    final drop = peerChannelIdsAbsentFromHost(
      local: local,
      hostSessionIds: {'mine'},
      preserveClientSessions: false,
    );
    expect(drop, {'psess_term'});
  });

  testWidgets('the history page pages forward, shows an empty state and forks',
      (tester) async {
    final cursors = <String?>[];
    String? forked;
    await tester.pumpWidget(MaterialApp(
      home: SessionHistoryScreen(
        title: '终端会话',
        loadPage: (cursor) async {
          cursors.add(cursor);
          return cursor == null
              ? PeerHistoryPage(
                  messages: [PeerHistoryMessage(role: 'user', content: '你好')],
                  cursor: 'c1',
                  hasMore: true,
                  completed: true,
                )
              : PeerHistoryPage(
                  messages: [PeerHistoryMessage(role: 'agent', content: '在的')],
                  completed: true,
                );
        },
        fork: () async => (sessionId: 'new-1', error: null),
        onForked: (id) => forked = id,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('你好'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('在的'), findsOneWidget);
    expect(cursors, [null, 'c1']);
    await tester.tap(find.text('分叉到私聊'));
    await tester.pumpAndSettle();
    expect(forked, 'new-1');
  });

  testWidgets('a session with no host-side record says so', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SessionHistoryScreen(
        title: 't',
        loadPage: (_) async => PeerHistoryPage.empty,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('主机上没有这个会话可显示的记录'), findsOneWidget);
  });
}
