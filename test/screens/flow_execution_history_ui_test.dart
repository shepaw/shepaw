import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/widgets/flow/flow_runs_pane.dart';

const _runs = [
  {
    'run_id': 'run_goal',
    'flow': 'dev',
    'status': 'succeeded',
    'started_ms': 1700000000000,
    'input_title': '修好登录页',
    'revision': 6,
  },
  {
    'run_id': 'run_old',
    'flow': 'dev',
    'status': 'failed',
    'started_ms': 1600000000000,
    'revision': 3,
  },
  {
    'run_id': 'run_live',
    'flow': 'dev',
    'status': 'running',
    'started_ms': 1800000000000,
    'input_title': '正在改设置',
  },
];

HubFlow _listClient(StreamController<PeerControlEvent> bus) => HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_list_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_list_resp',
              'request_id': frame['request_id'],
              'success': true,
              'runs': _runs,
            },
          ));
        }
        return true;
      },
    );

Widget _runsApp(HubFlow client, {bool executionHistory = true}) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FlowRunsPane(
          client: client,
          peerId: 'p1',
          scope: '',
          name: 'dev',
          executionHistory: executionHistory,
          onOpenRun: (_, __) {},
        ),
      ),
    );

const _tree = [
  {
    'key': 'impl',
    'id': 'impl',
    'kind': 'task',
    'status': 'done',
    'text': '写完了',
    'session_id': 'flow_deadbe12_impl',
    'agent_id': 'agent-7',
  },
  {
    'key': 'review',
    'id': 'review',
    'kind': 'task',
    'status': 'pending',
  },
];

HubFlow _runClient(StreamController<PeerControlEvent> bus) => HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_get_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'tasks_used': 1,
              'tree': _tree,
            },
          ));
        }
        return true;
      },
    );

Widget _runApp(HubFlow client) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: client),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('执行历史能按标题和状态搜索，并按分组筛选', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    await tester.pumpWidget(_runsApp(_listClient(bus)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('executions-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_old')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_live')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('executions-search')), '登录');
    await tester.pump();
    expect(find.byKey(const ValueKey('run-run_goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_old')), findsNothing);
    expect(find.byKey(const ValueKey('run-run_live')), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('executions-search')), '失败');
    await tester.pump();
    expect(find.byKey(const ValueKey('run-run_old')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_goal')), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('executions-search')), '第 6 版');
    await tester.pump();
    expect(find.byKey(const ValueKey('run-run_goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_old')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('executions-search-clear')));
    await tester.pump();
    expect(find.byKey(const ValueKey('run-run_live')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('executions-filter-running')));
    await tester.pump();
    expect(find.byKey(const ValueKey('run-run_live')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_goal')), findsNothing);
    expect(find.byKey(const ValueKey('run-run_old')), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('executions-search')), '不存在');
    await tester.pump();
    expect(find.byKey(const ValueKey('executions-no-match')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-run_live')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('executions-filter-all')));
    await tester.pump();
    expect(find.byKey(const ValueKey('executions-no-match')), findsOneWidget);
  });

  testWidgets('运行记录栏不带执行历史的搜索', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    await tester
        .pumpWidget(_runsApp(_listClient(bus), executionHistory: false));
    await _settle(tester);

    expect(find.byKey(const ValueKey('executions-search')), findsNothing);
    expect(find.byKey(const ValueKey('executions-filter-all')), findsNothing);
    expect(find.byKey(const ValueKey('run-run_goal')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('宽屏点组件在右侧栏打开，树还在', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    await tester.pumpWidget(_runApp(_runClient(bus)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsNothing);
    await tester.tap(find.text('impl'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    // 卡片上有一行预览，右侧栏里是同一段可选择的全文。
    expect(find.widgetWithText(SelectableText, '写完了'), findsOneWidget);
    expect(find.byKey(const ValueKey('node-view-session')), findsOneWidget);
    // 组件树没有被弹层盖住。
    expect(
        find.byKey(const ValueKey('flow-node-session-impl')), findsOneWidget);
    expect(find.text('review'), findsOneWidget);

    await tester.tap(find.text('review'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-view-session')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('flow-node-detail-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsNothing);
    expect(find.text('impl'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('窄屏点组件仍是底部弹层', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    await tester.pumpWidget(_runApp(_runClient(bus)));
    await _settle(tester);

    await tester.tap(find.text('impl'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsNothing);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('node-view-session')), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '写完了'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点循环时侧边栏按轮次折叠，能看到之前每一轮', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        if (frame['type'] == 'flow_run_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_get_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              'status': 'succeeded',
              'tasks_used': 2,
              'tree': [
                {
                  'key': 'again#1',
                  'id': 'again',
                  'kind': 'loop',
                  'status': 'done',
                  'rounds': 2,
                  'children': [
                    {
                      'key': 'again#1/work',
                      'id': 'work',
                      'kind': 'task',
                      'status': 'done',
                      'text': '第二轮',
                    },
                  ],
                  'iterations': [
                    {
                      'iter': 0,
                      'status': 'done',
                      'children': [
                        {
                          'key': 'again#0/work',
                          'id': 'work',
                          'kind': 'task',
                          'status': 'done',
                          'text': '第一轮',
                        },
                      ],
                    },
                    {
                      'iter': 1,
                      'status': 'done',
                      'children': [
                        {
                          'key': 'again#1/work',
                          'id': 'work',
                          'kind': 'task',
                          'status': 'done',
                          'text': '第二轮',
                          'session_id': 'flow_deadbe12_work',
                          'agent_id': 'agent-7',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ));
        }
        return true;
      },
    );
    await tester.pumpWidget(_runApp(client));
    await _settle(tester);

    expect(
        find.byKey(const ValueKey('loop-round-count-again')), findsOneWidget);
    await tester.tap(find.text('循环 · 第 2 轮'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsOneWidget);
    expect(find.text('每一轮'), findsOneWidget);
    expect(find.byKey(const ValueKey('loop-round-again#1-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('loop-round-again#1-1')), findsOneWidget);
    // 最近一轮默认展开，能看到这一轮的产出和会话入口。
    expect(find.byKey(const ValueKey('loop-round-text-again#1/work')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('loop-round-session-again#1/work')),
        findsOneWidget);
    // 更早的一轮收着，点开才看到当时的结果。
    expect(find.byKey(const ValueKey('loop-round-text-again#0/work')),
        findsNothing);
    await tester.tap(find.text('第 1 轮'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('loop-round-text-again#0/work')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
