import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/notes/notes_namespace.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/slip_scope_documents.dart';

import '../storage/memory_scope_transport.dart';
import '../storage/test_harness.dart';

/// `shepaw slip get` 也要能看到执行者是工作流，以及最近一次运行。
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
  });

  tearDown(() async {
    JadeSlipService.instance.debugDocuments = null;
  });

  test('纯 Agent 玉简的 CLI 视图没有工作流字段', () async {
    final slip = await JadeSlipService.instance.create(title: '纯 Agent');
    final got = await NotesGetCommand().execute({'id': slip.id});
    final view = (got['slip'] as Map).cast<String, dynamic>();
    expect(view.containsKey('executor_kind'), isFalse);
    expect(view.containsKey('flow_binding'), isFalse);
  });

  test('绑定工作流的玉简 CLI 视图带 scope/name/version 与最近运行', () async {
    final slip = await JadeSlipService.instance.create(title: '绑定的玉简');
    final bound = await JadeSlipService.instance.update(slip.copyWith(
      executorKind: JadeSlipExecutorKind.flow,
      flowBinding: const JadeSlipFlowBinding(
        scope: 'group:g1',
        name: '发布流程',
        revision: 3,
        inputs: {'goal': '上线'},
      ),
      flowRuns: const [
        JadeSlipFlowRun(
          runId: 'run-1',
          startedAt: 100,
          status: 'succeeded',
          hostId: 'host-1',
        ),
      ],
    ));
    final got = await NotesGetCommand().execute({'id': bound.id});
    final view = (got['slip'] as Map).cast<String, dynamic>();
    expect(view['executor_kind'], 'flow');
    final binding = (view['flow_binding'] as Map).cast<String, dynamic>();
    expect(binding['scope'], 'group:g1');
    expect(binding['name'], '发布流程');
    expect(binding['revision'], 3);
    expect(binding['inputs'], {'goal': '上线'});
    expect((view['latest_flow_run'] as Map)['run_id'], 'run-1');
  });
}
