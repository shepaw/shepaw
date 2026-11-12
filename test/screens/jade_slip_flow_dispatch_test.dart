import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/jade_slip_dispatch_dialog.dart';
import 'package:shepaw/screens/jade_slip_flow_dispatch.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/pouch_session.dart';
import 'package:shepaw/storage/slip_scope_documents.dart';

import '../storage/memory_scope_transport.dart';
import '../storage/test_harness.dart';

/// 玉简绑定工作流的派发路径：纯函数 + 弹层 + 一次不开真主机的开跑。
void main() {
  const self = 'aaaaaaaaaaaaaaaa';
  // 模板声明了 inputs，自动映射才有落点；没有声明的 input 一律不写。
  const yaml = 'name: demo\n'
      'inputs:\n'
      '  goal:\n'
      '    type: string\n'
      '    required: true\n'
      '  constraints:\n'
      '    type: string\n'
      '  done_when:\n'
      '    type: string\n'
      '  title:\n'
      '    type: string\n'
      '  slip_context:\n'
      '    type: string\n'
      'steps: []\n';

  setUpAll(() async {
    await StorageTestHarness.init();
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
    JadeSlipService.instance.debugDocuments = null;
    PouchSessionStore.readOverride = null;
    PouchSessionStore.debugResetCache();
  });

  Future<void> settle(WidgetTester tester, [int ms = 80]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  Widget dialogApp(
    JadeSlip slip,
    void Function(JadeSlipDispatchChoice? choice) onResult,
  ) =>
      app(Scaffold(
        body: Builder(builder: (context) {
          return Center(
            child: FilledButton(
              onPressed: () async {
                final choice = await showJadeSlipDispatchDialog(
                  context,
                  slip: slip,
                  agents: const [],
                );
                onResult(choice);
              },
              child: const Text('打开弹层'),
            ),
          );
        }),
      ));

  JadeSlip slip({
    String id = 's1',
    JadeSlipExecutorKind kind = JadeSlipExecutorKind.agent,
    JadeSlipFlowBinding? binding,
    List<JadeSlipFlowRun> runs = const [],
    List<JadeSlipItem> items = const [],
  }) =>
      JadeSlip(
        id: id,
        title: '测试玉简',
        body: '正文备注',
        goal: '把事做完',
        constraints: '别超时',
        doneWhen: '测试通过',
        items: items,
        executorKind: kind,
        flowBinding: binding,
        flowRuns: runs,
        deviceId: 'd1',
        createdAt: 1,
        updatedAt: 2,
      );

  const binding = JadeSlipFlowBinding(
    scope: 'lib',
    name: 'demo',
    inputs: {'goal': '预设目标'},
    bindings: {'coder': 'agent-1'},
  );

  group('jadeSlipFlowInputs', () {
    test('自动映射约定字段，未知名字忽略', () {
      final inputs = jadeSlipFlowInputs(
        slip(),
        inputNames: const [
          'goal',
          'constraints',
          'done_when',
          'body',
          'title',
          'unknown',
          '',
        ],
      );
      expect(inputs, {
        'goal': '把事做完',
        'constraints': '别超时',
        'done_when': '测试通过',
        'body': '正文备注',
        'title': '测试玉简',
      });
      expect(inputs.containsKey('unknown'), isFalse);
      expect(inputs.containsKey(''), isFalse);
    });

    test('presets 赢自动映射，overrides 赢 presets', () {
      expect(
        jadeSlipFlowInputs(
          slip(),
          inputNames: const ['goal', 'body'],
          presets: const {'goal': '预设目标'},
        )['goal'],
        '预设目标',
      );
      expect(
        jadeSlipFlowInputs(
          slip(),
          inputNames: const ['goal'],
          presets: const {'goal': '预设目标'},
          overrides: const {'goal': '手填目标'},
        )['goal'],
        '手填目标',
      );
    });

    test('空 override / 空 preset 不会抹掉低优先级的值', () {
      expect(
        jadeSlipFlowInputs(
          slip(),
          inputNames: const ['goal'],
          presets: const {'goal': '预设目标'},
          overrides: const {'goal': '  '},
        )['goal'],
        '预设目标',
      );
      expect(
        jadeSlipFlowInputs(
          slip(),
          inputNames: const ['goal'],
          presets: const {'goal': ''},
        )['goal'],
        '把事做完',
      );
      // 未声明的名字就算 presets / overrides 里有也一概不写。
      expect(
        jadeSlipFlowInputs(
          slip(),
          inputNames: const ['goal'],
          presets: const {'ghost': 'p'},
          overrides: const {'ghost': 'o'},
        ).containsKey('ghost'),
        isFalse,
      );
    });

    test('空值不写入；slip_context 拼清单与附件地址', () {
      const blank = JadeSlip(
        id: 's2',
        title: '',
        deviceId: 'd1',
        createdAt: 1,
        updatedAt: 2,
      );
      expect(
        jadeSlipFlowInputs(blank, inputNames: const ['body', 'goal']),
        isEmpty,
      );
      final context = jadeSlipFlowInputs(
        slip(),
        inputNames: const ['slip_context'],
        checklistText: '- [ ] 第一项\n- [x] 第二项',
        attachmentUris: '- a.png: pouch://p/slip:s1/files/a.png',
      )['slip_context'];
      expect(context, contains('测试玉简'));
      expect(context, contains('目标：把事做完'));
      expect(context, contains('- [ ] 第一项'));
      expect(context, contains('pouch://p/slip:s1/files/a.png'));
      expect(context, contains('附件：'));
    });
  });

  group('mergeJadeSlipFlowRuns', () {
    test('按 runId 取并集、不产生重复', () {
      final merged = mergeJadeSlipFlowRuns(
        const [
          JadeSlipFlowRun(runId: 'r1', startedAt: 1),
          JadeSlipFlowRun(runId: 'r2', startedAt: 2, status: 'succeeded'),
        ],
        const JadeSlipFlowRun(runId: 'r1', startedAt: 1),
      );
      expect(merged.map((r) => r.runId), ['r1', 'r2']);
      expect(merged.length, 2);
    });

    test('终态优先于 running，running 不会把终态退回', () {
      const running = JadeSlipFlowRun(runId: 'r1', startedAt: 5);
      const done = JadeSlipFlowRun(
        runId: 'r1',
        startedAt: 6,
        status: 'succeeded',
      );
      final upgraded = mergeJadeSlipFlowRuns(const [running], done);
      expect(upgraded.single.status, 'succeeded');
      final kept = mergeJadeSlipFlowRuns(const [done], running);
      expect(kept.single.status, 'succeeded');
      expect(kept.single.startedAt, 6);
    });

    test('只保留最近 20 条', () {
      var runs = <JadeSlipFlowRun>[];
      for (var i = 0; i < 25; i++) {
        runs = mergeJadeSlipFlowRuns(
          runs,
          JadeSlipFlowRun(runId: 'r$i', startedAt: i + 1),
        );
      }
      expect(runs.length, kMaxJadeSlipFlowRuns);
      expect(runs.first.runId, 'r5');
      expect(runs.last.runId, 'r24');
      expect(runs.map((r) => r.runId).toSet().length, 20);
    });
  });

  test('开跑表单交回的输入：非空值覆盖预设，清空的框不抹掉预设 / 自动映射', () {
    final merged = mergeJadeSlipFormInputs(
      {'goal': 'Ship', 'title': '玉简标题', 'extra': '预设'},
      {'goal': '', 'title': '人改的标题', 'new': '只在表单里'},
    );
    expect(merged, {
      'goal': 'Ship',
      'title': '人改的标题',
      'extra': '预设',
      'new': '只在表单里',
    });
    // 角色绑定走同一个合并：表单清空的角色不该抹掉预设。
    expect(
      mergeJadeSlipFormInputs({'coder': 'agent-1', 'reviewer': 'agent-2'},
          {'coder': '', 'dev': 'agent-3'}),
      {'coder': 'agent-1', 'reviewer': 'agent-2', 'dev': 'agent-3'},
    );
  });

  testWidgets('工作流玉简的确认弹层只有开跑，没有 Agent / 会话选项',
      (tester) async {
    await tester.runAsync(() async {
      final flowSlip = slip(
        kind: JadeSlipExecutorKind.flow,
        binding: binding,
      );
      JadeSlipDispatchChoice? choice;
      await tester.pumpWidget(dialogApp(flowSlip, (value) => choice = value));
      await tester.tap(find.text('打开弹层'));
      await settle(tester);
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('开跑工作流'), findsOneWidget);
      expect(find.text('开跑'), findsOneWidget);
      expect(find.text('demo'), findsNothing); // name 嵌在标题里
      expect(find.text('目标会话'), findsNothing);
      expect(find.text('执行 Agent'), findsNothing);
      expect(find.text('当前会话'), findsNothing);
      expect(find.text('新开会话'), findsNothing);
      expect(find.text('修改'), findsNothing);
      expect(find.text('预设输入: 1'), findsOneWidget);
      expect(find.text('角色绑定: 1'), findsOneWidget);

      await tester.tap(find.text('开跑'));
      await settle(tester);
      await settle(tester);
      expect(choice?.flowConfirmed, isTrue);
    });
  });

  testWidgets('切到工作流但还没选模板时，也不弹 Agent / 会话选项', (tester) async {
    await tester.runAsync(() async {
      final unbound = slip(kind: JadeSlipExecutorKind.flow);
      await tester.pumpWidget(dialogApp(unbound, (_) {}));
      await tester.tap(find.text('打开弹层'));
      await settle(tester);
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('未选工作流'), findsOneWidget);
      expect(find.text('目标会话'), findsNothing);
      expect(find.text('执行 Agent'), findsNothing);
      expect(find.text('修改'), findsNothing);
      // 「开跑」按钮要禁用，逼用户先回编辑页选模板。
      final go = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开跑'),
      );
      expect(go.onPressed, isNull);
    });
  });

  testWidgets('纯 Agent 玉简的确认弹层保持会话选项', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(dialogApp(slip(), (_) {}));
      await tester.tap(find.text('打开弹层'));
      await settle(tester);
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('目标会话'), findsOneWidget);
      expect(find.text('执行 Agent'), findsOneWidget);
      expect(find.text('当前会话'), findsOneWidget);
      expect(find.text('新开会话'), findsOneWidget);
      expect(find.text('指定会话'), findsOneWidget);
      expect(find.text('修改'), findsOneWidget);
      expect(find.textContaining('开跑工作流'), findsNothing);
      expect(find.text('开跑'), findsNothing);
    });
  });

  testWidgets('已有运行中的工作流时再确认一次，取消就不派发', (tester) async {
    await tester.runAsync(() async {
      final running = slip(
        kind: JadeSlipExecutorKind.flow,
        binding: binding,
        runs: const [
          JadeSlipFlowRun(runId: 'r-old', startedAt: 10, status: 'running'),
        ],
      );
      JadeSlipDispatchChoice? choice;
      await tester.pumpWidget(dialogApp(running, (value) => choice = value));
      await tester.tap(find.text('打开弹层'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.text('开跑'));
      await settle(tester);
      await settle(tester);

      expect(find.text('已有运行中的工作流，仍要再开一次？'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.text('取消'),
      ));
      await settle(tester);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(choice, isNull);
    });
  });

  testWidgets('模板选择弹层列出 lib 模板，重选保留预设输入', (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml, listTemplates: true);
      JadeSlipFlowBinding? picked;
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              picked = await showJadeSlipFlowTemplatePicker(
                context,
                slip: slip(kind: JadeSlipExecutorKind.flow, binding: binding),
                current: const JadeSlipFlowBinding(
                  scope: 'lib',
                  name: 'demo',
                  revision: 2,
                  inputs: {'goal': '预设目标'},
                  bindings: {'coder': 'agent-1'},
                ),
                client: hub.client,
              );
            },
            child: const Text('打开模板选择'),
          ),
        )),
      )));
      await tester.tap(find.text('打开模板选择'));
      // 模板列表是真实异步加载的（runAsync）：全量并发跑时机器忙，固定等几轮
      // 不够。轮询到出现为止，最多约 3 秒。
      final demo = find.byKey(const ValueKey('slip-flow-template-demo'));
      for (var i = 0; i < 50 && demo.evaluate().isEmpty; i++) {
        await settle(tester, 60);
      }
      await settle(tester, 60);

      expect(demo, findsOneWidget);
      expect(find.byKey(const ValueKey('slip-flow-template-other')),
          findsOneWidget);
      expect(find.text('模板说明'), findsOneWidget);
      expect(find.text('版本 3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('slip-flow-template-demo')));
      await settle(tester);
      await settle(tester);
      expect(picked?.scope, 'lib');
      expect(picked?.name, 'demo');
      expect(picked?.inputs, {'goal': '预设目标'});
      expect(picked?.bindings, {'coder': 'agent-1'});
      expect(picked?.revision, isNull); // 重选回到最新版
      await hub.bus.close();
    });
  });

  testWidgets('模板选择弹层同时列公共库和所属群模板', (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml, listTemplates: true);
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              await showJadeSlipFlowTemplatePicker(
                context,
                slip: slip(kind: JadeSlipExecutorKind.flow),
                groupScopes: const ['group:g1'],
                client: hub.client,
              );
            },
            child: const Text('打开模板选择'),
          ),
        )),
      )));
      await tester.tap(find.text('打开模板选择'));
      final groupDemo =
          find.byKey(const ValueKey('slip-flow-template-group:g1/demo'));
      for (var i = 0; i < 50 && groupDemo.evaluate().isEmpty; i++) {
        await settle(tester, 60);
      }
      await settle(tester, 60);

      final listed = hub.frames
          .where((frame) => frame['type'] == 'flow_list_req')
          .map((frame) => frame['scope'] ?? '')
          .toList();
      expect(listed, contains('lib'));
      expect(listed, contains('group:g1'), reason: '要拉所属群的模板库');
      // 同名模板在群库里带 scope 前缀，不会和公共库撞键。
      expect(find.byKey(const ValueKey('slip-flow-template-demo')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('slip-flow-template-group:g1/demo')),
          findsOneWidget);
      await hub.bus.close();
    });
  });

  testWidgets('模板被删 / 钉的版本取不到时明确提示重选，不静默换模板',
      (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml, getFails: true);
      bool? dispatched;
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              dispatched = await dispatchJadeSlipFlow(
                context,
                slip(kind: JadeSlipExecutorKind.flow, binding: binding),
                confirmed: true,
                client: hub.client,
              );
            },
            child: const Text('派发'),
          ),
        )),
      )));
      await tester.tap(find.text('派发'));
      for (var i = 0; i < 5; i++) {
        await settle(tester, 60);
      }

      expect(dispatched, isFalse);
      expect(hub.frames.where((f) => f['type'] == 'flow_run_start_req'),
          isEmpty, reason: '取不到模板就绝不开跑');
      expect(find.text('模板不存在或钉的版本已删除，请重新选择'), findsOneWidget);
      expect(find.text('选择工作流模板'), findsOneWidget,
          reason: '提示里要带重选入口');
      await hub.bus.close();
    });
  });

  testWidgets('旧主机没有 origin_ack 时仍可开跑，但提示不会回写',
      (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml, originAck: false);
      bool? dispatched;
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              dispatched = await dispatchJadeSlipFlow(
                context,
                slip(
                  id: 's-old-host',
                  kind: JadeSlipExecutorKind.flow,
                  binding: binding,
                ),
                confirmed: true,
                client: hub.client,
              );
            },
            child: const Text('派发'),
          ),
        )),
      )));
      await tester.tap(find.text('派发'));
      for (var i = 0; i < 6; i++) {
        await settle(tester, 60);
      }
      await tester.pump(const Duration(milliseconds: 400));

      expect(dispatched, isTrue, reason: '旧主机照常开跑');
      expect(hub.frames.where((f) => f['type'] == 'flow_run_start_req').length,
          1);
      expect(find.text('主机版本较旧，运行不会回写玉简'), findsOneWidget);
      await hub.bus.close();
    });
  });

  testWidgets('主机已回写终态时派发落盘不覆盖待验收状态', (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml);
      final base = slip(
        id: 's-race',
        kind: JadeSlipExecutorKind.flow,
        binding: binding,
        items: const [JadeSlipItem(id: 'i1', text: '第一项')],
      );
      // 这一跑很快：主机在 App 落盘前就把 succeeded 写进了权威副本。
      await JadeSlipService.instance.update(base.copyWith(
        status: JadeSlipStatus.needsReview,
        flowStatus: 'needs_review',
        flowRuns: const [
          JadeSlipFlowRun(
            runId: 'r1',
            startedAt: 1,
            status: 'succeeded',
            hostId: 'host-1',
          ),
        ],
      ));

      bool? dispatched;
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              // 调用方手里还是开跑前那份旧对象。
              dispatched = await dispatchJadeSlipFlow(
                context,
                base,
                confirmed: true,
                client: hub.client,
              );
            },
            child: const Text('派发'),
          ),
        )),
      )));
      await tester.tap(find.text('派发'));
      for (var i = 0; i < 6; i++) {
        await settle(tester, 60);
      }
      await tester.pump(const Duration(milliseconds: 400));

      expect(dispatched, isTrue);
      final saved = await JadeSlipService.instance.getById('s-race');
      expect(saved?.status, JadeSlipStatus.needsReview,
          reason: '不能把主机已经写好的待验收盖成进行中');
      expect(saved?.flowStatus, 'needs_review');
      expect(saved?.flowRuns.any((r) => r.runId == 'r1' && r.isTerminal),
          isTrue);
      await hub.bus.close();
    });
  });

  testWidgets('dispatchJadeSlipFlow 直接开跑：origin 带 slip_id，不弹会话选择',
      (tester) async {
    await tester.runAsync(() async {
      PouchSessionStore.readOverride = () async => const PouchSession(
            hubUrl: 'https://hub.test',
            pouchId: 'p',
            pouchName: 'p',
            hostPeerId: 'host-1',
          );
      final hub = _fakeHub(yaml: yaml);
      final flowSlip = slip(
        id: 's-flow-dispatch',
        kind: JadeSlipExecutorKind.flow,
        binding: binding,
        items: const [JadeSlipItem(id: 'i1', text: '第一项')],
      );
      bool? dispatched;
      await tester.pumpWidget(app(Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              dispatched = await dispatchJadeSlipFlow(
                context,
                flowSlip,
                confirmed: true,
                client: hub.client,
              );
            },
            child: const Text('派发'),
          ),
        )),
      )));
      await tester.tap(find.text('派发'));
      for (var i = 0; i < 6; i++) {
        await settle(tester, 60);
      }
      await tester.pump(const Duration(milliseconds: 400));

      expect(dispatched, isTrue);
      final start = hub.frames.firstWhere(
        (frame) => frame['type'] == 'flow_run_start_req',
      );
      expect(start['origin'], {
        'kind': 'slip',
        'slip_id': 's-flow-dispatch',
        'device_id': 'd1',
      });
      expect(start['scope'], 'lib');
      expect(start['name'], 'demo');
      expect(start['revision'], 3);
      // 自动映射 + 预设：预设赢，清单里没有单独的 Agent / 会话选择。
      expect(start['inputs']['goal'], '预设目标');
      expect(start['inputs']['constraints'], '别超时');
      expect(start['inputs']['done_when'], '测试通过');
      expect(find.text('目标会话'), findsNothing);
      expect(find.text('执行 Agent'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      final saved = await JadeSlipService.instance.getById('s-flow-dispatch');
      expect(saved?.flowRuns.any((r) => r.runId == 'r1'), isTrue);
      expect(saved?.sourceChannelId, isEmpty);
      // 主机确认会回写：开跑挂上 in_progress 锁，清单派生不会立刻冲掉它。
      expect(saved?.status, JadeSlipStatus.inProgress);
      expect(saved?.flowStatus, 'in_progress');
      await hub.bus.close();
    });
  });
}

