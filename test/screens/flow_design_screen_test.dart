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
        };
      case 'flow_validate_req':
        return {
          'type': 'flow_validate_resp',
          'success': true,
          'yaml': _baseYaml,
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
          'status': 'succeeded',
          'tasks_used': 1,
          'steps': [
            {'key': 'impl', 'attempt': 1}
          ],
          'tree': [_node('impl')],
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

  testWidgets('rehearsal lights the steps in order and can be ended',
      (tester) async {
    final host = _FakeHost();
    await tester.pumpWidget(_app(FlowDesignScreen(
      peerId: 'p1',
      name: 'dev',
      client: host.client,
      stepInterval: const Duration(milliseconds: 50),
    )));
    await _settle(tester);
    await tester.tap(find.byTooltip('演练'));
    await _settle(tester);
    expect(find.text('演练中：不调用任何 Agent'), findsOneWidget);
    // 走完后节点是完成。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.text('结束演练'));
    await tester.pump();
    expect(find.text('演练中：不调用任何 Agent'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await host.bus.close();
  });
}
