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
}