/// 内存里的一台假主机：请求帧留痕，响应帧同步打回 bus，不碰真连接。
class _FakeHub {
  _FakeHub({
    required this.yaml,
    required bool listTemplates,
    this.getFails = false,
    this.originAck = true,
  }) {
    bus = StreamController<PeerControlEvent>.broadcast();
    client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        frames.add(Map<String, dynamic>.from(frame));
        final type = frame['type'];
        if (type == 'flow_list_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_list_resp',
              'request_id': frame['request_id'],
              'success': true,
              'flows': listTemplates
                  ? [
                      {
                        'name': 'demo',
                        'latest': 3,
                        'description': '模板说明',
                      },
                      {'name': 'other', 'latest': 1},
                    ]
                  : <Map<String, dynamic>>[],
            },
          ));
        } else if (type == 'flow_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: getFails
                ? {
                    'type': 'flow_get_resp',
                    'request_id': frame['request_id'],
                    'success': false,
                    'error': '流程不存在',
                  }
                : {
                    'type': 'flow_get_resp',
                    'request_id': frame['request_id'],
                    'success': true,
                    'revision': 3,
                    'yaml': listTemplates
                        ? 'name: demo\ninputs:\n  goal:\n    type: string\nsteps: []\n'
                        : yaml,
                    'required_roles': <String>[],
                  },
          ));
        } else if (type == 'flow_run_start_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_start_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              if (originAck) 'origin_ack': true,
            },
          ));
        } else if (type == 'flow_run_get_req') {
          bus.add(PeerControlEvent(
            peerId: peerId,
            data: {
              'type': 'flow_run_get_resp',
              'request_id': frame['request_id'],
              'success': true,
              'run_id': 'r1',
              'status': 'running',
              'tasks_used': 0,
              'tree': <Map<String, dynamic>>[],
            },
          ));
        }
        return true;
      },
    );
  }

  final String yaml;
  final bool getFails;
  final bool originAck;
  late final StreamController<PeerControlEvent> bus;
  late final HubFlow client;
  final List<Map<String, dynamic>> frames = [];
}

_FakeHub _fakeHub({
  required String yaml,
  bool listTemplates = false,
  bool getFails = false,
  bool originAck = true,
}) =>
    _FakeHub(
      yaml: yaml,
      listTemplates: listTemplates,
      getFails: getFails,
      originAck: originAck,
    );
