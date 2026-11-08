import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 只为在用例结束后还原平台实例；shared_preferences 本身是直接依赖。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';
import 'package:shepaw/screens/flow_detail_screen.dart';
import 'package:shepaw/screens/flow_start_screen.dart';
import 'package:shepaw/screens/flow_workspace_screen.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  testWidgets('拖流程库和编辑区之间的分割线会改变两边宽度', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    final pane = find.byKey(const ValueKey('flow-library-pane'));
    final before = tester.getSize(pane).width;
    await tester.drag(
      find.byKey(const ValueKey('flow-library-splitter')),
      const Offset(80, 0),
    );
    await _settle(tester);
    expect(tester.getSize(pane).width, greaterThan(before + 40));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lists the library and starts a run with the flow name',
      (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    expect(find.text('dev'), findsOneWidget);
    expect(find.text('第 3 版'), findsOneWidget);
    await _startFromRow(tester, 'dev');
    await _settle(tester);
    // 开跑前先问一次：inputs、角色绑定、跑的是哪一版。
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);
    final start =
        harness.sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['name'], 'dev');
    // 表单是照第 3 版生成的，开跑就钉住第 3 版：别人中途存了新版也不会
    // 拿旧 inputs / bindings 去跑另一份定义。
    expect(start['revision'], 3);
    // 主机拒绝时把原因告诉用户，不跳走。
    expect(find.text('缺少输入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('主机给出 required_roles 时按主机名单生成绑定行', (tester) async {
    final harness = _Harness()
      // 定义里一个 role 引用都没有：客户端自己扫描会得到空名单，只有主机
      // 名单被采纳才会出现这一行（模拟主机新增了 App 还不认的节点用法）。
      ..flowYaml = 'flow: dev\nsteps:\n  - id: impl\n    task: {agent: claude-main, prompt: 写}\n'
      ..requiredRoles = ['coder'];
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await _startFromRow(tester, 'dev');
    await _settle(tester);
    expect(find.byKey(const ValueKey('start-role-coder')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('先保存再跑：新版本多出角色时带着旧值再问一次', (tester) async {
    // 草稿落盘走 SharedPreferences，没 mock 平台通道时 save() 会一直挂着。
    // 用完把平台实例还原：否则同文件后续用例会真的落草稿、互相污染。
    final originalPlatform = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
    addTearDown(() {
      SharedPreferences.setMockInitialValues({}); // 清数据 + 重置缓存实例
      SharedPreferencesStorePlatform.instance = originalPlatform;
    });
    final harness = _Harness(editable: true)
      ..flowYaml = 'flow: dev\ninputs:\n  goal: {type: string, required: true}\nsteps:\n- id: impl\n  task: {prompt: 写}\n'
      ..requiredRoles = [];
    addTearDown(harness.close);
    await _pumpPushed(tester, harness.client, size: const Size(2400, 1800));
    await tester.tap(find.text('dev'));
    await _settle(tester);
    // 加一步 → 产生未保存草稿。
    await tester.tap(find.byKey(const ValueKey('after-impl')));
    await _settle(tester);

    await _startFromRow(tester, 'dev');
    await _settleRoute(tester);
    // 表单照旧版生成：没有角色要绑。
    expect(find.byKey(const ValueKey('start-role-reviewer')), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '目标');
    await tester.tap(find.byKey(const ValueKey('save-first')));
    await tester.pump();
    // 保存成的新一版里多了一个 role 节点，主机名单也跟着变了。
    harness.flowYaml = 'flow: dev\ninputs:\n  goal: {type: string, required: true}\nroles:\n  reviewer: {desc: 审}\nsteps:\n- id: impl\n  task: {role: reviewer, prompt: 写}\n';
    harness.requiredRoles = ['reviewer'];
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settleRoute(tester);

    // 表单重新打开：刚填的目标带回来了，并补问新角色（不能拿旧 bindings 直接跑）。
    expect(find.byType(FlowStartScreen), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('start-input-goal')))
            .controller
            ?.text,
        '目标');
    expect(find.byKey(const ValueKey('start-role-reviewer')), findsOneWidget);
    expect(harness.sent.any((f) => f['type'] == 'flow_run_start_req'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('开跑：必填 input 没填就不发请求', (tester) async {
    final harness = _Harness()
      ..flowYaml =
          'flow: dev\ninputs:\n  goal: {type: string, required: true}\nroles:\n  coder: {desc: 写}\nsteps: []\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await _startFromRow(tester, 'dev');
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

  testWidgets('模板节点改成 Agent 后，开跑不再要求给声明过的角色选 Agent',
      (tester) async {
    final harness = _Harness()
      ..flowYaml = '''
flow: dev
roles:
  coder: {desc: 写代码}
  reviewer: {desc: 审代码}
inputs:
  goal: {type: string, required: true}
steps:
  - id: impl
    task: {agent: claude-main, prompt: 写}
  - id: review
    task: {agent: codex-main, prompt: 审}
''';
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await _startFromRow(tester, 'dev');
    await _settle(tester);
    expect(find.byKey(const ValueKey('start-role-coder')), findsNothing);
    expect(find.byKey(const ValueKey('start-role-reviewer')), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('start-input-goal')), '做个小工具');
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);

    final start =
        harness.sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start.containsKey('bindings'), isFalse,
        reason: '没有节点用 role，就不该给主机塞没用的 bindings');
    expect(start['inputs'], {'goal': '做个小工具'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('开跑表单是独立页面，文本输入框会跟着内容长高', (tester) async {
    final harness = _Harness()
      ..flowYaml = 'flow: dev\ninputs:\n  goal: {type: string}\nsteps: []\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await _startFromRow(tester, 'dev');
    await _settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(FlowStartScreen), findsOneWidget);
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('start-input-goal')));
    expect(field.maxLines, isNull, reason: '不能钉死成单行');
    expect(field.minLines, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('roles.default 预填进绑定，不用再手选 Agent', (tester) async {
    final harness = _Harness()
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写, default: codex-main}\nsteps:\n  - id: impl\n    task: {role: coder, prompt: 写}\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await _startFromRow(tester, 'dev');
    await _settle(tester);
    expect(find.text('codex-main'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-go')));
    await _settle(tester);
    final start =
        harness.sent.firstWhere((f) => f['type'] == 'flow_run_start_req');
    expect(start['bindings'], {'coder': 'codex-main'});
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

  testWidgets('执行历史按开跑时填的标题列出这个流程的运行', (tester) async {
    final harness = _Harness()
      ..runs = [
        {
          'run_id': 'run_goal',
          'flow': 'dev',
          'status': 'succeeded',
          'started_ms': 1700000000000,
          'input_title': '修好登录页',
        },
        {
          'run_id': 'run_old',
          'flow': 'dev',
          'status': 'failed',
          'started_ms': 1600000000000,
        },
        {
          'run_id': 'run_other',
          'flow': 'other',
          'status': 'succeeded',
          'started_ms': 1500000000000,
          'input_title': '别的流程',
        },
      ];
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.byKey(const ValueKey('flow-more-dev')));
    await _settleMenu(tester);
    expect(find.text('执行历史'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-executions-dev')));
    await _settleMenu(tester);

    expect(find.byKey(const ValueKey('flow-executions-page')), findsOneWidget);
    expect(find.text('修好登录页'), findsOneWidget);
    expect(find.text('未填写标题'), findsOneWidget);
    expect(find.text('别的流程'), findsNothing);
    expect(
      harness.sent.any((frame) =>
          frame['type'] == 'flow_run_list_req' && frame['name'] == 'dev'),
      isTrue,
    );

    await tester.tap(find.text('修好登录页'));
    await _settle(tester);
    expect(find.text('修好登录页'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a flow opens the editor directly', (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final harness = _Harness();
    addTearDown(harness.close);
    await _pump(tester, harness.client);

    await tester.tap(find.text('dev'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('detail-tab-overview')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-runs')), findsNothing);
    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(harness.sent.any((f) => f['type'] == 'flow_get_req'), isTrue);
    // 主机只给了空 ops：这台主机只读，所以没有保存按钮。
    expect(find.byKey(const ValueKey('save-button')), findsNothing);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
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
    // 窄屏详情：只读步骤，没有概览 / 运行 Tab。
    expect(find.text('设计：dev'), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-overview')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-runs')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-edit')), findsNothing);
    expect(find.byType(FlowDesignScreen), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
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
    // 窄屏 + 旧主机（没有编辑 ops）退回只读步骤页，只读提示要跟着换语言。
    expect(find.text('这台主机不支持编辑，当前只能查看'), findsOneWidget);

    locale.value = const Locale('en');
    await _settle(tester);
    expect(find.text('这台主机不支持编辑，当前只能查看'), findsNothing);
    expect(find.text('This host does not support editing; view only'),
        findsOneWidget);
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
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写}\nsteps:\n  - id: impl\n    task: {role: coder, prompt: 写}\n';
    addTearDown(harness.close);
    await _pump(tester, harness.client, agents: [agent]);

    await _startFromRow(tester, 'dev');
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
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写}\nsteps:\n  - id: impl\n    task: {role: coder, prompt: 写}\n';
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
      await _startFromRow(tester, 'dev');
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

  // ── A9-7：空缓存不算「已缓存」 ───────────────────────────────────────

  testWidgets('A9-7 首次空名单、agent 后同步出来：刷新后选择器能看到', (tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final harness = _Harness()
      ..flowYaml = 'flow: dev\nroles:\n  coder: {desc: 写}\nsteps:\n  - id: impl\n    task: {role: coder, prompt: 写}\n';
    addTearDown(harness.close);
    // 开机那一刻 peer agent 还没同步：缓存是一份空列表（非 null）。
    final agents = <RemoteAgent>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FlowWorkspaceScreen(
        peerId: 'p1',
        client: harness.client,
        embedded: true,
        initialAgents: agents,
      ),
    ));
    await _settle(tester);

    // 名单同步到了，但主机没换；刷新要重新拉一次候选。
    agents.add(_peerAgent('agent-late', '后同步 Agent', 'p1'));
    await tester.tap(find.byIcon(Icons.refresh));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> settleLong() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await _startFromRow(tester, 'dev');
    await settleLong();
    await tester.tap(find.byKey(const ValueKey('start-role-coder')));
    await settleLong();
    expect(find.text('后同步 Agent'), findsOneWidget,
        reason: '空缓存不能被当成命中，刷新后选择器必须看到新同步的 agent');
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
        tester.widget<FlowDetailScreen>(find.byType(FlowDetailScreen));
    expect(before.peerId, 'p1');
    expect(before.key.toString(), contains('p1'));

    activeHost = 'p2';
    await tester.tap(find.byIcon(Icons.refresh));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final after =
        tester.widget<FlowDetailScreen>(find.byType(FlowDetailScreen));
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

  /// 新版主机在 `flow_get_resp` 里带的「需要绑定的角色」。null = 老主机，
  /// 客户端要退回自己的保守扫描。
  List<String>? requiredRoles;

  /// 库里的流程名单。改它就能模拟「对话框打开期间别人建了同名流程」。
  List<Map<String, dynamic>> flows = [
    {'name': 'dev', 'latest': 3},
  ];

  /// 让 `flow_list_resp` 整体失败（例如库里有一个坏掉的 meta.json）。
  bool listFails = false;

  /// `flow_run_list_resp` 的运行。null 用一条默认的 `dev` / `run_1`。
  List<Map<String, dynamic>>? runs;

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
            'flow_run_list_req' => () {
                final requested = (frame['name'] as String?) ?? '';
                final all = runs ??
                    [
                      {
                        'run_id': 'run_1',
                        'flow': 'dev',
                        'status': 'succeeded',
                        'scope': 'lib',
                        'revision': 2,
                        'started_ms': 1700000000000,
                        'tasks_used': 3,
                      },
                    ];
                final shown = requested.isEmpty
                    ? all
                    : [
                        for (final run in all)
                          if (run['flow'] == requested) run,
                      ];
                return {
                  'type': 'flow_run_list_resp',
                  'success': true,
                  'runs': shown,
                };
              }(),
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
                if (requiredRoles != null) 'required_roles': requiredRoles,
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

/// 列表行不再有常驻「开始运行」按钮：从 `⋯` 菜单进开跑确认页。
/// PopupMenuButton 的弹层转场要 ~300ms，光 pump 一帧会点在动画外。
Future<void> _startFromRow(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('flow-more-$name')));
  await _settleMenu(tester);
  await tester.tap(find.byKey(ValueKey('flow-start-$name')));
  await _settleMenu(tester);
}

Future<void> _settleMenu(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
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

/// 开跑表单是整页路由（300ms 转场），180ms 不够它落位：宽窗口下右侧的
/// 「运行」按钮还会停在屏幕外，tap 会打空。
Future<void> _settleRoute(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
