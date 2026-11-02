import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_editor_controller.dart';
import 'package:shepaw/controllers/flow/flow_editor_notice.dart';
import 'package:shepaw/controllers/flow/flow_host_caps.dart';
import 'package:shepaw/peer/models/flow_models.dart';
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

  test('在途期间打的字不会被清掉，回包后接着发', () async {
    final harness = _Harness()..delay = const Duration(milliseconds: 200);
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '一', immediate: true);
    // 请求还在路上，用户继续打字。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.setField('a', 'desc', '一二');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 回包采纳了，但后打的字还在缓冲里，等着下一次发送。
    expect(c.yaml, 'flow: dev\nsteps: []\n# edited\n');
    expect(c.hasPending, isTrue);
    // 防抖会把它们再发一次。
    await _pastDebounce();
    final edits = harness.sent.where((f) => f['type'] == 'flow_edit_req');
    expect(edits.length, 2);
    expect(edits.last['ops'], [
      {'op': 'set', 'node_id': 'a', 'field': 'desc', 'value': '一二'},
    ]);
  });

  test('在途期间来的结构操作排队，回包后续发', () async {
    final harness = _Harness()..delay = const Duration(milliseconds: 200);
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '一', immediate: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 在途：这一批不能丢。
    await c.applyOps([
      {'op': 'delete', 'node_id': 'a'},
    ]);
    await _pastDebounce();

    final edits = harness.sent.where((f) => f['type'] == 'flow_edit_req');
    expect(edits.length, 2);
    expect(edits.last['ops'].last['op'], 'delete');
  });

  test('flush 失败时保存不发 flow_save_req', () async {
    final harness = _Harness()..rejectEdits = true;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '改了', immediate: true);
    await _pastDebounce();
    expect(c.hasRejected, isTrue);

    await c.save();
    // 存的是旧内容还提示「已保存」是最坏的一种错，宁可什么都不发。
    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isFalse);
  });

  test('被拒的字段不进下一批，用户改值后才重发', () async {
    final harness = _Harness()..rejectEdits = true;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '坏值', immediate: true);
    await _pastDebounce();
    // 再来一个结构操作：被拒的 desc 不该跟着一起发，否则整批又被拒。
    harness.rejectEdits = false;
    await c.applyOps([
      {'op': 'delete', 'node_id': 'b'},
    ]);
    final last = harness.sent.lastWhere((f) => f['type'] == 'flow_edit_req');
    expect(last['ops'], [
      {'op': 'delete', 'node_id': 'b'},
    ]);
    // 用户改了值，重新参与发送。
    c.setField('a', 'desc', '好值', immediate: true);
    await _pastDebounce();
    expect(c.hasRejected, isFalse);
    expect(c.hasPending, isFalse);
  });

  test('源码回空 yaml 时不改草稿', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final before = c.yaml;

    final ok = await c.applySource('broken: [[[', null);
    expect(ok, isFalse);
    expect(c.yaml, before, reason: '空 yaml 会把草稿清空');
    expect(harness.notices.single.kind, FlowEditorNoticeKind.sourceInvalid);
  });

  test('页面销毁后回包不抛', () async {
    final harness = _Harness()..delay = const Duration(milliseconds: 150);
    addTearDown(harness.close);
    final c = await harness.controller();

    c.setField('a', 'desc', '一', immediate: true);
    c.dispose();
    // 回包在这之后才到：不该碰已 dispose 的 ChangeNotifier。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.hasPending, isTrue);
  });

  test('旧主机的能力按 schema 降级', () async {
    // 没有 ops 的 schema = 旧主机。
    final old = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
    })!;
    final caps = FlowHostCaps.of(old, const []);
    expect(caps.canEdit, isFalse);
    expect(caps.canEditHeader, isFalse);
    expect(caps.canRetype, isFalse);
    expect(caps.readOnly, isTrue);

    // 有 move / header / retype 的新主机。
    final fresh = FlowSchema.fromResponse({
      'success': true,
      'common': [],
      'kinds': {},
      'ops': ['set', 'insert', 'move', 'delete', 'wrap', 'unwrap', 'retype', 'header'],
    })!;
    final full = FlowHostCaps.of(fresh, const []);
    expect(full.canEdit, isTrue);
    expect(full.canEditHeader, isTrue);
    expect(full.canRetype, isTrue);
  });

  test('连着改同一个字段只算一步 undo', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final before = c.yaml;

    // 模拟打一段提示词：三次防抖发送，同一个字段。
    for (final value in ['一', '一二', '一二三']) {
      c.setField('a', 'desc', value, immediate: true);
      await _pastDebounce();
    }
    expect(c.yaml, 'flow: dev\nsteps: []\n# edited\n');

    // 一次撤销就回到打字之前 —— 否则 40 步 undo 打一段字就用完了。
    await c.undo();
    expect(c.yaml, before);
    expect(c.canUndo, isFalse);
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

  /// 回包延后多久。用来造「在途期间用户还在打字」的窗口。
  Duration delay = Duration.zero;
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
            final event = PeerControlEvent(
                peerId: peerId,
                data: {...reply, 'request_id': frame['request_id']});
            if (delay == Duration.zero) {
              bus.add(event);
            } else {
              unawaited(Future<void>.delayed(delay, () {
                if (!bus.isClosed) bus.add(event);
              }));
            }
          }
          return true;
        },
      );

  Map<String, dynamic> _validate(String yaml) {
    // 主机在 YAML 语法错时会回空 yaml 加空诊断：拿它当草稿会把流程清空。
    if (yaml.contains('broken')) {
      return {
        'type': 'flow_validate_resp',
        'success': false,
        'yaml': '',
        'tree': [],
        'diagnostics': [],
        'error': 'YAML 语法错',
      };
    }
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
