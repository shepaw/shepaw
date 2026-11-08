import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 只为在用例结束后还原平台实例。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shepaw/controllers/flow/flow_draft_store.dart';
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

  test('在途期间连续两次结构操作都要留下', () async {
    final harness = _Harness()..delay = const Duration(milliseconds: 200);
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '一', immediate: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = c.applyOps([
      {'op': 'delete', 'node_id': 'a'},
    ]);
    final second = c.applyOps([
      {'op': 'delete', 'node_id': 'b'},
    ]);
    await Future.wait([first, second]);
    await _pastDebounce();

    final deletes = [
      for (final frame in harness.sent)
        if (frame['type'] == 'flow_edit_req')
          for (final op in frame['ops'] as List)
            if (op['op'] == 'delete') op['node_id'],
    ];
    expect(deletes, ['a', 'b']);
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
    // 但迟到回包仍要被采纳并落草稿 —— 以前这里直接丢弃，最后敲的字会永久丢。
    expect(c.yaml, 'flow: dev\nsteps: []\n# edited\n');
    expect(c.hasPending, isFalse);
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
  test('保存带 base_revision：不然两人同时改会静默覆盖', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '改了', immediate: true);
    await _pastDebounce();
    await c.save();
    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(save['base_revision'], 3);
  });

  test('flush 会等在途请求：不会拿旧 YAML 保存', () async {
    final harness = _Harness()..delay = const Duration(milliseconds: 200);
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    // 结构 op 在途（_pending 为空）。
    unawaited(c.applyOps([
      {'op': 'delete', 'node_id': 'a'},
    ]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.save();
    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    // 保存的是采纳后的内容，不是结构 op 之前的。
    expect(save['yaml'], 'flow: dev\nsteps: []\n# edited\n');
  });

  test('被拒的字段不会被无关的成功提交清掉', () async {
    final harness = _Harness()..rejectEdits = true;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '坏值', immediate: true);
    await _pastDebounce();
    expect(c.hasRejected, isTrue);

    harness.rejectEdits = false;
    await c.applyOps([
      {'op': 'delete', 'node_id': 'b'},
    ]);
    // 用户还没改这个字段，它必须继续留在 rejected 里。
    expect(c.hasRejected, isTrue);
    expect(c.hasPending, isTrue);
  });

  test('有被拒字段时 undo 不该被卡死', () async {
    final harness = _Harness()..rejectEdits = true;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    harness.rejectEdits = false;
    c.setField('a', 'desc', '第一次', immediate: true);
    await _pastDebounce();
    harness.rejectEdits = true;
    c.setField('a', 'desc', '坏值', immediate: true);
    await _pastDebounce();

    await c.undo();
    expect(c.dirty, isFalse);
  });

  test('不同字段的连续编辑不能合并成一步 undo', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    final initial = c.yaml;

    c.setField('a', 'desc', '一', immediate: true);
    await _pastDebounce();
    c.setField('a', 'task.prompt', '二', immediate: true);
    await _pastDebounce();

    await c.undo();
    expect(c.yaml, isNot(initial), reason: '第一次撤销只该退掉第二个字段');
    await c.undo();
    expect(c.yaml, initial);
  });

  test('合并 undo 之后 redo 栈必须作废', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '一', immediate: true);
    await _pastDebounce();
    c.setField('a', 'desc', '二', immediate: true);
    await _pastDebounce();
    await c.undo();
    // 刚撤销完又打字（会走合并路径），redo 不该复活刚撤销的版本。
    c.setField('a', 'desc', '三', immediate: true);
    await _pastDebounce();
    expect(c.canRedo, isFalse);
  });

  test('另存为带 create_only，普通保存不带', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    await c.saveAs('copy-of-dev');
    final saveAs =
        harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(saveAs['name'], 'copy-of-dev');
    expect(saveAs['create_only'], true);
    expect(saveAs['base_revision'], isNull);
  });

  test('force 保存不带 base_revision（冲突后覆盖为新一版）', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    await c.save(force: true);
    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(save['base_revision'], isNull);
  });

  test('保存失败但版本没变：不弹「覆盖为新一版」的冲突对话框', () async {
    // 主机给所有失败都带 latest；校验不过时它等于手上的版本（3）。
    final harness = _Harness()
      ..saveReply = {
        'type': 'flow_save_resp',
        'success': false,
        'error': '定义校验不过',
        'latest': 3,
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.save(), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.saveRejected);
  });

  test('版本被别人推进了才算冲突', () async {
    final harness = _Harness()
      ..saveReply = {
        'type': 'flow_save_resp',
        'success': false,
        'error': '已经被改到第 5 版',
        'latest': 5,
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.save(), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.saveConflict);
    expect(harness.notices.last.count, 5);
  });

  test('别人删了重建让版本反而变小，也仍然是冲突', () async {
    // 旧判据 `latest > _revision` 会把这种真冲突当成普通失败，三个出口全没了。
    final harness = _Harness()
      ..saveReply = {
        'type': 'flow_save_resp',
        'success': false,
        'error': '已经被改到第 1 版（你要改的是第 3 版）',
        'latest': 1,
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.save(), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.saveConflict);
  });

  test('force 保存不带 base_revision，任何失败都不能再弹冲突对话框', () async {
    // 否则「覆盖为新一版」会反复弹同一个对话框，成为死循环。
    final harness = _Harness()
      ..saveReply = {
        'type': 'flow_save_resp',
        'success': false,
        'error': '磁盘写失败',
        'latest': 5,
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.save(force: true), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.saveRejected);
  });

  test('改名：改 flow 头、存成新名字、删掉旧的', () async {
    final harness = _Harness()
      ..listReply = {
        'type': 'flow_list_resp',
        'success': true,
        'flows': [
          {'name': 'dev', 'latest': 3},
        ],
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);
    String? renamed;
    c.onRenamed = (name) => renamed = name;

    expect(await c.rename('review-loop'), isTrue);
    expect(c.name, 'review-loop');
    expect(renamed, 'review-loop');
    final edit = harness.sent.lastWhere((f) => f['type'] == 'flow_edit_req');
    expect(edit['ops'], [
      {'op': 'header', 'field': 'flow', 'value': 'review-loop'},
    ]);
    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(save['name'], 'review-loop');
    expect(save['create_only'], isTrue);
    expect(save['yaml'], contains('flow: review-loop'));
    final deleted =
        harness.sent.lastWhere((f) => f['type'] == 'flow_delete_req');
    expect(deleted['name'], 'dev');
  });

  test('改名撞名或名字不合法：不写也不删', () async {
    final harness = _Harness()
      ..listReply = {
        'type': 'flow_list_resp',
        'success': true,
        'flows': [
          {'name': 'dev', 'latest': 3},
          {'name': 'taken', 'latest': 1},
        ],
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.rename('dev'), isTrue);
    expect(await c.rename('中文标题'), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.nameInvalid);
    expect(await c.rename('taken'), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.nameTaken);
    expect(harness.sent.where((f) => f['type'] == 'flow_save_req'), isEmpty);
    expect(harness.sent.where((f) => f['type'] == 'flow_delete_req'), isEmpty);
    expect(c.name, 'dev');
  });

  test('另存为撞名：一个写请求都不发', () async {
    final harness = _Harness()
      ..listReply = {
        'type': 'flow_list_resp',
        'success': true,
        'flows': [
          // 编辑器自己就开在 dev 上，真实的库里必然有这一项。
          {'name': 'dev', 'latest': 3},
        ],
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.saveAs('dev'), isFalse);
    expect(harness.sent.where((f) => f['type'] == 'flow_save_req'), isEmpty);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.nameTaken);
  });

  test('流程名按主机原样区分大小写，DEV 不该被 dev 挡住', () async {
    final harness = _Harness()
      ..listReply = {
        'type': 'flow_list_resp',
        'success': true,
        'flows': [
          {'name': 'dev', 'latest': 3},
        ],
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    // 主机把名字原样拼进 scope，flow:DEV 和 flow:dev 是两行。
    expect(await c.saveAs('DEV'), isTrue);
    final save = harness.sent.lastWhere((f) => f['type'] == 'flow_save_req');
    expect(save['name'], 'DEV');
  });

  test('flow_list 明确回了失败：照常写，不再误报「主机没有回应」', () async {
    // 库里有一个坏掉的 meta.json 会让整个 list 失败，但主机仍在、save 仍能
    // 工作（新主机的 create_only 是原子的）。别把「新建」永久挡在这里。
    final harness = _Harness()
      ..listReply = {
        'type': 'flow_list_resp',
        'success': false,
        'error': 'meta 读不出来',
      };
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.saveAs('fresh'), isTrue);
    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isTrue);
    expect(harness.notices.any((n) => n.kind == FlowEditorNoticeKind.hostNoReply),
        isFalse);
  });

  test('主机真的不应答：另存为不写，并如实报「主机没有回应」', () async {
    final harness = _Harness()..reachable = false;
    addTearDown(harness.close);
    final c = await harness.controller();
    addTearDown(c.dispose);

    expect(await c.saveAs('fresh'), isFalse);
    expect(harness.sent.any((f) => f['type'] == 'flow_save_req'), isFalse);
    expect(harness.notices.last.kind, FlowEditorNoticeKind.hostNoReply);
  });

  test('流程被删掉后 abandon：迟到的 edit 回包不再落幽灵草稿', () async {
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
    addTearDown(() {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = original;
    });
    // 回包晚到，模拟「删除流程 → 卸载编辑页」时还在途的那一次 edit。
    final harness = _Harness()..delay = const Duration(milliseconds: 250);
    addTearDown(harness.close);
    final drafts = FlowDraftStore();
    final c = FlowEditorController(
      peerId: 'p1',
      name: 'dev',
      client: harness.client,
      draftStore: drafts,
    );
    c.onNotice = harness.notices.add;
    await c.load();
    addTearDown(c.dispose);

    c.setField('a', 'desc', '改了');
    // 500ms 防抖刚过、回包还没到：此刻删流程并清掉草稿。
    await Future<void>.delayed(const Duration(milliseconds: 560));
    expect(harness.sent.any((f) => f['type'] == 'flow_edit_req'), isTrue);
    c.abandon();
    await drafts.clear(peerId: 'p1', scope: '', name: 'dev');

    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(await drafts.load(peerId: 'p1', scope: '', name: 'dev'), isNull);
  });

}

