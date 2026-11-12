import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/models/flow_node_progress.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/widgets/flow/flow_node_output.dart';
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
      final view =
          FlowRunView.fromResponse({..._runResponse(), 'inputs': '不是对象'});
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
      Map<String, dynamic>? node,
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
                'tree': [
                  {...tree.single, ...?node}
                ],
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

    Future<void> openImpl(WidgetTester tester, HubFlow hub,
        {Size size = const Size(1200, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(hub));
      await _settle(tester);
      await tester.tap(find.text('impl').first);
      await _settle(tester);
    }

    testWidgets('输出按 Markdown 渲染；思考与工具调用默认折叠，点开才看到正文', (tester) async {
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

      // 折叠区标题在，但没点开之前不发请求、不转圈。
      expect(find.byKey(const ValueKey('node-progress')), findsOneWidget);
      expect(find.text('思考与工具调用'), findsOneWidget);
      expect(find.byKey(const ValueKey('node-progress-loading')), findsNothing);
      expect(requests, isEmpty);
      expect(find.text('Bash'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('node-progress-tile')));
      await _settle(tester);
      // 点开才为这个节点请求一次步骤，取到后标题下写上计数。
      expect(requests, hasLength(1));
      expect(requests.single['run_id'], 'r1');
      expect(requests.single['node'], 'impl');
      expect(find.text('1 段思考 · 1 次工具调用'), findsOneWidget);
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

    testWidgets('老主机不应答：打开节点不转圈，点开后超时写「没有记录」', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      final hub = client(bus, requests, progressAnswers: false);
      await openImpl(tester, hub);
      expect(find.byKey(const ValueKey('node-progress-loading')), findsNothing);
      expect(find.byKey(const ValueKey('node-progress')), findsOneWidget);
      expect(requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('node-progress-tile')));
      await _settle(tester);
      expect(requests, hasLength(1));
      expect(
          find.byKey(const ValueKey('node-progress-loading')), findsOneWidget);
      // 等过请求超时。
      await tester.pump(const Duration(seconds: 20));
      await _settle(tester);
      expect(find.byKey(const ValueKey('node-progress-loading')), findsNothing);
      expect(find.byKey(const ValueKey('node-progress-empty')), findsOneWidget);
      expect(find.text('没有记录到思考或工具调用'), findsOneWidget);
      expect(find.byKey(const ValueKey('node-text-impl')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('请求在途时关掉面板：放弃等待，不留超时计时器', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      final hub = client(bus, requests, progressAnswers: false);
      await openImpl(tester, hub);
      await tester.tap(find.byKey(const ValueKey('node-progress-tile')));
      await _settle(tester);
      expect(requests, hasLength(1));
      expect(
          find.byKey(const ValueKey('node-progress-loading')), findsOneWidget);
      // 关掉侧栏：面板销毁 → cancel 完成 → 10 秒计时器随即释放。
      await tester.tap(find.byKey(const ValueKey('flow-node-detail-close')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('node-progress')), findsNothing);
      // 测试结束时若还挂着计时器，testWidgets 会直接判失败。
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nodeProgress：cancel 完成即返回 null，不再等超时', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final hub = HubFlow(events: bus.stream, send: (_, __) async => true);
      final cancel = Completer<void>();
      var done = false;
      FlowNodeProgress? result = const FlowNodeProgress();
      unawaited(hub
          .nodeProgress('p1', 'r1', 'impl', cancel: cancel.future)
          .then((value) {
        result = value;
        done = true;
      }));
      await tester.pump();
      expect(done, isFalse);
      cancel.complete();
      await tester.pump();
      expect(done, isTrue);
      expect(result, isNull);
    });

    testWidgets('状态 / 轮次变了：展开着立刻重取，折叠着等下次点开', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      final node = <String, dynamic>{};
      await openImpl(tester, client(bus, requests, node: node));
      // 点标题栏：展开后 tile 中心落在正文区。
      await tester.tap(find.text('思考与工具调用'));
      await _settle(tester);
      expect(requests, hasLength(1));

      void bump(int attempt) {
        node['attempt'] = attempt;
        bus.add(PeerControlEvent(peerId: 'p1', data: {
          'type': 'flow.node.changed',
          'run_id': 'r1',
          'node': 'impl',
          'status': 'done',
          'attempt': attempt,
        }));
      }

      bump(2);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(requests, hasLength(2), reason: '展开着，轮次变了马上重取');

      // 收起后再变：不发请求；再点开才取。
      await tester.tap(find.text('思考与工具调用'));
      await _settle(tester);
      bump(3);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(requests, hasLength(2));
      await tester.tap(find.text('思考与工具调用'));
      await _settle(tester);
      expect(requests, hasLength(3));
      // 同一轮次再点开不重复请求。
      await tester.tap(find.text('思考与工具调用'));
      await _settle(tester);
      await tester.tap(find.text('思考与工具调用'));
      await _settle(tester);
      expect(requests, hasLength(3));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('手机弹层跟着运行更新：轮次变了重取步骤', (tester) async {
      final bus = StreamController<PeerControlEvent>.broadcast();
      addTearDown(bus.close);
      final requests = <Map<String, dynamic>>[];
      final node = <String, dynamic>{};
      await openImpl(tester, client(bus, requests, node: node),
          size: const Size(400, 900));
      expect(find.byKey(const ValueKey('flow-node-detail-pane')), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('node-progress-tile')));
      await _settle(tester);
      expect(requests, hasLength(1));

      node['attempt'] = 2;
      bus.add(PeerControlEvent(peerId: 'p1', data: {
        'type': 'flow.node.changed',
        'run_id': 'r1',
        'node': 'impl',
        'status': 'done',
        'attempt': 2,
      }));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(requests, hasLength(2));
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
      expect(
          PeerConnection.isControlFrameType('flow_node_progress_resp'), isTrue);
      expect(HubFlow.nodeProgressFrame('r1', 'build#2/impl'), {
        'type': 'flow_node_progress_req',
        'run_id': 'r1',
        'node': 'build#2/impl',
      });
    });
  });

  group('节点输出链接', () {
    Widget markdown(String data) => MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: FlowMarkdown(data)),
        );

    Future<void> tapLink(WidgetTester tester, String label) async {
      await tester.tap(find.textContaining(label, findRichText: true).first);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('外部链接打不开时提示，不抛异常', (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(markdown('[打开文档](https://example.com/doc)'));
      await tapLink(tester, '打开文档');
      expect(tester.takeException(), isNull);
      expect(find.text('无法打开链接: https://example.com/doc'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('相对链接没有工作区根：直接提示打不开', (tester) async {
      await tester.pumpWidget(markdown('[说明](docs/readme.md)'));
      await tapLink(tester, '说明');
      expect(tester.takeException(), isNull);
      expect(find.text('无法打开链接: docs/readme.md'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
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
      expect(
          running
              .withRunStatus(FlowRunStatus.running, eventError: '运行中告警')
              .error,
          '超出 max_tasks 上限');
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
                  {
                    'run_id': 'r2',
                    'flow': 'dev',
                    'status': 'succeeded',
                    'error': '预算告警：不该显示',
                  },
                  {
                    'run_id': 'r3',
                    'flow': 'dev',
                    'status': 'cancelled',
                    'error': '用户手动取消',
                  },
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
      expect(find.textContaining('预算告警'), findsNothing);
      // 取消原因同样写在行上。
      expect(find.byKey(const ValueKey('run-error-r3')), findsOneWidget);
      expect(find.text('取消原因：用户手动取消'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await bus.close();
    });
  });
}
