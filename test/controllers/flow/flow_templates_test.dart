import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_templates.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  test('模板名单和主机的内置模板对齐', () {
    // 主机 `crates/api/src/flow/builtin.rs::templates()` 的三个。
    expect(
      FlowTemplateCatalog.builtins.map((e) => e.id),
      ['builtin-review-loop', 'builtin-stage-gate', 'builtin-lead'],
    );
    for (final entry in FlowTemplateCatalog.builtins) {
      expect(entry.titleZh.isNotEmpty, isTrue);
      expect(entry.blurbEn.isNotEmpty, isTrue);
    }
  });

  testWidgets('从模板建：先取定义，再用 header 改名', (tester) async {
    final bus = StreamController<PeerControlEvent>.broadcast();
    addTearDown(bus.close);
    final sent = <Map<String, dynamic>>[];
    final client = HubFlow(
      events: bus.stream,
      send: (peerId, frame) async {
        sent.add(frame);
        final reply = switch (frame['type']) {
          'flow_get_req' => {
              'type': 'flow_get_resp',
              'success': true,
              'revision': 1,
              'yaml': 'flow: builtin-review-loop\nsteps: []\n',
            },
          'flow_edit_req' => {
              'type': 'flow_edit_resp',
              'success': true,
              'valid': true,
              'yaml': 'flow: mine\nsteps: []\n',
              'tree': [],
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

    final source = await FlowFlowFrom.sourceYaml(
      client,
      'p1',
      '',
      'builtin-review-loop',
    );
    expect(source, 'flow: builtin-review-loop\nsteps: []\n');

    final renamed = await FlowFlowFrom.rename(client, 'p1', source!, 'mine');
    expect(renamed, 'flow: mine\nsteps: []\n');

    // 改名是一个 header 操作 —— 不在客户端改 YAML（flow 字段不给用户在表单改）。
    final edit = sent.lastWhere((f) => f['type'] == 'flow_edit_req');
    expect(edit['ops'], [
      {'op': 'header', 'field': 'flow', 'value': 'mine'},
    ]);
  });
}
