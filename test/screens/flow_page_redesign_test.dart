import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/models/flow_models.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';
import 'package:shepaw/screens/flow_start_screen.dart';
import 'package:shepaw/screens/flow_workspace_screen.dart';
import 'package:shepaw/widgets/flow/flow_runs_pane.dart';

/// 流程库交互重设计的回归用例（方案 workflow-page-redesign.md 第六章）。
///
/// 覆盖：列表行状态 / 空库入口、点进流程直接编辑与开跑确认、演练与运行区分、
/// 工具条保存状态、属性侧栏、草稿横幅、运行分组、窄屏只读步骤、旧主机兼容。
const _yaml = 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 写}\n';

Map<String, dynamic> _node(String id) => {
      'key': id,
      'id': id,
      'kind': 'task',
      'fields': {
        'task': {'prompt': '写'}
      },
    };

class _Host {
  _Host({this.editable = true, this.flows});

  final bool editable;
  List<Map<String, dynamic>>? flows;
  List<Map<String, dynamic>> runs = const [];
  String yaml = _yaml;
  final sent = <Map<String, dynamic>>[];
  final bus = StreamController<PeerControlEvent>.broadcast();

  List<Map<String, dynamic>> get library =>
      flows ??
      [
        {
          'name': 'dev',
          'latest': 2,
          'description': '开发流程',
          'updated_ms': DateTime.now().millisecondsSinceEpoch,
        },
      ];

