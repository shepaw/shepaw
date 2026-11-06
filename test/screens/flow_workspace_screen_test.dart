import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';
import 'package:shepaw/screens/flow_workspace_screen.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  testWidgets('lists the library and starts a run with the flow name',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('第 3 版'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
    await _settle(tester);
    // 开跑前先问一次：inputs、角色绑定、跑的是哪一版。
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);
    final start =
        harness.sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['name'], 'dev');
    // 主机拒绝时把原因告诉用户，不跳走。
    expect(find.text('缺少输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('开跑：必填 input 没填就不发请求', (tester) async {
    final harness = _Harness()
      ..flowYaml =
          'flow: dev\ninputs:\n  goal: {type: string, required: true}\nroles:\n  coder: {desc: 写}\nsteps: []\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
    await _settle(tester);
    // 表单按 inputs 生成了。
    expect(find.byKey(const ValueKey('start-input-goal')), findsOneWidget);
    // 角色还没绑 Agent。
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);
    expect(find.textContaining('goal'), findsWidgets);
    expect(harness.sent.any((f) => f['type'] == 'flow_run_start_req'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a retry state when the host does not answer',
      (tester) async {
    final harness = _Harness(reachable: false);
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    expect(find.text('主机没有回应'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('新建：名字不合法在对话框里就被拦下', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('new-flow-name')), 'has space');
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settle(tester);
    // 没关对话框，也没发保存。
    expect(find.byKey(const ValueKey('new-flow-name')), findsOneWidget);
    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('新建：撞名不发请求', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);
    // 库里已经有 dev 了。
    await tester.enterText(find.byKey(const ValueKey('new-flow-name')), 'dev');
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('new-flow-name')), findsOneWidget);
    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('新建空白：带 create_only 存一个空骨架', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('new-flow-name')), 'fresh');
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settle(tester);

    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(save['name'], 'fresh');
    expect(save['create_only'], true);
    expect(save['yaml'], 'flow: fresh\nversion: 1\nsteps: []\n');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('打开新建对话框不再额外查库（离线时不会卡 10 秒）', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);
    final before =
        harness.sent.where((f) => f['type'] == 'flow_list_req').length;

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('new-flow-name')), findsOneWidget);
    expect(
      harness.sent.where((f) => f['type'] == 'flow_list_req').length,
      before,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('对话框打开期间别人建了同名流程：保存前查库把它挡下', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('new-flow-name')), 'fresh');
    // 对话框里的 existing 还是旧的；库里已经被别人占了名字。
    harness.flows = [
      {'name': 'dev', 'latest': 3},
      {'name': 'fresh', 'latest': 1},
    ];
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settle(tester);

    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isFalse);
    expect(find.text('已经有同名的流程了，换一个'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('flow_list 整体失败时新建仍照常保存，不误报主机没回应', (tester) async {
    final harness = _Harness()..listFails = true;
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byTooltip('新建'));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('new-flow-name')), 'fresh');
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settle(tester);

    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('列表栏的刷新会重新取名单（画廊文案不会停在旧值）', (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client, embedded: true);
    final before =
        harness.sent.where((f) => f['type'] == 'flow_list_req').length;

    await tester.tap(find.byIcon(Icons.refresh));
    await _settle(tester);

    expect(
      harness.sent.where((f) => f['type'] == 'flow_list_req').length,
      greaterThan(before),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('运行记录栏列主机上的运行，点一条打开运行视图', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byKey(const ValueKey('tab-runs')));
    await _settle(tester);
    expect(harness.sent.any((f) => f['type'] == 'flow_run_list_req'), isTrue);
    expect(find.byKey(const ValueKey('run-run_1')), findsOneWidget);
    expect(find.text('dev'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a flow opens its design view in the detail pane',
      (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 右栏出现设计视图（标题带流程名）。
    expect(find.text('设计：dev'), findsOneWidget);
    // 进详情要先把定义取回来。
    expect(harness.sent.any((f) => f['type'] == 'flow_get_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  // ── P1：退回按钮 ──────────────────────────────────────────────────────────

  testWidgets('P1 mobile push：列表 / 详情都只有一个返回按钮，且逐级退回', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(400, 800));
    // 列表态：外层隐含返回，1 个。
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 窄屏详情：actions 上提到外层，设计页不再画内层 AppBar。
    expect(find.text('设计：dev'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    // 设计页的 actions 确实合并进了外层唯一一条栏（这里至少能点「与上一版对比」）。
    expect(find.byTooltip('与上一版对比'), findsOneWidget);
    // 第一次返回 → 列表。
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-search')), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    // 第二次返回 → 上一页。
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.text('previous page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P1 desktop 非嵌入 push（宽屏）：最多一个返回按钮', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(2400, 1800));
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 宽屏：设计页自己那条栏没有返回按钮，外层仍是唯一一个。
    expect(find.byType(BackButton), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P1 desktop 嵌入（窄窗口）：详情态只有一个 _closeDetail 返回', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client,
        embedded: true, size: const Size(600, 900));
    // 窄屏嵌入列表态：不隐含返回。
    expect(find.byType(BackButton), findsNothing);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    expect(find.text('设计：dev'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-search')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P1 desktop 嵌入（宽窗口）：hideOuterAppBar 后最多一个返回', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client,
        embedded: true, size: const Size(2400, 1800));
    expect(find.byType(BackButton), findsNothing);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    expect(find.byType(BackButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A7 切 locale 后窄屏外层工具栏文案跟着更新', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final locale = ValueNotifier(const Locale('zh'));
    addTearDown(locale.dispose);

    await tester.pumpWidget(ValueListenableBuilder<Locale>(
      valueListenable: locale,
      builder: (context, value, _) => MaterialApp(
        locale: value,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FlowWorkspaceScreen(peerId: 'p1', client: harness.client),
      ),
    ));
    await _settle(tester);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 窄屏详情：设计页把 actions 发布到外层唯一一条栏。
    expect(find.byTooltip('与上一版对比'), findsOneWidget);

    locale.value = const Locale('en');
    await _settle(tester);
    // 状态没变（revision / dirty / …），但 locale 变了 —— 缓存签名必须换掉旧按钮。
    expect(find.byTooltip('与上一版对比'), findsNothing);
    expect(find.byTooltip('Compare with previous revision'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P1 有未保存草稿时按返回会弹 _guardDirty 确认', (tester) async {
    final harness = _Harness(editable: true)
      ..flowYaml = 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 写}\n';
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(2400, 1800));
    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 加一步 → 产生未保存改动（onDirtyChanged → _editorDirty = true）。
    await tester.tap(find.byKey(const ValueKey('after-impl')));
    await _settle(tester);
    // A3-7：有未保存改动仍要拦截原生返回。
    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
      isFalse,
    );
    // 返回走 PopScope → _guardDirty → 弹确认。
    await tester.tap(find.byType(BackButton).first);
    await _settle(tester);
    expect(find.text('有没保存的改动'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  // ── A3-7：原生返回 / 侧滑 ────────────────────────────────────────────────

  testWidgets('A3-7 列表态且干净时放行原生返回', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(400, 800));

    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
      isTrue,
      reason: '列表态没有可拦截的层级，不该吃掉 iOS 侧滑 / 原生 pop',
    );
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    expect(await navigator.maybePop(), isTrue);
    await _settle(tester);
    expect(find.text('previous page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A3-7 窄屏详情仍然拦截，先退回列表', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(400, 800));
    await tester.tap(find.text('dev'));
    await _settle(tester);

    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
      isFalse,
      reason: '详情态要先退回列表，不能直接退出页面',
    );
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    expect(await navigator.maybePop(), isTrue);
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-search')), findsOneWidget);
    expect(find.text('previous page'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // ── A3-6：开跑对话框的 agent 绑定用 Hub id ───────────────────────────────

  testWidgets('A3-6 老 peeragent_ 行选进 bindings 时发送 Hub id', (tester) async {
    const localId = 'peeragent_p1_remote-a36';
    final agent = RemoteAgent(
      id: localId,
      name: 'Legacy Agent',
      token: 'tok',
      endpoint: 'peer://p1/$localId',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      metadata: {
        'source_peer_id': 'p1',
        'remote_agent_id': 'remote-a36',
      },
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final harness = _Harness()
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写}\nsteps: []\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client, agents: [agent]);

    await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('start-role-coder')));
    await _settle(tester);
    await tester.tap(find.text('Legacy Agent'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);

    final start =
        harness.sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['bindings'], {'coder': 'remote-a36'},
        reason: '主机只认 Hub id，不能把本机行 id 发过去');
    await tester.pumpWidget(const SizedBox());
  });

  // ── A5-6：切主机后 agent 候选必须跟着换 ──────────────────────────────────

  testWidgets('A5-6 切主机后开跑选择器给的是新主机的 agent', (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    var activeHost = 'p1';
    PouchSessionStore.readOverride = () async => PouchSession(
          hubUrl: 'wss://hub.example/peer/ws',
          pouchId: 'bag',
          pouchName: 'bag',
          hostPeerId: activeHost,
        );
    addTearDown(() => PouchSessionStore.readOverride = null);

    final agents = [
      _peerAgent('agent-p1', 'P1 Agent', 'p1'),
      _peerAgent('agent-p2', 'P2 Agent', 'p2'),
    ];
    final harness = _Harness()
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写}\nsteps: []\n';
    addTearDown(harness.close);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowWorkspaceScreen(
        peerId: '',
        client: harness.client,
        embedded: true,
        initialAgents: agents,
      ),
    ));
    await _settle(tester);

    // 对话框退场动画比 _settle 的 180ms 长，多等一会儿，别在它还挂在树上时继续点。
    Future<void> settleLong() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> openPicker() async {
      await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
      await settleLong();
      await tester.tap(find.byKey(const ValueKey('start-role-coder')));
      await settleLong();
    }

    await openPicker();
    expect(find.text('P1 Agent'), findsOneWidget);
    expect(find.text('P2 Agent'), findsNothing,
        reason: '当前主机是 p1，不能列 p2 的 agent');
    // 选一个关掉选择器，再关掉开跑对话框。
    await tester.tap(find.text('P1 Agent'));
    await settleLong();
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await settleLong();

    // 主机切成 p2 后刷新工作台。
    activeHost = 'p2';
    await tester.tap(find.byIcon(Icons.refresh));
    await settleLong();

    await openPicker();
    expect(find.text('P2 Agent'), findsOneWidget,
        reason: '换主机后必须重拉该主机的 agent 列表');
    expect(find.text('P1 Agent'), findsNothing, reason: '旧主机的 agent 不能留在候选里');
    await tester.tap(find.text('P2 Agent'));
    await _settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  // ── A6-1：切主机后详情必须换 key（连同 controller 一起重建） ─────────────

  testWidgets('A6-1 同名流程切主机后详情的 ValueKey 带上新 peerId', (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    var activeHost = 'p1';
    PouchSessionStore.readOverride = () async => PouchSession(
          hubUrl: 'wss://hub.example/peer/ws',
          pouchId: 'bag',
          pouchName: 'bag',
          hostPeerId: activeHost,
        );
    addTearDown(() => PouchSessionStore.readOverride = null);

    final harness = _Harness();
    addTearDown(harness.close);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowWorkspaceScreen(
        peerId: '',
        client: harness.client,
        embedded: true,
      ),
    ));
    await _settle(tester);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    final before =
        tester.widget<FlowDesignScreen>(find.byType(FlowDesignScreen));
    expect(before.peerId, 'p1');
    expect(before.key.toString(), contains('p1'));

    activeHost = 'p2';
    await tester.tap(find.byIcon(Icons.refresh));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final after =
        tester.widget<FlowDesignScreen>(find.byType(FlowDesignScreen));
    expect(after.peerId, 'p2');
    expect(after.key, isNot(before.key),
        reason: '同名流程换主机后必须强制重建详情，不能复用旧 controller');
    expect(after.key.toString(), contains('p2'));
    await tester.pumpWidget(const SizedBox());
  });
}

RemoteAgent _peerAgent(String id, String name, String peerId) => RemoteAgent(
      id: id,
      name: name,
      token: 'tok',
      endpoint: 'peer://$peerId/$id',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      metadata: {
        'source_peer_id': peerId,
        'remote_agent_id': id,
      },
      createdAt: 1,
      updatedAt: 1,
    );

/// 假主机：按帧类型回一份固定应答，并把请求记下来。
class _Harness {
  _Harness({this.reachable = true, this.editable = false});

  final bool reachable;

  /// 让 design 页可编辑（schema 带 ops、树里有一个 task 节点），用来造未保存草稿。
  final bool editable;

  /// `flow_get` 回的定义。换掉它就能试 inputs / roles 的开跑表单。
  String flowYaml = 'flow: dev\nsteps: []\n';

  /// 库里的流程名单。改它就能模拟「对话框打开期间别人建了同名流程」。
  List<Map<String, dynamic>> flows = [
    {'name': 'dev', 'latest': 3},
  ];

  /// 让 `flow_list_resp` 整体失败（例如库里有一个坏掉的 meta.json）。
  bool listFails = false;

  final StreamController<PeerControlEvent> bus =
      StreamController<PeerControlEvent>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  HubFlow get client => HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          sent.add(frame);
          if (!reachable) return false;
          final reply = switch (frame['type']) {
            'flow_list_req' => listFails
                ? {
                    'type': 'flow_list_resp',
                    'success': false,
                    'error': 'meta 读不出来',
                  }
                : {
                    'type': 'flow_list_resp',
                    'success': true,
                    'flows': flows,
                  },
            'flow_run_list_req' => {
                'type': 'flow_run_list_resp',
                'success': true,
                'runs': [
                  {
                    'run_id': 'run_1',
                    'flow': 'dev',
                    'status': 'succeeded',
                    'scope': 'lib',
                    'revision': 2,
                    'started_ms': 1700000000000,
                    'tasks_used': 3,
                  },
                ],
              },
            'flow_save_req' => {
                'type': 'flow_save_resp',
                'success': true,
                'flow': {'name': frame['name'], 'latest': 1},
              },
            'flow_run_start_req' => {
                'type': 'flow_run_start_resp',
                'success': false,
                'error': '缺少输入',
              },
            'flow_get_req' => {
                'type': 'flow_get_resp',
                'success': true,
                'revision': 3,
                'yaml': flowYaml,
              },
            'flow_schema_req' => {
                'type': 'flow_schema_resp',
                'success': true,
                'common': [],
                'kinds': editable
                    ? {
                        'task': [
                          {
                            'name': 'task.prompt',
                            'type': 'text',
                            'label': '提示词'
                          },
                        ],
                      }
                    : {},
                'ops': editable
                    ? [
                        'set',
                        'insert',
                        'move',
                        'delete',
                        'wrap',
                        'unwrap',
                        'retype',
                        'header',
                      ]
                    : [],
              },
            'flow_validate_req' => {
                'type': 'flow_validate_resp',
                'success': true,
                'yaml': editable
                    ? ((frame['yaml'] as String?) ?? flowYaml)
                    : 'flow: dev\nsteps: []\n',
                'tree': editable
                    ? [
                        {
                          'key': 'impl',
                          'id': 'impl',
                          'kind': 'task',
                          'fields': {
                            'task': {'prompt': '写'}
                          },
                        },
                      ]
                    : [],
                'diagnostics': [],
              },
            'flow_edit_req' => {
                'type': 'flow_edit_resp',
                'success': true,
                'valid': true,
                'yaml': 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 改了}\n',
                'tree': [
                  {
                    'key': 'impl',
                    'id': 'impl',
                    'kind': 'task',
                    'fields': {
                      'task': {'prompt': '改了'}
                    },
                  },
                ],
                'diagnostics': [],
              },
            _ => null,
          };
          if (reply != null) {
            bus.add(PeerControlEvent(
                peerId: peerId,
                data: {...reply, 'request_id': frame['request_id']}));
          }
          return true;
        },
      );

  Future<void> close() async {
    await bus.close();
  }
}

Future<void> _pump(
  WidgetTester tester,
  HubFlow client, {
  bool embedded = false,
  List<RemoteAgent> agents = const [],
}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: FlowWorkspaceScreen(
      peerId: 'p1',
      client: client,
      embedded: embedded,
      initialAgents: agents.isEmpty ? null : agents,
    ),
  ));
  await _settle(tester);
}

/// 把工作台 push 成一条真正的路由（下面压着「上一页」），才能验证逐级返回，
/// 也能让 AppBar 真正生成隐含返回按钮。
Future<void> _pumpPushed(
  WidgetTester tester,
  HubFlow client, {
  bool embedded = false,
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
        builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('previous page'),
                    ElevatedButton(
                      key: const ValueKey('go-to-flows'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FlowWorkspaceScreen(
                              peerId: 'p1', client: client, embedded: embedded),
                        ),
                      ),
                      child: const Text('go'),
                    ),
                  ],
                ),
              ),
            )),
  ));
  await tester.tap(find.byKey(const ValueKey('go-to-flows')));
  await _settle(tester);
}

/// 页面里有 spinner 和计时器，`pumpAndSettle` 不会收敛，用有界 pump。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}
