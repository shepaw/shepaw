import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/runtime_browse.dart';
import 'package:shepaw/storage/runtime_paths.dart';

void main() {
  const owner = 'agent_1';

  test('产物、附件、会话归到三块，并带上频道', () {
    final art = classifyRuntimeOwnerFile(
      owner,
      '$owner/ch_1/artifacts/task/report.md',
    );
    final att = classifyRuntimeOwnerFile(
      owner,
      '$owner/ch_1/attachments/${'a' * 64}',
    );
    final ses = classifyRuntimeOwnerFile(
      owner,
      '$owner/ch_1/sessions/session.json',
    );

    expect(art?.bucket, RuntimeBucket.artifacts);
    expect(art?.channelId, 'ch_1');
    expect(att?.bucket, RuntimeBucket.attachments);
    expect(ses?.bucket, RuntimeBucket.sessions);
    expect(ses?.workflowDir, isNull);
  });

  test('工作流目录单独记下来', () {
    const wf = 'wf_flow1__step_step9';
    final placed = classifyRuntimeOwnerFile(
      owner,
      '$owner/ch_1/$wf/artifacts/task/out.md',
    );
    expect(placed?.workflowDir, wf);
    expect(placed?.bucket, RuntimeBucket.artifacts);
    expect(
      RuntimePaths.parseWorkflowScopeDir(wf),
      (workflowId: 'flow1', stepId: 'step9'),
    );
  });

  test('soul 镜像和别的 owner 不进这三块', () {
    expect(
      classifyRuntimeOwnerFile(owner, '$owner/soul.md'),
      isNull,
    );
    expect(
      classifyRuntimeOwnerFile(owner, '$owner/memory.md'),
      isNull,
    );
    expect(
      classifyRuntimeOwnerFile(owner, 'other/ch/artifacts/t/a.md'),
      isNull,
    );
  });
}
