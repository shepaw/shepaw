import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/flow_session_banner.dart';

Message _message(Map<String, dynamic>? metadata) => Message.simple(
      id: 'm1',
      channelId: 'psess_flow_deadbe12_impl',
      senderId: 'user',
      senderName: '',
      content: '做这个任务',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      type: MessageType.text,
      metadata: metadata,
    );

void main() {
  test('P4: flow prompt metadata identifies the session origin', () {
    final origin = flowSessionOriginOf([
      _message(null),
      _message({
        'flow': {
          'run_id': 'deadbe12-1234',
          'node_key': 'outer/impl',
          'attempt': 1,
        },
      }),
    ])!;
    expect(origin.runId, 'deadbe12-1234');
    expect(origin.nodeKey, 'outer/impl');
    expect(origin.label, 'impl');
    expect(flowSessionOriginOf([_message({'flow': null}), _message(null)]),
        isNull);
  });

  testWidgets('P4: banner shows the node and a 查看运行 link', (tester) async {
    const origin = FlowSessionOrigin(runId: 'deadbe12', nodeKey: 'outer/impl');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: FlowSessionBanner(origin: origin)),
    ));
    expect(find.text('工作流 · 节点 impl'), findsOneWidget);
    expect(find.text('查看运行'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-session-view-run')), findsOneWidget);
  });
}
