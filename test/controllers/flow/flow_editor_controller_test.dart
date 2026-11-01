import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_editor_controller.dart';
import 'package:shepaw/controllers/flow/flow_editor_notice.dart';
import 'package:shepaw/peer/services/hub_flow.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';

void main() {
  test('三次按键合并成一个 flow_edit_req', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '一');
    c.setField('a', 'desc', '一二');
    c.setField('a', 'desc', '一二三');
    // 还在防抖窗口里：一个请求都没发。
    expect(harness.sent.where((f) => f['type'] == 'flow_edit_req'), isEmpty);
    await _pastDebounce();
    final edits = harness.sent.where((f) => f['type'] == 'flow_edit_req');
    expect(edits.length, 1);
    // 同一个字段只留最后一次的值。
    expect(edits.single['ops'], [
      {'op': 'set', 'node_id': 'a', 'field': 'desc', 'value': '一二三'},
    ]);
  });

  test('主机没应答：状态不动，挂起的改动留着', () async {
    final harness = _Harness()..reachable = false;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final before = c.yaml;

    c.setField('a', 'desc', '改了');
    await _pastDebounce();

    expect(c.yaml, before);
    expect(c.hasPending, isTrue);
    expect(c.offline, isTrue);
    expect(harness.notices.single.kind, FlowEditorNoticeKind.hostNoReply);
  });

  test('主机拒了整批：状态不动，挂起的改动留着', () async {
    final harness = _Harness()..rejectEdits = true;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final before = c.yaml;

    c.setField('a', 'desc', '改了');
    await _pastDebounce();

    expect(c.yaml, before);
    expect(c.hasPending, isTrue);
    expect(harness.notices.single.kind, FlowEditorNoticeKind.editRejected);
  });

  test('撤销不额外发请求，三元组一起退回去', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final before = c.yaml;
    final treeBefore = c.tree;

    c.setField('a', 'desc', '改了');
    await _pastDebounce();
    expect(c.yaml, 'flow: dev\nsteps: []\n# edited\n');
    expect(c.canUndo, isTrue);

    final sentBefore = harness.sent.length;
    await c.undo();
    expect(c.yaml, before);
    expect(c.tree, treeBefore);
    // 撤销是纯本地的：快照里带着树和诊断，不用再问主机。
    expect(harness.sent.length, sentBefore);
  });

  test('源码「用这份」把树和诊断一起换掉（不再只换 YAML）', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    await c.applySource('flow: dev\nsteps: []\n# from source\n', null);

    expect(c.yaml, 'flow: dev\nsteps: []\n# from source\n');
    // 主机这一版带两条诊断：界面必须立刻看到，而不是停在改之前的树。
    expect(c.diagnostics.length, 2);
    expect(c.tree.single.id, 'from-source');
  });

  test('头上的字段走 header 操作，且立即发送', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setHeader('limits.max_tasks', 30);
    await _pastDebounce();
    final edits = harness.sent.where((f) => f['type'] == 'flow_edit_req');
    expect(edits.length, 1);
    expect(edits.single['ops'], [
      {'op': 'header', 'field': 'limits.max_tasks', 'value': 30},
    ]);
  });
}

Future<void> _pastDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

/// 假主机：按帧类型回固定应答，记下所有请求。
class _Harness {
  _Harness();

  bool reachable = true;
  bool rejectEdits = false;
  final List<Map<String, dynamic>> sent = [];
  final List<FlowEditorNotice> notices = [];
  final StreamController<PeerControlEvent> bus =
      StreamController<PeerControlEvent>.broadcast();

  HubFlow get client => HubFlow(
        events: bus.stream,
        send: (peerId, frame) async {
          sent.add(Map<String, dynamic>.from(frame));
          if (!reachable) return false;
          final reply = switch (frame['type']) {
            'flow_get_req' => {
                'type': 'flow_get_resp',
                'success': true,
                'revision': 3,
                'yaml': 'flow: dev\nsteps: []\n',
              },
            'flow_schema_req' => {
                'type': 'flow_schema_resp',
                'success': true,
                'common': [],
                'kinds': {},
              },
            'flow_validate_req' => _validate(frame['yaml'] as String? ?? ''),
            'flow_edit_req' => rejectEdits
                ? {
                    'type': 'flow_edit_resp',
                    'success': false,
                    'error': '第 1 个操作：没有节点 `a`',
                  }
                : {
                    // `type` 放最后：_validate 里也有 type，spread 会盖掉它。
                    ..._validate('flow: dev\nsteps: []\n# edited\n'),
                    'type': 'flow_edit_resp',
                    'success': true,
                    'valid': true,
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

  Map<String, dynamic> _validate(String yaml) {
    final fromSource = yaml.contains('from source');
    return {
      'type': 'flow_validate_resp',
      'success': true,
      'yaml': yaml,
      'tree': [
        {
          'key': fromSource ? 'from-source' : 'a',
          'id': fromSource ? 'from-source' : 'a',
          'kind': 'task',
          'children': [],
        },
      ],
      'diagnostics': fromSource
          ? [
              {'at': 'a', 'severity': 'error', 'message': '缺 prompt'},
              {'at': '', 'severity': 'warning', 'message': '没有描述'},
            ]
          : [],
    };
  }

  Future<FlowEditorController> controller() async {
    final c = FlowEditorController(
      peerId: 'p1',
      name: 'dev',
      client: client,
    );
    c.onNotice = notices.add;
    await c.load();
    return c;
  }

  Future<void> close() async {
    await bus.close();
  }
}
