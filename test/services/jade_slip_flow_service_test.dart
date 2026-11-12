import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/slip_scope_documents.dart';
import 'package:shepaw/storage/store_protocol.dart';

import '../storage/memory_scope_transport.dart';
import '../storage/test_harness.dart';

/// 工作流终态回写后的两个服务层保证：
/// - 人动清单时状态锁要放开，不能永远压着「待验收」
/// - 主机推 `slip.changed` 后能重读到新事件与新状态（拿不到就静默）
void main() {
  const self = 'aaaaaaaaaaaaaaaa';

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  late SlipScopeDocuments docs;

  setUp(() async {
    docs = SlipScopeDocuments(
      store: PouchScopeStore(
        transport: MemoryScopeTransport(),
        pouchId: 'test-pouch',
      ),
      deviceId: self,
    );
    JadeSlipService.instance.debugDocuments = () => docs;
    JadeSlipService.instance.debugResetHostChangeSync();
  });

  tearDown(() async {
    JadeSlipService.instance.debugDocuments = null;
    JadeSlipService.instance.debugResetHostChangeSync();
  });

  Future<JadeSlip> seeded({
    String id = 'slip-flow',
    String flowStatus = '',
  }) async {
    final slip = await JadeSlipService.instance.create(
      title: '绑定的玉简',
      body: '正文',
    );
    return JadeSlipService.instance.update(
      slip.copyWith(
        executorKind: JadeSlipExecutorKind.flow,
        flowBinding: const JadeSlipFlowBinding(scope: 'lib', name: '发布流程'),
        status: JadeSlipStatus.needsReview,
        flowStatus: flowStatus,
      ),
    );
  }

  test('只改标题时状态锁保住待验收，改清单时放开', () async {
    final slip = await seeded(flowStatus: 'needs_review');
    expect(slip.status, JadeSlipStatus.needsReview);

    final renamed = await JadeSlipService.instance.update(
      (await JadeSlipService.instance.getById(slip.id))!
          .copyWith(title: '换个标题'),
    );
    expect(renamed.status, JadeSlipStatus.needsReview);
    expect(renamed.flowStatus, 'needs_review');

    final withItem = await JadeSlipService.instance.addItem(
      id: renamed.id,
      text: '补一项',
    );
    expect(withItem.flowStatus, '', reason: '人动了清单，锁应放开');
    expect(withItem.status, JadeSlipStatus.open);
  });

  test('refreshFromHost 能读到主机写回的事件和状态', () async {
    final slip = await seeded();
    // 模拟主机直接写权威副本（绕过 App 服务）。
    final raw = <String, dynamic>{
      ...slip.toJson(),
      'status': 'needs_review',
      'flow_status': 'needs_review',
      'events': [
        {
          'id': 'flow_run_r1_succeeded',
          'kind': 'flow_run',
          'actor_id': 'system',
          'actor_name': '工作流',
          'text': '工作流运行完成，待验收',
          'created_at': 12345,
        },
      ],
      'updated_at': slip.updatedAt + 5,
    };
    await docs.writeBytes(
      StoreSpace.slips,
      slip.relPath,
      Uint8List.fromList(utf8.encode(jsonEncode(raw))),
    );

    var notified = 0;
    final sub = JadeSlipService.instance.changes.listen((_) => notified++);
    addTearDown(sub.cancel);
    await JadeSlipService.instance.refreshFromHost(slip.id);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final fresh = await JadeSlipService.instance.getById(slip.id);
    expect(fresh, isNotNull);
    expect(fresh!.events.length, 1);
    expect(fresh.events.single.kind, 'flow_run');
    expect(fresh.status, JadeSlipStatus.needsReview);
    expect(fresh.flowStatus, 'needs_review');
    expect(notified, greaterThan(0));
  });

  test('主机 slip.changed 控制帧触发重读并通知 UI', () async {
    final slip = await seeded();
    final raw = <String, dynamic>{
      ...slip.toJson(),
      'status': 'blocked',
      'flow_status': 'blocked',
      'events': [
        {
          'id': 'flow_run_r2_failed',
          'kind': 'flow_run',
          'actor_id': 'system',
          'text': '工作流运行失败：预算耗尽',
          'created_at': 22222,
        },
      ],
      'updated_at': slip.updatedAt + 5,
    };
    await docs.writeBytes(
      StoreSpace.slips,
      slip.relPath,
      Uint8List.fromList(utf8.encode(jsonEncode(raw))),
    );

    var notified = 0;
    final sub = JadeSlipService.instance.changes.listen((_) => notified++);
    addTearDown(sub.cancel);
    JadeSlipService.instance.debugHandleHostEvent({
      'type': 'slip.changed',
      'slip_id': slip.id,
      'run_id': 'r2',
      'status': 'failed',
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final fresh = await JadeSlipService.instance.getById(slip.id);
    expect(fresh!.status, JadeSlipStatus.blocked);
    expect(fresh.events.single.text, contains('预算耗尽'));
    expect(notified, greaterThan(0));
  });

  test('无关的主机帧不触发重读', () async {
    final slip = await seeded();
    JadeSlipService.instance.debugHandleHostEvent({
      'type': 'flow.run.changed',
      'run_id': 'r1',
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final list = await JadeSlipService.instance.list();
    expect(list.length, 1);
    expect(list.single.id, slip.id);
    expect(list.single.events, isEmpty);
  });

  test('refreshFromHost 读不到时静默忽略（回写失败不影响 UI）', () async {
    await JadeSlipService.instance.refreshFromHost('does-not-exist');
    final list = await JadeSlipService.instance.list();
    expect(list, isEmpty);
  });

  test('用另一份同值副本改标题：清单没变，状态锁不该被清', () async {
    final slip = await seeded(flowStatus: 'needs_review');
    final withItem = await JadeSlipService.instance.addItem(
      id: slip.id,
      text: '一项',
    );
    final locked = await JadeSlipService.instance.update(withItem.copyWith(
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ));
    expect(locked.flowStatus, 'needs_review');
    // 列表页重新解码出来的副本：items 是新对象，内容一样。
    final decoded = JadeSlip.fromJson(
      jsonDecode(jsonEncode(locked.toJson())) as Map<String, dynamic>,
    );
    expect(identical(decoded.items, locked.items), isFalse);
    final renamed = await JadeSlipService.instance
        .update(decoded.copyWith(title: '只改标题'));
    expect(renamed.flowStatus, 'needs_review');
    expect(renamed.status, JadeSlipStatus.needsReview);
  });

  test('清单早已收完又跑出待验收：整条验收放锁并变 done', () async {
    final slip = await seeded();
    final withItem = await JadeSlipService.instance.addItem(
      id: slip.id,
      text: '一项',
    );
    final acceptedItems = [
      for (final item in withItem.items)
        item.copyWith(state: JadeSlipItemState.accepted),
    ];
    final settled = await JadeSlipService.instance
        .update(withItem.copyWith(items: acceptedItems));
    expect(settled.status, JadeSlipStatus.done);
    // 主机回写：待验收 + 锁（清单没动）。
    final rerun = await JadeSlipService.instance.update(settled.copyWith(
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ));
    expect(rerun.status, JadeSlipStatus.needsReview);

    final done = await JadeSlipService.instance.acceptWhole(id: rerun.id);
    expect(done.status, JadeSlipStatus.done);
    expect(done.flowStatus, '');
    expect(done.events.any((e) => e.text == '验收工作流结果'), isTrue);
  });

  test('还有未完成清单项时，整条验收不清掉待验收状态锁', () async {
    final slip = await seeded();
    final locked = await JadeSlipService.instance.update(slip.copyWith(
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ));
    final withItem = await JadeSlipService.instance.addItem(
      id: locked.id,
      text: '未完成',
    );
    // addItem 会按清单改动放锁，重新挂上模拟主机回写的终态锁。
    final rerun = await JadeSlipService.instance.update(withItem.copyWith(
      status: JadeSlipStatus.needsReview,
      flowStatus: 'needs_review',
    ));
    final result = await JadeSlipService.instance.acceptWhole(id: rerun.id);
    expect(result.flowStatus, 'needs_review');
    expect(result.status, JadeSlipStatus.needsReview);
    expect(result.events.any((e) => e.text == '验收工作流结果'), isFalse);
  });
}
