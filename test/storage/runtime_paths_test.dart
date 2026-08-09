import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/runtime_paths.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  group('RuntimePaths', () {
    test('resolveOwnerId：群聊用 parentGroupId', () {
      expect(
        RuntimePaths.resolveOwnerId(
          agentId: 'agent-1',
          channelId: 'ch-g',
          channelType: 'group',
          parentGroupId: 'group-9',
        ),
        'group-9',
      );
    });

    test('resolveOwnerId：单聊用 agentId', () {
      expect(
        RuntimePaths.resolveOwnerId(
          agentId: 'agent-1',
          channelId: 'ch-dm',
          channelType: 'dm',
        ),
        'agent-1',
      );
    });

    test('attachment / session / artifact 路径', () {
      final att = RuntimePaths.attachmentBlob('a1', 'c1', 'a' * 64);
      expect(att, 'a1/c1/attachments/${'a' * 64}');
      expect(RuntimePaths.isRuntimeAttachmentPath(att), isTrue);
      expect(RuntimePaths.sessionJson('a1', 'c1'), 'a1/c1/sessions/session.json');
      expect(
        RuntimePaths.artifactFile(
          ownerId: 'a1',
          channelId: 'c1',
          taskId: 't1',
          filename: 'out.md',
        ),
        'a1/c1/artifacts/t1/out.md',
      );
    });

    test('workflow scoped channel：channel 与 wf/step 分目录', () {
      const scoped =
          'psess_group_77899647-8d7e-4eea-8357-37bd10bc5aeb'
          '__wf_af8faa46-bffc-4a3d-82a2-f33427095ae8'
          '__step_79647862-af5b-4871-afa6-6b7353548d90';
      final split = RuntimePaths.splitChannelId(scoped);
      expect(
        split.channelId,
        'psess_group_77899647-8d7e-4eea-8357-37bd10bc5aeb',
      );
      expect(
        split.workflowScope,
        'wf_af8faa46-bffc-4a3d-82a2-f33427095ae8'
        '__step_79647862-af5b-4871-afa6-6b7353548d90',
      );
      expect(
        RuntimePaths.sessionJson('peeragent_x_channel-claude', scoped),
        'peeragent_x_channel-claude/'
        'psess_group_77899647-8d7e-4eea-8357-37bd10bc5aeb/'
        'wf_af8faa46-bffc-4a3d-82a2-f33427095ae8'
        '__step_79647862-af5b-4871-afa6-6b7353548d90/'
        'sessions/session.json',
      );
      expect(
        RuntimePaths.channelRoot(
          'owner',
          'psess_group_abc',
          workflowScope: 'wf_1__step_2',
        ),
        'owner/psess_group_abc/wf_1__step_2',
      );
    });

    test('uri 组装', () {
      final uri = RuntimePaths.uri(
        deviceId: '0123456789abcdef',
        relPath: 'a1/soul.md',
      );
      expect(uri, startsWith('store://${StoreSpace.runtime}/0123456789abcdef/'));
      expect(uri, contains('a1/soul.md'));
    });
  });

  group('StoreSpace profile', () {
    test('内置与 legacy', () {
      expect(StoreSpace.all, containsAll([
        StoreSpace.workspaces,
        StoreSpace.runtime,
        StoreSpace.files,
        StoreSpace.public_,
        StoreSpace.backups,
        StoreSpace.memory,
        StoreSpace.artifacts,
        StoreSpace.attachments,
      ]));
      expect(StoreSpace.sharedReadable, isNot(contains(StoreSpace.runtime)));
      expect(StoreSpace.sharedReadable, isNot(contains(StoreSpace.memory)));
      expect(StoreSpace.isOwnerCrossWritable(StoreSpace.workspaces), isTrue);
      expect(StoreSpace.isOwnerCrossWritable(StoreSpace.runtime), isFalse);
      expect(StoreSpace.browserSpaces, contains(StoreSpace.workspaces));
      expect(StoreSpace.browserSpaces, contains(StoreSpace.public_));
      expect(StoreSpace.browserSpaces, contains(StoreSpace.memory));
    });
  });
}
