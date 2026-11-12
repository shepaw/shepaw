import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/models/flow_node_progress.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/widgets/flow/flow_runs_pane.dart';

/// 执行详情三条修复的模型 / UI 回归：
/// ① 初始输入原文能看见；② 列表行直接写失败原因；③ 终态事件自带原因时
/// 不必等详情重拉（重拉失败也留得住）。
const _tree = [
  {'key': 'impl', 'id': 'impl', 'kind': 'task', 'status': 'done'},
];

Map<String, dynamic> _runResponse({
  String status = 'failed',
  Map<String, dynamic>? inputs,
}) =>
    {
      'type': 'flow_run_get_resp',
      'success': true,
      'run_id': 'r1',
      'status': status,
      'tasks_used': 1,
      'tree': _tree,
      if (inputs != null) 'inputs': inputs,
    };

Widget _app(HubFlow client) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: client),
    );

Widget _runsApp(HubFlow client) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FlowRunsPane(
          client: client,
          peerId: 'p1',
          scope: '',
          name: 'dev',
          executionHistory: true,
          onOpenRun: (_, __) {},
        ),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  group('初始输入', () {
    test('详情模型解析 inputs，并在状态更新中保留', () {
      final view = FlowRunView.fromResponse(_runResponse(inputs: {
        'goal': '写一封欢迎邮件\n第二段',
        'count': 3,
      }));
      expect(view, isNotNull);
      expect(view!.inputs['goal'], '写一封欢迎邮件\n第二段');
      expect(view.inputs['count'], 3);
      expect(view.withNodeStatus('impl', FlowNodeStatus.done, 1).inputs,
          view.inputs);
      expect(view.withRunStatus(FlowRunStatus.failed).inputs, view.inputs);
    });

    test('inputs 不是对象时按空处理', () {
      final view = FlowRunView.fromResponse(
          {..._runResponse(), 'inputs': '不是对象'});
      expect(view, isNotNull);
      expect(view!.inputs, isEmpty);
    });

    testWidgets('执行详情显示开跑时填的初始输入原文', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      final client = HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          if (frame['type'] == 'flow_run_get_req') {
            bus.add(PeerControlEvent(
              peerId: peerId,
              data: {
                ..._runResponse(inputs: {
                  'goal': '把登录页的验证码补上',
                  'extra': {'nested': true},
                }),
                'request_id': frame['request_id'],
              },
            ));
          }
          return true;
        },
      );
      await tester.pumpWidget(_app(client));
      await _settle(tester);
      expect(find.byKey(const ValueKey('run-inputs-card')), findsOneWidget);
      expect(find.text('goal'), findsOneWidget);
      expect(find.text('把登录页的验证码补上'), findsOneWidget);
      // 非字符串值也不丢，转成可读 JSON。
      expect(find.textContaining('nested'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });

    testWidgets('老主机不下发 inputs 就不画空卡', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      final client = HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          if (frame['type'] == 'flow_run_get_req') {
            bus.add(PeerControlEvent(
              peerId: peerId,
              data: {
                ..._runResponse(),
                'request_id': frame['request_id'],
              },
            ));
          }
          return true;
        },
      );
      await tester.pumpWidget(_app(client));
      await _settle(tester);
      expect(find.byKey(const ValueKey('run-inputs-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });
  });

  group('节点详情', () {
    const tree = [
      {
        'key': 'impl',
        'id': 'impl',
        'kind': 'task',
        'status': 'done',
        'text': '## 结果\n\n- 改了 **登录页**\n\n```\ncargo test\n```',
        'session_id': 'flow_deadbe12_impl',
        'agent_id': 'agent-7',
      },
    ];

    HubFlow client(
      StreamController<PeerControlEvent> bus,
      List<Map<String, dynamic>> progressRequests, {
      bool progressAnswers = true,
    }) =>
        HubFlow(
          events: bus.stream,
          send: (peerId, frame) async {
            if (frame['type'] == 'flow_run_get_req') {
              bus.add(PeerControlEvent(peerId: peerId, data: {
                'type': 'flow_run_get_resp',
                'request_id': frame['request_id'],
                'success': true,
                'run_id': 'r1',
                'status': 'succeeded',
                'tasks_used': 1,
                'tree': tree,
              }));
            } else if (frame['type'] == 'flow_node_progress_req') {
              progressRequests.add(Map<String, dynamic>.from(frame));
              if (!progressAnswers) return true;
              bus.add(PeerControlEvent(peerId: peerId, data: {
                'type': 'flow_node_progress_resp',
                'request_id': frame['request_id'],
                'success': true,
                'run_id': 'r1',
                'node': frame['node'],
                'progress_omitted': 2,
                'progress': [
                  {
                    'kind': 'thought',
                    'title': '思考',
                    'content': '先看看 **登录页** 的表单',
                  },
                  {
                    'kind': 'tool',
                    'title': 'Bash',
                    'summary': 'cargo test -p shepaw-api',
                    'content': 'test result: ok. 5 passed',
                    'status': 'completed',
                  },
                ],
              }));
            }
            return true;
          },
        );

    Future<void> openImpl(WidgetTester tester, HubFlow hub) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(hub));
      await _settle(tester);
      await tester.tap(find.text('impl').first);
      await _settle(tester);
    }

    testWidgets('输出按 Markdown 渲染；思考与工具调用默认折叠，点开才看到正文',
        (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      await openImpl(tester, client(bus, requests));

      final pane = find.byKey(const ValueKey('flow-node-detail-pane'));
      expect(pane, findsOneWidget);
      // Markdown：标题 / 加粗按段落渲染，原始的 `##`、`**` 不再出现。
      expect(find.byKey(const ValueKey('node-text-impl')), findsOneWidget);
      expect(find.descendant(of: pane, matching: find.textContaining('## 结果')),
          findsNothing);
      expect(find.descendant(of: pane, matching: find.textContaining('结果')),
          findsWidgets);

      // 只为这个节点请求一次步骤。
      expect(requests, hasLength(1));
      expect(requests.single['run_id'], 'r1');
      expect(requests.single['node'], 'impl');

      // 折叠区在，但正文没展开。
      expect(find.byKey(const ValueKey('node-progress')), findsOneWidget);
      expect(find.text('思考与工具调用'), findsOneWidget);
      expect(find.text('1 段思考 · 1 次工具调用'), findsOneWidget);
      expect(find.text('Bash'), findsNothing);
      expect(find.textContaining('test result'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('node-progress-tile')));
      await _settle(tester);
      expect(find.text('更早的 2 段步骤没有保留'), findsOneWidget);
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('cargo test -p shepaw-api'), findsOneWidget);
      // 每一块也各自折叠。
      expect(find.textContaining('test result'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('node-progress-block-1')));
      await _settle(tester);
      expect(find.textContaining('test result: ok. 5 passed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('node-progress-block-0')));
      await _settle(tester);
      expect(find.textContaining('登录页'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('老主机不应答步骤请求时不画折叠区，输出照常显示', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      final hub = client(bus, requests, progressAnswers: false);
      await openImpl(tester, hub);
      expect(find.byKey(const ValueKey('node-progress-loading')), findsOneWidget);
      // 等过请求超时。
      await tester.pump(const Duration(seconds: 20));
      await _settle(tester);
      expect(find.byKey(const ValueKey('node-progress-loading')), findsNothing);
      expect(find.byKey(const ValueKey('node-progress')), findsNothing);
      expect(find.byKey(const ValueKey('node-text-impl')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('步骤响应解析：空块丢掉，失败按 null', () {
      final parsed = FlowNodeProgress.fromResponse({
        'success': true,
        'progress': [
          {'kind': 'thought', 'title': '', 'content': '  '},
          {'kind': 'tool', 'title': 'Read', 'content': 'x', 'status': 'failed'},
          '不是对象',
        ],
      });
      expect(parsed!.blocks, hasLength(1));
      expect(parsed.blocks.single.failed, isTrue);
      expect(parsed.toolCount, 1);
      expect(FlowNodeProgress.fromResponse({'success': false}), isNull);
    });

    test('步骤帧走控制通道', () {
      expect(PeerConnection.isControlFrameType('flow_node_progress_resp'),
          isTrue);
      expect(HubFlow.nodeProgressFrame('r1', 'build#2/impl'), {
        'type': 'flow_node_progress_req',
        'run_id': 'r1',
        'node': 'build#2/impl',
      });
    });
  });

  group('失败原因', () {
    test('终态事件从 error / outcome.Failed.error 解出原因', () {
      final flat = FlowEvent.parse('flow.run.changed', {
        'run_id': 'r1',
        'status': 'failed',
        'error': '磁盘满了',
      });
      expect(flat?.error, '磁盘满了');

      final outcome = FlowEvent.parse('flow.run.changed', {
        'run_id': 'r1',
        'status': 'failed',
        'outcome': {
          'Failed': {'error': '引擎超时'},
        },
      });
      expect(outcome?.error, '引擎超时');

      final plain = FlowEvent.parse('flow.run.changed', {
        'run_id': 'r1',
        'status': 'cancelled',
      });
      expect(plain?.error, isNull);
    });

    test('终态事件自带原因时不丢，运行中带 error 也不冒充失败原因', () {
      final running = FlowRunView.fromResponse({
        ..._runResponse(status: 'running'),
        'error': '超出 max_tasks 上限',
      })!;
      expect(running.withRunStatus(FlowRunStatus.running,
          eventError: '运行中告警').error, '超出 max_tasks 上限');
      expect(running.withRunStatus(FlowRunStatus.failed).error, isNull,
          reason: '没有权威原因时仍要清掉旧告警');
      expect(
          running
              .withRunStatus(FlowRunStatus.failed, eventError: '真正的原因')
              .error,
          '真正的原因');
    });

    testWidgets('状态帧带原因时立即显示，详情重拉失败也留得住', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      var requests = 0;
      final client = HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          if (frame['type'] != 'flow_run_get_req') return true;
          requests += 1;
          if (requests > 1) return false; // 终态后的重拉连不上
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              ..._runResponse(status: 'running'),
              'request_id': frame['request_id'],
            },
          ));
          return true;
        },
      );
      await tester.pumpWidget(_app(client));
      await _settle(tester);
      bus.add(PeerControlEvent(
        peerId: 'p1',
        data: {
          'type': 'flow.run.changed',
          'run_id': 'r1',
          'status': 'failed',
          'outcome': {
            'Failed': {'error': '引擎超时：30 分钟没有返回'},
          },
        },
      ));
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byKey(const ValueKey('run-error-card')), findsOneWidget);
      expect(find.text('引擎超时：30 分钟没有返回'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('引擎超时：30 分钟没有返回'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });

    test('列表行解析失败原因', () {
      final runs = FlowRunSummary.listFromResponse({
        'success': true,
        'runs': [
          {'run_id': 'r1', 'flow': 'dev', 'status': 'failed', 'error': '磁盘满了'},
          {'run_id': 'r2', 'flow': 'dev', 'status': 'failed', 'error': '  '},
          {'run_id': 'r3', 'flow': 'dev', 'status': 'failed'},
        ],
      });
      expect(runs[0].error, '磁盘满了');
      expect(runs[1].error, isNull);
      expect(runs[2].error, isNull);
    });

    testWidgets('执行历史列表行直接写失败原因', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      final client = HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          if (frame['type'] == 'flow_run_list_req') {
            bus.add(PeerControlEvent(
              peerId: peerId,
              data: {
                'type': 'flow_run_list_resp',
                'request_id': frame['request_id'],
                'success': true,
                'runs': [
                  {
                    'run_id': 'r1',
                    'flow': 'dev',
                    'status': 'failed',
                    'error': '工作流日志写入失败：磁盘满了',
                  },
                  {'run_id': 'r2', 'flow': 'dev', 'status': 'succeeded'},
                ],
              },
            ));
          }
          return true;
        },
      );
      await tester.pumpWidget(_runsApp(client));
      await _settle(tester);
      expect(find.byKey(const ValueKey('run-error-r1')), findsOneWidget);
      expect(find.textContaining('工作流日志写入失败：磁盘满了'), findsOneWidget);
      expect(find.byKey(const ValueKey('run-error-r2')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });
  });
}