  HubFlow get client => HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          sent.add(frame);
          final reply = _reply(frame);
          if (reply != null) {
            bus.add(PeerControlEvent(
                peerId: peerId,
                data: {...reply, 'request_id': frame['request_id']}));
          }
          return true;
        },
      );

  Map<String, dynamic>? _reply(Map<String, dynamic> frame) {
    return switch (frame['type']) {
      'flow_list_req' => {
          'type': 'flow_list_resp',
          'success': true,
          'flows': library,
        },
      'flow_run_list_req' => {
          'type': 'flow_run_list_resp',
          'success': true,
          'runs': runs,
        },
      'flow_get_req' => {
          'type': 'flow_get_resp',
          'success': true,
          'revision': 2,
          'yaml': yaml,
          'required_roles': <String>[],
        },
      'flow_schema_req' => {
          'type': 'flow_schema_resp',
          'success': true,
          'common': <dynamic>[],
          'kinds': {
            'task': [
              {'name': 'task.prompt', 'type': 'text', 'label': '提示词'},
            ],
          },
          'ops': editable
              ? [
                  'set',
                  'insert',
                  'move',
                  'delete',
                  'wrap',
                  'unwrap',
                  'retype',
                  'header'
                ]
              : <String>[],
        },
      'flow_validate_req' => {
          'type': 'flow_validate_resp',
          'success': true,
          'yaml': (frame['yaml'] as String?) ?? yaml,
          'tree': [_node('impl')],
          'diagnostics': <dynamic>[],
        },
      'flow_edit_req' => {
          'type': 'flow_edit_resp',
          'success': true,
          'valid': true,
          'yaml': 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 改了}\n',
          'tree': [_node('impl')],
          'diagnostics': <dynamic>[],
        },
      'flow_save_req' => {
          'type': 'flow_save_resp',
          'success': true,
          'flow': {'name': 'dev', 'latest': 3},
        },
      'flow_diff_req' => {
          'type': 'flow_diff_resp',
          'success': true,
          'nodes': <dynamic>[],
          'header': <dynamic>[],
        },
      'flow_rehearse_req' => {
          'type': 'flow_rehearse_resp',
          'success': true,
          'rehearsal_id': 'reh_1',
          'status': 'running',
          'tasks_used': 1,
          'steps': [
            {'key': 'impl', 'attempt': 1}
          ],
          'done': false,
          'tree': [_node('impl')],
        },
      'flow_rehearse_drop_req' => {
          'type': 'flow_rehearse_resp',
          'success': true,
          'rehearsal_id': 'reh_1',
          'done': true,
        },
      'flow_run_start_req' => {
          'type': 'flow_run_start_resp',
          'success': true,
          'run_id': 'run_new',
        },
      'flow_run_get_req' => {
          'type': 'flow_run_get_resp',
          'success': true,
          'run_id': 'run_new',
          'status': 'running',
          'tasks_used': 0,
          'tree': <dynamic>[],
        },
      _ => null,
    };
  }

  Future<void> close() => bus.close();
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _settleMenu(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpWorkspace(WidgetTester tester, _Host host) async {
  await tester.pumpWidget(_app(FlowWorkspaceScreen(
    peerId: 'p1',
    client: host.client,
    initialAgents: const [],
  )));
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('列表行：状态点 / 说明 / 无常驻开跑按钮，空库给模板入口', (tester) async {
    final host = _Host(flows: [
      {'name': 'dev', 'latest': 2, 'last_run_status': 'running'},
      {
        'name': 'broken',
        'latest': 4,
        'last_run_status': 'failed',
        'description': '会失败的流程',
      },
      {
        'name': 'needs-me',
        'latest': 1,
        'last_run_status': 'running',
        'last_run_needs_approval': true,
        'last_run_id': 'run_waiting',
      },
    ]);
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);

    // 开跑入口收进 `⋯`，不再每行常驻。
    expect(find.byKey(const ValueKey('flow-start-dev')), findsNothing);
    expect(find.byKey(const ValueKey('flow-more-dev')), findsOneWidget);
    expect(find.byTooltip('运行中'), findsOneWidget);
    expect(find.byTooltip('最近失败'), findsOneWidget);
    expect(find.text('待审批'), findsOneWidget);
    // 徽标直接带去那次运行（手机上也能审批）。
    expect(
        find.byKey(const ValueKey('flow-approval-needs-me')), findsOneWidget);
    expect(find.text('会失败的流程'), findsOneWidget);
    // 没有说明的流程回退到版本号。
    expect(find.text('第 2 版'), findsOneWidget);

    // 空库：给「从模板新建」入口。
    host.flows = [];
    await tester.tap(find.byIcon(Icons.refresh));
    await _settle(tester);
    expect(find.byKey(const ValueKey('library-from-template')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('新 App + 旧主机（无可选字段）只回退信息，页面仍可用', (tester) async {
    final host = _Host(flows: [
      {'name': 'dev', 'latest': 2},
    ]);
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);

    expect(find.text('第 2 版'), findsOneWidget);
    expect(find.byTooltip('运行中'), findsNothing);
    expect(find.byTooltip('最近失败'), findsNothing);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);
    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点进流程直接编辑；开始运行必经确认面板，取消不产生运行', (tester) async {
    final host = _Host();
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);

    await tester.tap(find.text('dev'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-executions-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);
    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-tab-overview')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-edit')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-runs')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('flow-more-dev')));
    await _settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('flow-start-dev')));
    await _settleMenu(tester);
    expect(find.byType(FlowStartScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('start-confirm-banner')), findsOneWidget);
    expect(find.text('这会真实调用 Agent 并发送消息；演练不会产生真实调用。'), findsOneWidget);
    expect(find.text('这次要绑定的角色'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(host.sent.any((f) => f['type'] == 'flow_run_start_req'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('演练与运行图标/文案不同，演练期间有持续提示条', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = _Host();
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rehearse-button')),
        matching: find.byIcon(Icons.science_outlined),
      ),
      findsOneWidget,
    );
    expect(find.text('演练'), findsWidgets);
    expect(find.text('开始运行'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('rehearse-button')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('rehearsal-banner')), findsOneWidget);
    expect(find.text('演练中 · 不会产生真实调用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('工具条：主区仅四个操作 + ⋯，保存状态文字跟着变', (tester) async {
    final host = _Host();
    addTearDown(host.close);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('save-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('rehearse-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('redo')), findsOneWidget);
    expect(find.byKey(const ValueKey('design-more')), findsOneWidget);
    expect(find.text('已保存第 2 版'), findsOneWidget);
    // 低频操作不在主区。对比不再是一个开关，有改动时自己出现。
    expect(find.byKey(const ValueKey('history-open')), findsNothing);
    expect(find.byKey(const ValueKey('diff-toggle')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('design-more')));
    await _settleMenu(tester);
    expect(find.byKey(const ValueKey('history-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('header-open')), findsNothing);
    expect(find.byKey(const ValueKey('flow-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('yaml-bar')), findsOneWidget);
    // 点弹层外的空白处收起菜单，后面的编辑操作才不会被遮住。
    await tester.tapAt(const Offset(2, 2));
    await _settleMenu(tester);

    // 改一个字段 → 未保存；保存 → 已保存第 3 版。
    await tester.tap(find.text('impl'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '认真写');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _settle(tester);
    expect(find.text('● 未保存的改动'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-button')));
    await _settle(tester);
    expect(find.text('已保存第 3 版'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('侧栏只有属性：点组件才展开，源码走对话框，节点树还在', (tester) async {
    final host = _Host();
    addTearDown(host.close);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-tab-properties')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-tab-problems')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-tab-rehearsal')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-tab-source')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-close')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-open')), findsNothing);
    // 点进流程就打开流程设置，不用再点「打开侧栏」。
    expect(find.text('流程设置'), findsWidgets);

    await tester.tap(find.text('impl'));
    await _settle(tester);
    expect(
        find.byKey(const ValueKey('drawer-properties-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('f:task.prompt')), findsOneWidget);
    expect(find.text('属性'), findsNothing);
    expect(find.byKey(const ValueKey('drawer-close')), findsNothing);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('design-more')));
    await _settleMenu(tester);
    await tester.tap(find.byKey(const ValueKey('yaml-bar')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('yaml-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-tab-source')), findsNothing);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('草稿恢复是概览横幅，不再进入时弹窗', (tester) async {
    SharedPreferences.setMockInitialValues({
      'flow_draft_v1|p1||dev': jsonEncode({
        'yaml': 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 改过}\n',
        'base_revision': 2,
        'saved_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    final host = _Host();
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);

    expect(find.byType(AlertDialog), findsNothing, reason: '恢复草稿不能再用阻塞式弹窗');
    expect(find.byKey(const ValueKey('draft-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('draft-restore')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draft-discard')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('draft-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机上未保存草稿提示单独占一行，按钮不会被缩小', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'flow_draft_v1|p1||dev': jsonEncode({
        'yaml': 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 改过}\n',
        'base_revision': 2,
        'saved_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    });
    final host = _Host();
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);

    final status = tester.getRect(find.byKey(const ValueKey('save-status')));
    final banner = tester.getRect(find.byKey(const ValueKey('draft-banner')));
    final restore = tester.getRect(find.byKey(const ValueKey('draft-restore')));
    expect(banner.top, greaterThanOrEqualTo(status.bottom - 1),
        reason: '提示要在保存状态下面单独一行');
    expect(banner.width, greaterThan(300), reason: '这一行要铺开，不能缩成一小粒');
    expect(restore.height, greaterThanOrEqualTo(32),
        reason: '恢复按钮要保持能点的高度');
    await tester.tap(find.byKey(const ValueKey('draft-restore')));
    await _settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机从执行历史进编辑页：没有概览 / 运行 Tab，保存和步骤都在', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = _Host();
    addTearDown(host.close);
    await _pumpWorkspace(tester, host);
    await tester.tap(find.text('dev'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-executions-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('executions-edit')));
    await _settle(tester);

    expect(find.byKey(const ValueKey('detail-tab-overview')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-steps')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-runs')), findsNothing);
    expect(find.byKey(const ValueKey('detail-tab-edit')), findsNothing);
    // 手机和桌面共用同一个编辑面：能保存，能点步骤，只是属性换成整页。
    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('save-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    expect(find.byKey(const ValueKey('row-impl')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('运行分组：需要你处理 > 运行中 > 已结束', () {
    expect(
        FlowRunSummary(runId: 'a', flow: 'dev', status: 'waiting_user').group,
        FlowRunGroup.attention);
    expect(FlowRunSummary(runId: 'b', flow: 'dev', status: 'running').group,
        FlowRunGroup.running);
    expect(FlowRunSummary(runId: 'c', flow: 'dev', status: 'succeeded').group,
        FlowRunGroup.finished);
    expect(FlowRunSummary(runId: 'd', flow: 'dev', status: 'failed').group,
        FlowRunGroup.finished);
  });

  testWidgets('运行列表把「需要你处理」置顶', (tester) async {
    final host = _Host()
      ..runs = [
        {
          'run_id': 'done_1',
          'flow': 'dev',
          'status': 'succeeded',
          'started_ms': 1700000000000,
        },
        {
          'run_id': 'wait_1',
          'flow': 'dev',
          'status': 'waiting_user',
          'started_ms': 1700000001000,
        },
        {
          'run_id': 'live_1',
          'flow': 'dev',
          'status': 'running',
          'started_ms': 1700000002000,
        },
      ];
    addTearDown(host.close);
    await tester.pumpWidget(_app(Scaffold(
      body: FlowRunsPane(
        client: host.client,
        peerId: 'p1',
        name: 'dev',
      ),
    )));
    await _settle(tester);

    final attention =
        tester.getCenter(find.byKey(const ValueKey('runs-group-attention'))).dy;
    final running =
        tester.getCenter(find.byKey(const ValueKey('runs-group-running'))).dy;
    final finished =
        tester.getCenter(find.byKey(const ValueKey('runs-group-finished'))).dy;
    expect(attention, lessThan(running));
    expect(running, lessThan(finished));
    expect(find.text('需要你处理'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
