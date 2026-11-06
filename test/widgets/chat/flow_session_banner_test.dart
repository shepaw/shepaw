import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/widgets/chat/flow_session_banner.dart';

Message _message(Map<String, dynamic>? metadata, {String id = 'm1'}) =>
    Message.simple(
      id: id,
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
    expect(
        flowSessionOriginOf([
          _message({'flow': null}),
          _message(null)
        ]),
        isNull);
  });

  test('A3-8 消息列表没变时不再全量扫描', () {
    final cache = FlowSessionOriginCache();
    final messages = [
      _message({
        'flow': {
          'run_id': 'deadbe12-1234',
          'node_key': 'outer/impl',
        },
      }),
    ];
    expect(cache.resolve(messages)?.runId, 'deadbe12-1234');
    expect(cache.scanCount, 1);
    // 同一列表重复 resolve（页面重建）不再扫描。
    expect(cache.resolve(messages)?.runId, 'deadbe12-1234');
    expect(cache.resolve(messages)?.runId, 'deadbe12-1234');
    expect(cache.scanCount, 1);

    // 长度或最后一条 id 变了才重算。
    messages.add(_message(null));
    expect(cache.resolve(messages)?.runId, 'deadbe12-1234');
    expect(cache.scanCount, 2);
    messages[1] = _message(null, id: 'm2');
    expect(cache.resolve(messages)?.runId, 'deadbe12-1234');
    expect(cache.scanCount, 3);

    // 换频道（scope 变）也要重算，避免沿用上一个会话的横幅。
    expect(cache.resolve(messages, scope: 'other')?.runId, 'deadbe12-1234');
    expect(cache.scanCount, 4);
  });

  test('A6-9: 原地补 metadata.flow 后横幅出现，且不恢复每次全量扫描', () {
    final cache = FlowSessionOriginCache();
    final messages = [
      _message({'source': 'local'}),
      _message(null, id: 'm2'),
    ];
    expect(cache.resolve(messages), isNull);
    expect(cache.resolve(messages), isNull);
    expect(cache.scanCount, 1, reason: 'A3-8：普通重建不重扫');

    // 同长同 id，但给已有 prompt 原地加了 metadata.flow：签名变了。
    messages.first.metadata!['flow'] = {
      'run_id': 'run16',
      'node_key': 'seq/impl',
    };
    expect(cache.resolve(messages)?.runId, 'run16');
    expect(cache.scanCount, 2);
  });

  test('A6-9: 中间消息的 metadata 变更靠调用方 revision 失效', () {
    final cache = FlowSessionOriginCache();
    final messages = [
      _message(null, id: 'a'),
      _message({'source': 'local'}, id: 'b'),
      _message(null, id: 'c'),
    ];
    expect(cache.resolve(messages, metadataRevision: 1), isNull);
    expect(cache.scanCount, 1);

    messages[1].metadata!['flow'] = {'run_id': 'run-middle'};
    // 没换频道 / 没换列表时仍不重复扫描。
    expect(cache.resolve(messages, metadataRevision: 1), isNull);
    expect(cache.scanCount, 1);

    // DB 重载带回新 metadata，调用方把 revision 前移 → 重扫一次。
    expect(cache.resolve(messages, metadataRevision: 2)?.runId, 'run-middle');
    expect(cache.scanCount, 2);
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

  Widget bannerApp(FlowSessionOrigin origin) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: FlowSessionBanner(origin: origin)),
      );

  test('A7-7: origin 带上会话的 agent 行 / 消息里的来源 peer', () {
    final messages = [
      _message({
        'flow': {'run_id': 'r16', 'node_key': 'a/impl'},
        'source_peer_id': 'p1',
      }),
    ];
    final origin = flowSessionOriginOf(messages, agentRowId: 'agent-row-impl')!;
    expect(origin.runId, 'r16');
    expect(origin.sourceAgentId, 'agent-row-impl');
    expect(origin.peerId, 'p1');

    // agent 行换了（会话切换）必须重新扫描，别沿用上一条的 origin。
    final cache = FlowSessionOriginCache();
    expect(cache.resolve(messages, agentRowId: 'a')?.sourceAgentId, 'a');
    expect(cache.scanCount, 1);
    expect(cache.resolve(messages, agentRowId: 'b')?.sourceAgentId, 'b');
    expect(cache.scanCount, 2);
  });

  testWidgets('A7-7: 查看运行连到来源主机 p1，而不是当前 activeHost p2', (tester) async {
    final opened = <({String peerId, String runId})>[];
    debugFlowSourcePeerResolver = (rowId) async {
      expect(rowId, 'agent-row-impl');
      return 'p1';
    };
    debugFlowActiveHost = () async => 'p2';
    debugOpenFlowRun = (peerId, runId) async {
      opened.add((peerId: peerId, runId: runId));
    };
    addTearDown(() {
      debugFlowSourcePeerResolver = null;
      debugFlowActiveHost = null;
      debugOpenFlowRun = null;
    });

    final origin = flowSessionOriginOf([
      _message({
        'flow': {'run_id': 'r16', 'node_key': 'a/impl'},
      }),
    ], agentRowId: 'agent-row-impl')!;
    await tester.pumpWidget(bannerApp(origin));
    await tester.tap(find.byKey(const ValueKey('flow-session-view-run')));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.peerId, 'p1', reason: '不能用当前主机 p2 去查另一台主机发起的运行');
    expect(opened.single.runId, 'r16');
  });

  testWidgets('A7-7: 来源 peer 拿不到才退回 activeHost', (tester) async {
    final opened = <String>[];
    debugFlowSourcePeerResolver = (_) async => '';
    debugFlowActiveHost = () async => 'p2';
    debugOpenFlowRun = (peerId, _) async => opened.add(peerId);
    addTearDown(() {
      debugFlowSourcePeerResolver = null;
      debugFlowActiveHost = null;
      debugOpenFlowRun = null;
    });

    final origin = flowSessionOriginOf([
      _message({
        'flow': {'run_id': 'r16', 'node_key': 'a/impl'},
      }),
    ], agentRowId: 'agent-row-unknown')!;
    await tester.pumpWidget(bannerApp(origin));
    await tester.tap(find.byKey(const ValueKey('flow-session-view-run')));
    await tester.pump();
    expect(opened, ['p2']);
  });
}
