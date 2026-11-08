import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';
import 'package:shepaw/screens/flow_workspace_screen.dart';

/// 手机端也能编辑工作流：完整编辑 + 新建/复制/删除流程 + 点选说话并存。
///
/// 手机布局靠 `LayoutUtils.isDesktopLayout`（窄窗口 + 非桌面 OS）判定，
/// 用例统一把物理尺寸设成 400×800、devicePixelRatio 1。
const _yaml = 'flow: dev\nsteps:\n- id: impl\n  task: {prompt: 写}\n';

Map<String, dynamic> _node(String id) => {
      'key': id,
      'id': id,
      'kind': 'task',
      'fields': {
        'task': {'prompt': '写'}
      },
    };

/// 假主机：按帧回包并记下发出的帧。`editable` 控制 schema 的 ops，
/// 用来模拟「旧主机不支持编辑」的降级路径。
class _Host {
  _Host({this.editable = true, this.emptyTree = false, this.twoNodes = false});

  final bool editable;
  final bool emptyTree;
  final bool twoNodes;
  final sent = <Map<String, dynamic>>[];
  final bus = StreamController<PeerControlEvent>.broadcast();
  List<Map<String, dynamic>> diagnostics = const [];
  List<Map<String, dynamic>> flows = [
    {'name': 'dev', 'latest': 2, 'description': '开发流程'},
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

  Map<String, dynamic>? _reply(Map<String, dynamic> frame) =>
      switch (frame['type']) {
        'flow_list_req' => {
            'type': 'flow_list_resp',
            'success': true,
            'flows': flows,
          },
        'flow_run_list_req' => {
            'type': 'flow_run_list_resp',
            'success': true,
            'runs': <dynamic>[],
          },
        'flow_get_req' => {
            'type': 'flow_get_resp',
            'success': true,
            'revision': 2,
            'yaml': emptyTree ? 'flow: dev\nsteps: []\n' : _yaml,
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
                    'header',
                  ]
                : <String>[],
          },
        'flow_validate_req' => {
            'type': 'flow_validate_resp',
            'success': true,
            'yaml': (frame['yaml'] as String?) ?? _yaml,
            'tree': emptyTree
                ? <dynamic>[]
                : twoNodes
                    ? [_node('impl'), _node('review')]
                    : [_node('impl')],
            'diagnostics': diagnostics,
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
        'flow_delete_req' => {
            'type': 'flow_delete_resp',
            'success': true,
          },
        'flow_diff_req' => {
            'type': 'flow_diff_resp',
            'success': true,
            'nodes': <dynamic>[],
            'header': <dynamic>[],
          },
        _ => null,
      };

  void close() => unawaited(bus.close());
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 底部弹层有转场动画，多泵几帧再点条目。
Future<void> _settleSheet(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _openFlow(
  WidgetTester tester,
  _Host host, {
  String scope = '',
}) async {
  await tester.pumpWidget(_app(FlowWorkspaceScreen(
    peerId: 'p1',
    client: host.client,
    scope: scope,
    initialAgents: const [],
  )));
  await _settle(tester);
  await tester.tap(find.text('dev'));
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('手机点进流程能编辑：点节点开整页，改提示词发出 set op', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await _openFlow(tester, host);

    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('save-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    // compact 行：行尾只留 ⋯，没有五个按钮。
    expect(find.byKey(const ValueKey('after-impl')), findsNothing);
    expect(find.byKey(const ValueKey('del-impl')), findsNothing);
    expect(find.byKey(const ValueKey('menu-impl')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-editor-close')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '认真写');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _settle(tester);
    final edit = host.sent.firstWhere((f) => f['type'] == 'flow_edit_req');
    expect(edit['ops'], [
      {
        'op': 'set',
        'node_id': 'impl',
        'field': 'task.prompt',
        'value': '认真写',
      }
    ]);

    // 关掉整页退回大纲，改动还在（save 可点）。
    await tester.tap(find.byKey(const ValueKey('phone-editor-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-button')))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机整页关掉时先交出正在编辑的文本', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await _openFlow(tester, host);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);

    // 故意不手动 unfocus：直接点关闭，最后一段输入也必须发出去。
    await tester.enterText(
        find.byKey(const ValueKey('f:task.prompt')), '没失焦就关');
    await tester.tap(find.byKey(const ValueKey('phone-editor-close')));
    await _settle(tester);
    final edit = host.sent.firstWhere((f) => f['type'] == 'flow_edit_req');
    expect(edit['ops'], [
      {
        'op': 'set',
        'node_id': 'impl',
        'field': 'task.prompt',
        'value': '没失焦就关',
      }
    ]);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机 ⋯ 菜单能加一步，也能流程设置', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await _openFlow(tester, host);

    await tester.tap(find.byKey(const ValueKey('menu-impl')));
    await _settleSheet(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('在后面加一步'));
    await _settleSheet(tester);
    final edit = host.sent.firstWhere((f) => f['type'] == 'flow_edit_req');
    expect((edit['ops'] as List).first['op'], 'insert');

    // 点顶部的流程卡片打开流程设置整页。
    await tester.tap(find.byKey(const ValueKey('flow-title')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机 ⋯ 菜单补上移 / 下移，能重排步骤', (tester) async {
    await _phone(tester);
    final host = _Host(twoNodes: true);
    addTearDown(host.close);
    await _openFlow(tester, host);

    await tester.tap(find.byKey(const ValueKey('menu-impl')));
    await _settleSheet(tester);
    expect(find.text('下移'), findsOneWidget);
    await tester.tap(find.text('下移'));
    await _settleSheet(tester);
    final edit = host.sent.firstWhere((f) => f['type'] == 'flow_edit_req');
    expect((edit['ops'] as List).first['op'], 'move');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空流程在手机上有「添加第一步」', (tester) async {
    await _phone(tester);
    final host = _Host(emptyTree: true);
    addTearDown(host.close);
    await _openFlow(tester, host);

    final add = find.byKey(const ValueKey('phone-add-first-step'));
    expect(add, findsOneWidget);
    await tester.tap(add);
    await _settle(tester);
    final edit = host.sent.firstWhere((f) => f['type'] == 'flow_edit_req');
    expect((edit['ops'] as List).first['op'], 'insert');
    expect((edit['ops'] as List).first['parent_id'], '');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点选说话与编辑并存：选择模式下点行只切选中', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    // 群库流程才有说话条。
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      scope: 'group:g1',
      groupId: 'g1',
      client: host.client,
    )));
    await _settle(tester);

    expect(find.byKey(const ValueKey('steps-select')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('steps-select')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('pick-impl')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('sel-impl')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);
    expect(find.byKey(const ValueKey('talk-input')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('sel-impl')), findsNothing);

    // 退出选择模式后点行就回到编辑。
    await tester.tap(find.byKey(const ValueKey('steps-select')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧主机（没有编辑 ops）在手机上仍退回只读步骤页', (tester) async {
    await _phone(tester);
    final host = _Host(editable: false);
    addTearDown(host.close);
    await _openFlow(tester, host);

    expect(find.byType(FlowDesignScreen), findsNothing);
    expect(find.byKey(const ValueKey('save-button')), findsNothing);
    expect(find.byKey(const ValueKey('flow-steps-tree')), findsOneWidget);
    expect(find.text('这台主机不支持编辑，当前只能查看'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机能从列表新建流程（对话框不溢出，create_only 写库）', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await tester.pumpWidget(_app(FlowWorkspaceScreen(
      peerId: 'p1',
      client: host.client,
      initialAgents: const [],
    )));
    await _settle(tester);

    await tester.tap(find.byTooltip('新建'));
    await _settleSheet(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('new-flow-name')), 'mobile_flow');
    await tester.tap(find.byKey(const ValueKey('new-flow-create')));
    await _settleSheet(tester);
    final saves = host.sent.where((f) => f['type'] == 'flow_save_req').toList();
    expect(saves, isNotEmpty);
    expect(saves.last['name'], 'mobile_flow');
    expect(saves.last['create_only'], true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机列表能新建，也能确认删除流程', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await tester.pumpWidget(_app(FlowWorkspaceScreen(
      peerId: 'p1',
      client: host.client,
      initialAgents: const [],
    )));
    await _settle(tester);

    expect(find.byTooltip('新建'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-more-dev')));
    await _settleSheet(tester);
    expect(find.byKey(const ValueKey('flow-delete-dev')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-delete-dev')));
    await _settleSheet(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('删除流程'),
    ));
    await _settle(tester);
    expect(host.sent.any((f) => f['type'] == 'flow_delete_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  // ── 复审发现的问题：回归用例 ───────────────────────────────────────────────

  testWidgets('系统返回只关手机整页，不把整个详情一起退掉', (tester) async {
    await _phone(tester);
    final host = _Host();
    addTearDown(host.close);
    await _openFlow(tester, host);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsNothing);
    // 详情还在：两个 PopScope 都被通知到，外层不能顺手退列表。
    expect(find.byType(FlowDesignScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机点诊断「定位」会打开整页属性', (tester) async {
    await _phone(tester);
    final host = _Host()
      ..diagnostics = [
        {
          'severity': 'error',
          'at': 'impl',
          'message': '缺提示词',
        },
      ];
    addTearDown(host.close);
    await _openFlow(tester, host);

    final diag = find.byKey(const ValueKey('diag-impl-缺提示词'));
    expect(diag, findsOneWidget);
    await tester.tap(diag);
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('f:task.prompt')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('退出选择模式后点节点能直接改字段，不被多选摘要挡住', (tester) async {
    await _phone(tester);
    final host = _Host(twoNodes: true);
    addTearDown(host.close);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      scope: 'group:g1',
      groupId: 'g1',
      client: host.client,
    )));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('steps-select')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await tester.tap(find.byKey(const ValueKey('row-review')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('sel-impl')), findsOneWidget);
    expect(find.byKey(const ValueKey('sel-review')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('steps-select')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('row-impl')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-properties-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('f:task.prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('multi-summary')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('先在桌面打开过设计页，手机群流程仍会显示一次性提示', (tester) async {
    final desktop = _Host();
    addTearDown(desktop.close);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: desktop.client,
    )));
    await _settle(tester);
    await tester.pumpWidget(const SizedBox());

    await _phone(tester);
    final phone = _Host();
    addTearDown(phone.close);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      scope: 'group:g1',
      groupId: 'g1',
      client: phone.client,
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('phone-select-hint')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
