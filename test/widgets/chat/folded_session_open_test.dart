import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/folded_sessions.dart';
import 'package:shepaw/peer/services/flow_session_open.dart';
import 'package:shepaw/widgets/chat/folded_session_open.dart';

SessionSearchHit _flowHit(String sessionId) => SessionSearchHit(
      agentId: 'agent-7',
      sessionId: sessionId,
      title: '修 bug · impl',
      source: 'hub',
      origin: const SessionOrigin(kind: 'flow', runId: 'deadbe12'),
      updatedAt: 1,
      readOnly: false,
    );

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  test('P4: only real host session ids become psess_ channels', () {
    expect(flowFoldedSessionId('flow_deadbe12_impl'), 'flow_deadbe12_impl');
    // 旧运行的引擎槽位 key / 群前缀拼不出真频道，点击要退回运行视图。
    expect(flowFoldedSessionId('flow:r1:impl'), isNull);
    expect(flowFoldedSessionId('group:g1:s1:flow_x'), isNull);
    expect(flowFoldedSessionId(''), isNull);
  });

  testWidgets('P4: tapping a flow search hit opens the node session',
      (tester) async {
    final opened = <({String channelId, String? agentId})>[];
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    addTearDown(() => debugOpenFlowSessionChannel = null);

    final hit = _flowHit('flow_deadbe12_impl');
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => openSessionSearchHit(context, peerId: 'p1', hit: hit),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    expect(opened.single.agentId, 'agent-7');
  });

  testWidgets('P4: long-press menu keeps a 查看运行 entry', (tester) async {
    final hit = _flowHit('flow_deadbe12_impl');
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => showFlowRunActions(
          context,
          peerId: 'p1',
          runId: hit.origin.runId,
          title: hit.title,
        ),
        child: const Text('menu'),
      ),
    )));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    expect(find.text('查看运行'), findsOneWidget);
  });
}
