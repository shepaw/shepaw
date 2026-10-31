import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/peer/services/hub_folded_sessions.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/widgets/chat/folded_session_items.dart';

void main() {
  groupViewTests();
  test('summary and folder frames ask for the folded view', () {
    expect(HubFoldedSessions.summaryFrame('a1', requestId: 'r'), {
      'type': 'agent_sessions_req',
      'request_id': 'r',
      'agent_id': 'a1',
      'view': 'folded',
    });
    expect(
        HubFoldedSessions.folderFrame('a1', SessionFolderKind.flow,
            cursor: '50', limit: 20, parentSession: 'ch-2', requestId: 'r'),
        {
          'type': 'agent_sessions_req',
          'request_id': 'r',
          'agent_id': 'a1',
          'view': 'folded',
          'folder': 'flow',
          'cursor': '50',
          'limit': 20,
          'parent_session': 'ch-2',
        });
  });

  test('summary rows decode, unknown kinds are skipped', () {
    final summary = FoldedSummary.fromResponse({
      'folders': [
        {'kind': 'group', 'count': 6, 'updated_at': 9, 'latest_title': '讨论'},
        {'kind': 'mystery', 'count': 1},
      ],
    })!;
    expect(summary.folders.single.kind, SessionFolderKind.group);
    expect(summary.folders.single.count, 6);
    expect(FoldedSummary.fromResponse({'sessions': []}), isNull);
  });

  test('a page decodes origins and the next cursor', () {
    final page = FoldedPage.fromResponse({
      'cursor': '50',
      'sessions': [
        {
          'session_id': 'part-flow-r1-build',
          'title': 'build',
          'updated_at': 5,
          'origin': {'kind': 'flow', 'run_id': 'r1', 'node_key': 'build'},
        },
      ],
    })!;
    expect(page.cursor, '50');
    expect(page.items.single.isFlow, isTrue);
    expect(page.items.single.runId, 'r1');
    expect(FoldedPage.fromResponse({'cursor': ''})?.cursor, isNull);
  });

  testWidgets('the expanded folder pages through and forks into a private chat',
      (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        final id = frame['request_id'];
        if (frame['type'] == 'agent_session_fork_req') {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            'type': 'agent_session_fork_resp',
            'request_id': id,
            'ok': true,
            'session_id': 'new-1',
          }));
          return true;
        }
        final first = (frame['cursor'] ?? '') == '';
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_sessions_resp',
          'request_id': id,
          'agent_id': 'a1',
          'folder': 'flow',
          'cursor': first ? '1' : null,
          'sessions': [
            {
              'session_id': first ? 's1' : 's2',
              'title': first ? '第一个' : '第二个',
              'origin': {'kind': 'flow', 'run_id': 'r1', 'node_key': 'n'},
            },
          ],
        }));
        return true;
      },
    );
    String? forked;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SessionFolderItems(
            peerId: 'p1',
            agentId: 'a1',
            folder: SessionFolderKind.flow,
            client: client,
            onForked: (id) => forked = id,
          ),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('第一个'), findsOneWidget);
    expect(find.text('运行 r1'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('第二个'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(sent[1]['cursor'], '1');

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分叉到私聊'));
    await tester.pumpAndSettle();
    expect(forked, 'new-1');
    await bus.close();
  });
}

void groupViewTests() {
  test('group view pages decode and pair by agent/group/session', () async {
    final page = GroupViewPage.fromResponse({
      'agent_id': 'a1',
      'cursor': 'v1.2.x',
      'has_more': true,
      'total': 5,
      'messages': [
        {
          'message_id': 'm1',
          'role': 'assistant',
          'content': '我说的',
          'created_at': 't'
        },
      ],
    })!;
    expect(page.hasMore, isTrue);
    expect(page.messages.single.content, '我说的');
    expect(
        GroupViewPage.fromResponse({'error': 'missing_params', 'messages': []}),
        isNull);

    final bus = StreamController<PeerControlEvent>.broadcast();
    final sent = <Map<String, dynamic>>[];
    final client = HubFoldedSessions(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        // 别的群会话的回包先到，不能被认领。
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_group_view_resp',
          'agent_id': 'a1',
          'group_id': 'g-other',
          'session_id': 's1',
          'messages': [],
        }));
        bus.add(PeerControlEvent(peerId: peerId, data: {
          'type': 'agent_group_view_resp',
          'agent_id': 'a1',
          'group_id': 'g1',
          'session_id': 's1',
          'total': 1,
          'messages': [
            {'message_id': 'm9', 'content': 'x'}
          ],
        }));
        return true;
      },
    );
    final got = await client.groupView('p1', 'a1', 'g1', 's1', cursor: 'c');
    expect(got!.messages.single.id, 'm9');
    expect(sent.single['cursor'], 'c');
    expect(sent.single.containsKey('request_id'), isFalse);
    await bus.close();
  });
}
