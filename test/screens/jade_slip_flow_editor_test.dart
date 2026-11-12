import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_run_screen.dart';
import 'package:shepaw/screens/jade_slip_editor_screen.dart';
import 'package:shepaw/screens/jade_slip_screen.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/slip_scope_documents.dart';

import '../storage/memory_scope_transport.dart';
import '../storage/test_harness.dart';

/// 玉简绑定工作流的编辑 / 列表 / 运行页回归。
///
/// 玉简走内存 scope 传输（真实异步 IO），相关用例包在 [WidgetTester.runAsync]；
/// 模板选择器用 `debugJadeSlipTemplatePicker` 注入，不去连真实主机。
void main() {
  const self = 'aaaaaaaaaaaaaaaa';
  const binding = JadeSlipFlowBinding(
    scope: 'lib',
    name: '报告流程',
    revision: 3,
    inputs: {'goal': '写完周报'},
    bindings: {'coder': 'agent-7'},
    inputFrom: {'goal': 'slip'},
  );

  late JadeSlipFlowTemplatePicker defaultPicker;

  setUpAll(() async {
    await StorageTestHarness.init();
    defaultPicker = debugJadeSlipTemplatePicker;
  });

  setUp(() async {
    final docs = SlipScopeDocuments(
      store: PouchScopeStore(
        transport: MemoryScopeTransport(),
        pouchId: 'test-pouch',
      ),
      deviceId: self,
    );
    JadeSlipService.instance.debugDocuments = () => docs;
  });

  tearDown(() async {
    debugJadeSlipTemplatePicker = defaultPicker;
    JadeSlipService.instance.debugDocuments = null;
  });

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  Widget editor(String slipId) => Scaffold(
        body: JadeSlipEditorScreen(slipId: slipId, embedded: true),
      );

  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  Future<void> pumpEditor(WidgetTester tester, String slipId) async {
    await tester.pumpWidget(app(editor(slipId)));
    await settle(tester);
    await settle(tester);
  }

  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<String> seed({
    JadeSlipExecutorKind kind = JadeSlipExecutorKind.agent,
    JadeSlipFlowBinding? flowBinding,
    List<JadeSlipFlowRun> flowRuns = const [],
  }) async {
    final slip = await JadeSlipService.instance.create(title: '测试玉简');
    final updated = await JadeSlipService.instance.update(slip.copyWith(
      assigneeAgentId: 'agent-1',
      assigneeAgentName: '惜宝',
      executorKind: kind,
      flowBinding: flowBinding,
      flowRuns: flowRuns,
    ));
    return updated.id;
  }

  testWidgets('执行者切换：工作流模式给选模板入口，切回 Agent 不清绑定', (tester) async {
    await tester.runAsync(() async {
      // 之前绑过模板、当前切回 Agent：来回切换都得保留双方的数据。
      final id = await seed(flowBinding: binding);
      await pumpEditor(tester, id);

      expect(find.byKey(const ValueKey('slip-executor-agent')), findsOneWidget);
      expect(find.byKey(const ValueKey('slip-executor-flow')), findsOneWidget);
      expect(find.byKey(const ValueKey('slip-flow-pick')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('slip-executor-flow')));
      await settle(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('slip-flow-pick')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('slip-flow-input-goal')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('slip-executor-agent')));
      await settle(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('slip-flow-pick')), findsNothing);

      final saved = JadeSlipService.instance.peekById(id);
      expect(saved?.executorKind, JadeSlipExecutorKind.agent);
      expect(saved?.flowBinding?.name, '报告流程');
      expect(saved?.assigneeAgentId, 'agent-1');
      expect(saved?.assigneeAgentName, '惜宝');
    });
  });

  testWidgets('保存绑定并重开编辑页：模板、预设输入、角色绑定都在', (tester) async {
    await tester.runAsync(() async {
      debugJadeSlipTemplatePicker =
          (context, {required slip, current}) async => binding;
      final id = await seed();
      await pumpEditor(tester, id);

      await tester.tap(find.byKey(const ValueKey('slip-executor-flow')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('slip-flow-pick')));
      await settle(tester, 600);

      var saved = JadeSlipService.instance.peekById(id);
      expect(saved?.executorKind, JadeSlipExecutorKind.flow);
      expect(saved?.flowBinding?.name, '报告流程');
      expect(saved?.flowBinding?.revision, 3);
      expect(saved?.flowBinding?.inputs['goal'], '写完周报');
      expect(saved?.flowBinding?.bindings['coder'], 'agent-7');

      // 手填输入：值要落盘，来源标成 manual，模板 scope/name/版本不动。
      await tester.enterText(
        find.byKey(const ValueKey('slip-flow-input-goal')),
        '手写目标',
      );
      await settle(tester, 600);
      saved = JadeSlipService.instance.peekById(id);
      expect(saved?.flowBinding?.inputs['goal'], '手写目标');
      expect(saved?.flowBinding?.inputFrom['goal'], 'manual');
      expect(saved?.flowBinding?.scope, 'lib');
      expect(saved?.flowBinding?.name, '报告流程');
      expect(saved?.flowBinding?.revision, 3);

      // 关掉再开：从服务重新读，表单显示的值就是落盘的值。
      await tester.pumpWidget(const SizedBox());
      await pumpEditor(tester, id);
      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('slip-flow-input-goal')))
            .controller
            ?.text,
        '手写目标',
      );
      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('slip-flow-role-coder')))
            .controller
            ?.text,
        'agent-7',
      );
      expect(find.text('版本 3'), findsWidgets);
    });
  });

  testWidgets('工作流玉简清单全完成时仍能打开派发弹层', (tester) async {
    await tester.runAsync(() async {
      final created = await JadeSlipService.instance.create(
        title: '流程玉简',
        items: const [JadeSlipItem(id: 'only', text: '就这一项')],
      );
      await JadeSlipService.instance
          .setItemDone(id: created.id, itemId: 'only', done: true);
      final latest = await JadeSlipService.instance.getById(created.id);
      await JadeSlipService.instance.update(latest!.copyWith(
        executorKind: JadeSlipExecutorKind.flow,
        flowBinding: binding,
      ));

      await pumpEditor(tester, created.id);
      await tester.tap(find.text('执行'));
      await settle(tester);
      await settle(tester);

      // 纯 Agent 的「没有待办项」拦截不能套到模板重跑上。
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text('清单已全部完成，没有待办项可以交给 Agent'),
        findsNothing,
      );
    });
  });

  testWidgets('列表行：工作流玉简显示徽标与运行状态', (tester) async {
    narrow(tester);
    await tester.runAsync(() async {
      await JadeSlipService.instance.create(title: '普通玉简');
      var flow = await JadeSlipService.instance.create(title: '流程玉简');
      flow = await JadeSlipService.instance.update(flow.copyWith(
        executorKind: JadeSlipExecutorKind.flow,
        flowBinding: binding,
        flowRuns: const [JadeSlipFlowRun(runId: 'r1', status: 'running')],
      ));

      await tester.pumpWidget(app(const JadeSlipScreen(embedded: true)));
      await settle(tester);
      await settle(tester);

      expect(find.byKey(const ValueKey('slip-flow-badge')), findsOneWidget);
      expect(find.text('工作流 · 报告流程'), findsOneWidget);
      expect(find.text('运行：running'), findsOneWidget);
      expect(find.text('普通玉简'), findsOneWidget);
    });
  });

  testWidgets('列表行：纯 Agent 玉简不显示工作流徽标', (tester) async {
    narrow(tester);
    await tester.runAsync(() async {
      await JadeSlipService.instance.create(title: '普通玉简');
      await tester.pumpWidget(app(const JadeSlipScreen(embedded: true)));
      await settle(tester);
      await settle(tester);

      expect(find.byKey(const ValueKey('slip-flow-badge')), findsNothing);
      expect(find.text('普通玉简'), findsOneWidget);
    });
  });

  testWidgets('FlowRunScreen 带 sourceSlipId：头部可回到玉简', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final client = _fakeHost(bus);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        client: client,
        sourceSlipId: 's1',
        sourceSlipTitle: '测试玉简',
        onOpenSlip: () => opened++,
      ),
    ));
    await _pumpRun(tester);

    expect(find.byKey(const ValueKey('flow-run-from-slip')), findsOneWidget);
    expect(find.text('来自玉简《测试玉简》'), findsOneWidget);
    expect(find.text('回到玉简'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-run-from-slip')));
    await tester.pump();
    expect(opened, 1);

    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('FlowRunScreen 没有玉简来源时不加头部卡片', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: FlowRunScreen(peerId: 'p1', runId: 'r1', client: _fakeHost(bus)),
    ));
    await _pumpRun(tester);

    expect(find.byKey(const ValueKey('flow-run-from-slip')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('运行详情的 origin 优先于构造参数', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    final client = _fakeHost(bus, extra: const {
      'origin': {'kind': 'slip', 'slip_id': 's9'},
    });
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: FlowRunScreen(
        peerId: 'p1',
        runId: 'r1',
        title: '报告流程',
        client: client,
      ),
    ));
    await _pumpRun(tester);

    expect(find.byKey(const ValueKey('flow-run-from-slip')), findsOneWidget);
    expect(find.text('来自玉简《报告流程》'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}

/// 只回 `flow_run_get_resp` 的假主机，跟 flow_run_screen_p6_test 的写法一致。
HubFlow _fakeHost(
  StreamController<PeerControlEvent> bus, {
  Map<String, dynamic>? extra,
}) =>
    HubFlow(
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
              'tree': const <dynamic>[],
              if (extra != null) ...extra,
            },
          ));
        }
        return true;
      },
    );

Future<void> _pumpRun(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}
