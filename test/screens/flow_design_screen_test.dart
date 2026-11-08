import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/l10n/app_localizations.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/screens/flow_design_screen.dart';

const _baseYaml = 'steps:\n- id: impl\n  task: {prompt: 写}\n';

Map<String, dynamic> _node(String id, {Map<String, dynamic>? fields}) => {
      'key': id,
      'id': id,
      'kind': 'task',
      if (fields != null) 'fields': fields,
    };

/// 一个假主机：按帧类型回包，记下收到的帧。
class _FakeHost {
  _FakeHost() {
    client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        sentPeers.add(peerId);
        final reply = _reply(frame);
        if (reply != null) {
          bus.add(PeerControlEvent(peerId: peerId, data: {
            ...reply,
            'request_id': frame['request_id'],
          }));
        }
        return true;
      },
    );
  }

  final bus = StreamController<PeerControlEvent>.broadcast();
  final sent = <Map<String, dynamic>>[];

  /// 每个请求发往哪台主机（A6-1：切主机后保存要走新 peer）。
  final sentPeers = <String>[];
  late final HubFlow client;
  String editedPrompt = '写';
  bool dropNode = false;

  Map<String, dynamic>? _reply(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'flow_list_req':
        return {
          'type': 'flow_list_resp',
          'success': true,
          'flows': [
            {'name': 'helper', 'latest': 1},
          ],
        };
      case 'flow_get_req':
        return {
          'type': 'flow_get_resp',
          'success': true,
          'revision': 2,
          'yaml': _baseYaml,
        };
      case 'flow_schema_req':
        return {
          'type': 'flow_schema_resp',
          'success': true,
          'common': [
            {'name': 'desc', 'type': 'string', 'label': '说明'},
          ],
          'kinds': {
            'task': [
              {'name': 'task.prompt', 'type': 'text', 'label': '提示词'},
            ],
          },
          // 带 ops 才算"现在的主机"，否则能力探测会把整页判成只读。
          'ops': [
            'set',
            'insert',
            'move',
            'delete',
            'wrap',
            'unwrap',
            'retype',
            'header',
          ],
        };
      case 'flow_validate_req':
        // 主机回的是补过 id 的那份（正常就是提交的那份），草稿以它为准。
        return {
          'type': 'flow_validate_resp',
          'success': true,
          'yaml': (frame['yaml'] as String?) ?? _baseYaml,
          'tree': [
            _node('impl', fields: {
              'task': {'prompt': '写'}
            }),
          ],
          'diagnostics': [],
        };
      case 'flow_edit_req':
        final deleted = dropNode &&
            frame['ops'] is List &&
            (frame['ops'] as List).any(
              (op) => op is Map && op['op'] == 'delete',
            );
        if (deleted) {
          return {
            'type': 'flow_edit_resp',
            'success': true,
            'valid': true,
            'yaml': 'steps: []\n',
            'tree': <Map<String, dynamic>>[],
            'diagnostics': [],
          };
        }
        return {
          'type': 'flow_edit_resp',
          'success': true,
          'valid': true,
          'yaml': 'steps:\n- id: impl\n  task: {prompt: 认真写}\n',
          'tree': [
            _node('impl', fields: {
              'task': {'prompt': '认真写'}
            }),
          ],
          'diagnostics': [],
        };
      case 'flow_diff_req':
        return {
          'type': 'flow_diff_resp',
          'success': true,
          'nodes': [
            {
              'id': 'impl',
              'kind': 'task',
              'change': 'changed',
              'fields': [
                {'field': 'task.prompt', 'from': '写', 'to': '认真写'}
              ],
            },
          ],
          'header': [],
        };
      case 'flow_rehearse_req':
        return {
          'type': 'flow_rehearse_resp',
          'success': true,
          'rehearsal_id': 'reh_1',
          // 走到关卡：先派了一个活，然后停在那儿等人选。
          'status': 'running',
          'tasks_used': 1,
          'steps': [
            {'key': 'impl', 'attempt': 1}
          ],
          'question': {
            'kind': 'gate',
            'key': 'ok',
            'ask': '可以发吗',
            'options': ['通过', '返工'],
          },
          'done': false,
          'tree': [
            _node('impl'),
            {'key': 'ok', 'id': 'ok', 'kind': 'gate'},
          ],
        };
      case 'flow_rehearse_answer_req':
        return {
          'type': 'flow_rehearse_resp',
          'success': true,
          'rehearsal_id': 'reh_1',
          'status': 'succeeded',
          'tasks_used': 2,
          'steps': [
            {'key': 'impl', 'attempt': 1},
            {'key': 'ship', 'attempt': 1},
          ],
          'done': true,
          'tree': [_node('impl'), _node('ship')],
        };
      case 'flow_rehearse_drop_req':
        return {
          'type': 'flow_rehearse_resp',
          'success': true,
          'rehearsal_id': 'reh_1',
          'done': true,
        };
      case 'flow_save_req':
        return {
          'type': 'flow_save_resp',
          'success': true,
          'flow': {'latest': 3},
        };
    }
    return null;
  }
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 低频操作都收进了工具条的 `⋯` 菜单；弹层转场要等 ~300ms。
Future<void> _openMenu(WidgetTester tester, String itemKey) async {
  await tester.tap(find.byKey(const ValueKey('design-more')));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(find.byKey(ValueKey(itemKey)));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('editing a field sends a set op and redraws from the host tree',
      (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    expect(find.text('第 2 版'), findsOneWidget);
    // 没改动时不能保存。
    final save = find.byKey(const ValueKey('save-button'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(find.text('impl'));
    await _settle(tester);
    final promptField = find.byKey(const ValueKey('f:task.prompt'));
    expect(find.text('写'), findsWidgets);
    await tester.enterText(promptField, '认真写');
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
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    // 保存：成功后版本号跟着主机报的走，按钮又灰回去。
    await tester.tap(save);
    await _settle(tester);
    expect(host.sent.last['type'], 'flow_save_req');
    expect(host.sent.last['name'], 'dev');
    expect(find.text('第 3 版'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('the diff toggle marks changed nodes', (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('diff-toggle')));
    await _settle(tester);
    expect(find.text('1 处改动'), findsOneWidget);
    expect(find.text('有改动'), findsOneWidget);
    final diff = host.sent.firstWhere((f) => f['type'] == 'flow_diff_req');
    expect(diff['from_yaml'], _baseYaml);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('the source bar opens on desktop and checks the yaml on the host',
      (tester) async {
    final host = _FakeHost();
    // 桌面宽度：源码条在窄屏是只读的。
    tester.view.physicalSize = const Size(3000, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);

    await _openMenu(tester, 'yaml-bar');
    await _settle(tester);
    expect(find.byKey(const ValueKey('yaml-editor')), findsOneWidget);

    // 校验走主机：改完立刻发 flow_validate_req。
    await tester.tap(find.byKey(const ValueKey('yaml-validate')));
    await _settle(tester);
    expect(host.sent.any((f) => f['type'] == 'flow_validate_req'), isTrue);

    // 用这份：草稿换成改过的，可以保存了。
    await tester.enterText(find.byKey(const ValueKey('yaml-editor')),
        'steps:\n- id: impl\n  task: {prompt: "认真写"}\n');
    await tester.tap(find.byKey(const ValueKey('yaml-apply')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('yaml-editor')), findsNothing);
    final save = find.byKey(const ValueKey('save-button'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('rehearsal lights the steps in order and can be ended',
      (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
      // 每步 300ms：`_settle` 的 180ms 还在点亮中，能先看到"演练中"。
      stepInterval: const Duration(milliseconds: 300),
    )));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('rehearse-button')));
    await _settle(tester);
    expect(find.text('演练中：不调用任何 Agent'), findsOneWidget);
    // 节点依次点亮，点完停在关卡上摆出选项。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('走到这儿要你选一下'), findsOneWidget);
    expect(find.text('可以发吗'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    // 选一个选项：接着往下走，走完不再问。
    await tester.tap(find.byKey(const ValueKey('rehearse-通过')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('走到这儿要你选一下'), findsNothing);
    final answered =
        host.sent.firstWhere((f) => f['type'] == 'flow_rehearse_answer_req');
    expect(answered['rehearsal_id'], 'reh_1');
    expect(answered['choice'], '通过');

    await tester.tap(find.text('结束演练'));
    await tester.pump();
    expect(find.text('演练中：不调用任何 Agent'), findsNothing);
    // 结束演练要把主机上那份丢掉。
    expect(host.sent.any((f) => f['type'] == 'flow_rehearse_drop_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('A6-1: 同名流程切主机后，保存 / 校验都发往新 peer', (tester) async {
    final host = _FakeHost();
    Widget screen(String peerId) => FlowDesignScreen(
          peerId: peerId,
          name: 'dev',
          client: host.client,
        );
    await tester.pumpWidget(_app(screen('p1')));
    await _settle(tester);
    expect(host.sentPeers, isNotEmpty);
    expect(host.sentPeers.every((p) => p == 'p1'), isTrue);

    // 同名流程在两台主机上都存在：只换 peerId，ValueKey 不变。
    final beforeSwitch = host.sent.length;
    await tester.pumpWidget(_app(screen('p2')));
    await _settle(tester);
    expect(host.sent.length, greaterThan(beforeSwitch),
        reason: '切主机要重建 controller 并重新加载定义 / 引用');
    expect(host.sentPeers.sublist(beforeSwitch).every((p) => p == 'p2'), isTrue,
        reason: '旧 peerId 不能残留在 controller 里');

    await tester.tap(find.text('impl'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '认真写');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _settle(tester);
    final save = find.byKey(const ValueKey('save-button'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await _settle(tester);

    final saveIdx =
        host.sent.lastIndexWhere((f) => f['type'] == 'flow_save_req');
    expect(saveIdx, greaterThanOrEqualTo(beforeSwitch));
    expect(host.sentPeers[saveIdx], 'p2', reason: '保存必须发往新主机');
    expect(
        host.sentPeers.sublist(beforeSwitch).every((p) => p == 'p2'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('undo puts the previous prompt back', (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    await tester.tap(find.text('impl'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '认真写');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('undo')));
    await _settle(tester);
    expect(find.text('写'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('an invalid prompt stays until the second leave', (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    await tester.tap(find.text('impl'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('f:task.prompt')), '');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('header-open')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('f:task.prompt')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('header-open')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('f:task.prompt')), findsNothing);
    expect(find.text('流程设置'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('deleting the selected node falls back to flow settings',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = _FakeHost()..dropNode = true;
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    await tester.tap(find.text('impl'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('del-impl')));
    await tester.tap(find.byKey(const ValueKey('del-impl')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, '删除这一步'));
    await _settle(tester);
    expect(find.text('impl'), findsNothing);
    expect(find.text('流程设置'), findsWidgets);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });

  testWidgets('a 700-wide page keeps the tree and overlays the panel',
      (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
    )));
    await _settle(tester);
    expect(find.byKey(const ValueKey('flow-node-tree')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-close')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });
}