Future<void> _pastDebounce() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

/// 假主机：按帧类型回固定应答，记下所有请求。
class _Harness {
  _Harness();

  bool reachable = true;
  bool rejectEdits = false;

  /// 自定义 `flow_save_req` 的应答（测失败路径）。
  Map<String, dynamic>? saveReply;

  /// 自定义 `flow_list_req` 的应答（另存为查重用）。
  Map<String, dynamic>? listReply;

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
            'flow_list_req' =>
              listReply ??
                  {
                    'type': 'flow_list_resp',
                    'success': true,
                    'flows': [],
                  },
            'flow_save_req' =>
              saveReply ??
                  {
                    'type': 'flow_save_resp',
                    'success': true,
                    'flow': {'latest': 4},
                  },
            'flow_edit_req' => rejectEdits
                ? {
                    'type': 'flow_edit_resp',
                    'success': false,
                    'error': '第 1 个操作：没有节点 `a`',
                  }
                : {
                    // `type` 放最后：_validate 里也有 type，spread 会盖掉它。
                    ..._validate(_editedYaml(frame)),
                    'type': 'flow_edit_resp',
                    'success': true,
                    'valid': true,
                  },
            'flow_delete_req' => {
                'type': 'flow_delete_resp',
                'success': true,
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

  /// 普通编辑仍回固定 YAML。改 `flow` 头时把新名字写回去，好核对存盘内容。
  String _editedYaml(Map<String, dynamic> frame) {
    final ops = frame['ops'];
    if (ops is List) {
      for (final op in ops) {
        if (op is Map && op['op'] == 'header' && op['field'] == 'flow') {
          return 'flow: ${op['value']}\nsteps: []\n';
        }
      }
    }
    return 'flow: dev\nsteps: []\n# edited\n';
  }

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
