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

    test('resolveStoreTarget：群聊产物进群 runtime', () {
      final t = RuntimePaths.resolveStoreTarget(
        agentId: 'agent-1',
        channelId: 'ch-g',
        channelType: 'group',
        parentGroupId: 'group-9',
      );
      expect(t.ownerId, 'group-9');
      expect(t.channelId, 'ch-g');
    });

    test('resolveStoreTarget：群绑定成员 DM 仍进群 runtime', () {
      final t = RuntimePaths.resolveStoreTarget(
        agentId: 'agent-1',
        channelId: 'gmd_group-9__agent-1',
        channelType: 'dm',
        sourceGroupChannelId: 'group-9',
      );
      expect(t.ownerId, 'group-9');
      expect(t.channelId, 'group-9');
    });

    test('resolveStoreTarget：普通单聊进自己的 runtime', () {
      final t = RuntimePaths.resolveStoreTarget(
        agentId: 'agent-1',
        channelId: 'ch-dm',
        channelType: 'dm',
      );
      expect(t.ownerId, 'agent-1');
      expect(t.channelId, 'ch-dm');
    });

    test('attachment / session / artifact 路径', () {
      final att = RuntimePaths.attachmentBlob('a1', 'c1', 'a' * 64);
      expect(att, 'a1/c1/attachments/${'a' * 64}');
      expect(RuntimePaths.isRuntimeAttachmentPath(att), isTrue);
      expect(
          RuntimePaths.sessionJson('a1', 'c1'), 'a1/c1/sessions/session.json');
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
      const scoped = 'psess_group_77899647-8d7e-4eea-8357-37bd10bc5aeb'
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
      expect(
          uri, startsWith('store://${StoreSpace.runtime}/0123456789abcdef/'));
      expect(uri, contains('a1/soul.md'));
    });
  });

  group('StoreSpace profile', () {
    test('内置与 legacy', () {
      expect(
          StoreSpace.all,
          containsAll([
            StoreSpace.workspaces,
            StoreSpace.runtime,
            StoreSpace.files,
            StoreSpace.public_,
            StoreSpace.backups,
            StoreSpace.cognition,
            StoreSpace.memory,
            StoreSpace.artifacts,
            StoreSpace.attachments,
          ]));
      expect(StoreSpace.sharedReadable, isNot(contains(StoreSpace.runtime)));
      expect(StoreSpace.sharedReadable, isNot(contains(StoreSpace.cognition)));
      expect(StoreSpace.sharedReadable, isNot(contains(StoreSpace.memory)));
      expect(StoreSpace.isOwnerCrossWritable(StoreSpace.workspaces), isTrue);
      expect(StoreSpace.isOwnerCrossWritable(StoreSpace.runtime), isFalse);
      expect(StoreSpace.browserSpaces, contains(StoreSpace.workspaces));
      expect(StoreSpace.browserSpaces, contains(StoreSpace.public_));
      expect(StoreSpace.browserSpaces, contains(StoreSpace.cognition));
      expect(StoreSpace.browserSpaces, isNot(contains(StoreSpace.memory)));
      expect(StoreSpace.defaultBrowserSpaces, [
        StoreSpace.files,
        StoreSpace.workspaces,
        StoreSpace.public_,
      ]);
      expect(StoreSpace.advancedBrowserSpaces, [
        StoreSpace.runtime,
        StoreSpace.cognition,
        StoreSpace.artifacts,
      ]);
      expect(
        StoreSpace.defaultVisibleSpaces(StoreSpace.browserSpaces),
        [StoreSpace.files, StoreSpace.workspaces, StoreSpace.public_],
      );
      expect(
        StoreSpace.advancedVisibleSpaces(StoreSpace.browserSpaces),
        [StoreSpace.runtime, StoreSpace.cognition, StoreSpace.artifacts],
      );
      expect(
        StoreSpace.defaultVisibleSpaces([StoreSpace.files, 'notes']),
        [StoreSpace.files, 'notes'],
      );
      expect(
        StoreSpace.advancedVisibleSpaces(
            [StoreSpace.files, StoreSpace.runtime]),
        [StoreSpace.runtime],
      );
    });
  });

  group('RuntimeSharePolicy', () {
    test('allowsFileRead：仅放行 attachments/artifacts 段下的文件', () {
      expect(
        RuntimeSharePolicy.allowsFileRead('agent_1/ch_1/attachments/aaaaaaaa'),
        isTrue,
      );
      expect(
        RuntimeSharePolicy.allowsFileRead(
            'agent_1/ch_1/artifacts/task_1/out.txt'),
        isTrue,
      );
      // workflow scope 内的附件同样放行
      expect(
        RuntimeSharePolicy.allowsFileRead(
            'agent_1/ch_1/wf_w1__step_1/attachments/bbbbbbbb'),
        isTrue,
      );
      expect(RuntimeSharePolicy.allowsFileRead('agent_1/soul.md'), isFalse);
      expect(
        RuntimeSharePolicy.allowsFileRead('agent_1/ch_1/sessions/session.json'),
        isFalse,
      );
      // channel 根下未知文件不放行
      expect(
        RuntimeSharePolicy.allowsFileRead('agent_1/ch_1/session.md'),
        isFalse,
      );
      expect(RuntimeSharePolicy.allowsFileRead(''), isFalse);
    });

    test('isSensitivePath：根镜像/清单与会话段命中', () {
      expect(RuntimeSharePolicy.isSensitivePath('agent_1/soul.md'), isTrue);
      expect(RuntimeSharePolicy.isSensitivePath('agent_1/memory.md'), isTrue);
      expect(
          RuntimeSharePolicy.isSensitivePath('agent_1/workspace.md'), isTrue);
      expect(
        RuntimeSharePolicy.isSensitivePath('agent_1/context.manifest.json'),
        isTrue,
      );
      expect(
        RuntimeSharePolicy.isSensitivePath(
            'agent_1/ch_1/sessions/session.json'),
        isTrue,
      );
      // 附件/目录非敏感，由服务端 allowsFileRead 严格把关
      expect(
        RuntimeSharePolicy.isSensitivePath('agent_1/ch_1/attachments/aaaaaaaa'),
        isFalse,
      );
      expect(RuntimeSharePolicy.isSensitivePath('agent_1/ch_1'), isFalse);
    });
  });
}
