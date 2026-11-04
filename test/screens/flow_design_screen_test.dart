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
  late final HubFlow client;
  String editedPrompt = '写';

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
    final save = find.widgetWithIcon(IconButton, Icons.check);
    expect(tester.widget<IconButton>(save).onPressed, isNull);

    await tester.tap(find.text('impl'));
    await _settle(tester);
    final promptField = find.byKey(const ValueKey('f:task.prompt'));
    expect(find.text('写'), findsWidgets);
    await tester.enterText(promptField, '认真写');
    // 客户端补充字段让检查器变高了，应用按钮可能滚出屏幕。
    await tester.ensureVisible(find.byKey(const ValueKey('inspector-apply')));
    await tester.tap(find.byKey(const ValueKey('inspector-apply')));
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
    expect(tester.widget<IconButton>(save).onPressed, isNotNull);

    // 保存：成功后版本号跟着主机报的走，按钮又灰回去。
    await tester.tap(save);
    await _settle(tester);
    expect(host.sent.last['type'], 'flow_save_req');
    expect(host.sent.last['name'], 'dev');
    expect(find.text('第 3 版'), findsOneWidget);
    expect(tester.widget<IconButton>(save).onPressed, isNull);
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
    await tester.tap(find.byTooltip('与上一版对比'));
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

    await tester.tap(find.byKey(const ValueKey('yaml-bar')));
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
    final save = find.widgetWithIcon(IconButton, Icons.check);
    expect(tester.widget<IconButton>(save).onPressed, isNotNull);
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
    await tester.tap(find.byTooltip('演练'));
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
    final answered = host.sent
        .firstWhere((f) => f['type'] == 'flow_rehearse_answer_req');
    expect(answered['rehearsal_id'], 'reh_1');
    expect(answered['choice'], '通过');

    await tester.tap(find.text('结束演练'));
    await tester.pump();
    expect(find.text('演练中：不调用任何 Agent'), findsNothing);
    // 结束演练要把主机上那份丢掉。
    expect(
        host.sent.any((f) => f['type'] == 'flow_rehearse_drop_req'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });
}
