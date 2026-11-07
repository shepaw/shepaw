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

SessionSearchHit _flowHitWithoutAgent(
  String sessionId, {
  String fromAgent = '',
}) =>
    SessionSearchHit(
      agentId: '',
      sessionId: sessionId,
      title: '修 bug · impl',
      source: 'hub',
      origin: SessionOrigin(
        kind: 'flow',
        runId: 'deadbe12',
        fromAgent: fromAgent,
      ),
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

  test('A2-1: 参与条目 part-flow-… 不是会话，不能拼成 psess_ 频道', () {
    // 折叠组 / 搜索把参与成员列成 `part-flow-<run>-<node>`。
    expect(flowFoldedSessionId('part-flow-r1-build'), isNull);
    // 即便里面已经带了 flow_ 字样，前缀仍然说明它是参与条目。
    expect(flowFoldedSessionId('part-flow_deadbe12_impl'), isNull);
    // 真会话 id 仍照常通行。
    expect(flowFoldedSessionId('flow_deadbe12_impl'), 'flow_deadbe12_impl');
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

  testWidgets('A10-8: 无 agent 的搜索命中不打开空壳频道', (tester) async {
    final opened = <({String channelId, String? agentId})>[];
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    var resolved = 0;
    debugResolveFlowSearchHitAgent = ({
      required String peerId,
      required String runId,
      required String sessionId,
    }) async {
      resolved++;
      return null;
    };
    addTearDown(() {
      debugOpenFlowSessionChannel = null;
      debugResolveFlowSearchHitAgent = null;
    });

    final hit = _flowHitWithoutAgent('flow_deadbe12_impl');
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => openSessionSearchHit(context, peerId: 'p1', hit: hit),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(resolved, 1, reason: '缺 agent 时要先尝试解析 / 重拉');
    expect(opened, isEmpty, reason: '解析不出 agent 绝不能以空 agentId 建频道');
    expect(find.text('正在准备会话，请稍后再点'), findsOneWidget);
  });

  testWidgets('A10-8: 运行树解析到 agent 后才打开会话', (tester) async {
    final opened = <({String channelId, String? agentId})>[];
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    debugResolveFlowSearchHitAgent = ({
      required String peerId,
      required String runId,
      required String sessionId,
    }) async {
      expect(peerId, 'p1');
      expect(runId, 'deadbe12');
      expect(sessionId, 'flow_deadbe12_impl');
      return 'agent-from-tree';
    };
    addTearDown(() {
      debugOpenFlowSessionChannel = null;
      debugResolveFlowSearchHitAgent = null;
    });

    final hit = _flowHitWithoutAgent('flow_deadbe12_impl');
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => openSessionSearchHit(context, peerId: 'p1', hit: hit),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(opened, hasLength(1));
    expect(opened.single.channelId, 'psess_flow_deadbe12_impl');
    expect(opened.single.agentId, 'agent-from-tree');
  });

  testWidgets('A10-8: flow 命中的 origin.from_agent 就是节点 agent', (tester) async {
    final opened = <({String channelId, String? agentId})>[];
    debugOpenFlowSessionChannel = (channelId, agentId) async {
      opened.add((channelId: channelId, agentId: agentId));
    };
    debugResolveFlowSearchHitAgent = ({
      required String peerId,
      required String runId,
      required String sessionId,
    }) async {
      fail('已有会话归属时不该再重拉运行树');
    };
    addTearDown(() {
      debugOpenFlowSessionChannel = null;
      debugResolveFlowSearchHitAgent = null;
    });

    final hit = _flowHitWithoutAgent(
      'flow_deadbe12_impl',
      fromAgent: 'agent-node',
    );
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => openSessionSearchHit(context, peerId: 'p1', hit: hit),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.agentId, 'agent-node');
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

  testWidgets('A6-4: 弹层期间行被卸载，点「查看运行」不抛异常', (tester) async {
    var showRow = true;
    late StateSetter setRow;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, setState) {
        setRow = setState;
        return showRow
            ? Builder(
                builder: (rowContext) => TextButton(
                  onPressed: () => showFlowRunActions(
                    rowContext,
                    peerId: 'p1',
                    runId: 'deadbe12',
                    title: '修 bug',
                  ),
                  child: const Text('menu'),
                ),
              )
            : const Text('row gone');
      },
    )));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    expect(find.text('查看运行'), findsOneWidget);

    // 列表刷新把这一行拆掉，但底部弹层还开着。
    setRow(() => showRow = false);
    await tester.pump();
    expect(find.text('row gone'), findsOneWidget);

    await tester.tap(find.text('查看运行'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
