import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/store/store_namespace.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/store_uri_reader.dart';

import 'test_harness.dart';

/// GroupWorkspaceService 端到端（StoreService loopback + 临时目录）。
/// 覆盖：元数据创建/幂等/成员变更、round 状态写入与读取、store CLI 群空间
/// 权限校验（只有成员可读写、只能写自己的子目录）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  final ws = GroupWorkspaceService.instance;

  group('ensureGroupWorkspace', () {
    test('创建元数据与成员表，路径根为 group_<gid>', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test1',
        members: [
          (agentId: 'she-builtin-agent-001', role: 'admin'),
          (agentId: 'agent-b', role: 'member'),
        ],
      );

      expect(ws.workspaceRoot('group_test1'), 'group_group_test1');
      expect(ws.metaRelPath('group_test1'),
          'group_group_test1/group-workspace.json');

      final meta = await ws.loadMeta('group_test1');
      expect(meta, isNotNull);
      expect(meta!.groupId, 'group_test1');
      expect(meta.schemaVersion, 1);
      expect(meta.homeDevice, isNotEmpty);
      expect(meta.members.length, 2);
      expect(meta.members['she-builtin-agent-001']!.role, 'admin');
      expect(meta.members['agent-b']!.role, 'member');
      expect(meta.isMember('agent-b'), isTrue);
      expect(meta.isMember('stranger'), isFalse);
    });

    test('重复 ensure 幂等：不覆盖已有成员，补缺新成员', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test1',
        members: [(agentId: 'agent-c', role: 'member')],
      );
      final meta = await ws.loadMeta('group_test1');
      expect(meta!.members.length, 3);
      expect(meta.members['agent-b']!.role, 'member');
      expect(meta.members['agent-c']!.role, 'member');
    });
  });

  group('成员变更', () {
    test('upsertMember 新增/保留 role，removeMember 移除', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test2',
        members: [(agentId: 'she', role: 'admin')],
      );

      await ws.upsertMember(
        groupId: 'group_test2',
        agentId: 'agent-d',
        role: 'member',
      );
      var meta = await ws.loadMeta('group_test2');
      expect(meta!.isMember('agent-d'), isTrue);

      // role 为空时保持原值
      await ws.upsertMember(groupId: 'group_test2', agentId: 'agent-d');
      meta = await ws.loadMeta('group_test2');
      expect(meta!.members['agent-d']!.role, 'member');

      await ws.removeMember(groupId: 'group_test2', agentId: 'agent-d');
      meta = await ws.loadMeta('group_test2');
      expect(meta!.isMember('agent-d'), isFalse);
    });
  });

  group('编排状态落盘', () {
    test('writeRoundState 写 round 文件并更新 latest 指针', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test3',
        members: [(agentId: 'she', role: 'admin')],
      );
      const sessionId = 'group_session1';

      await ws.writeRoundState(
        groupId: 'group_test3',
        sessionId: sessionId,
        round: 0,
        payload: {'status': 'running', 'round': 0},
      );
      await ws.writeRoundState(
        groupId: 'group_test3',
        sessionId: sessionId,
        round: 1,
        payload: {'status': 'members_done', 'round': 1},
      );

      final latest = await ws.readLatestOrchestration(
        groupId: 'group_test3',
        sessionId: sessionId,
      );
      expect(latest, isNotNull);
      expect(latest!['status'], 'members_done');
      expect(latest['round'], 1);

      final round0 = await ws.readRoundState(
        groupId: 'group_test3',
        sessionId: sessionId,
        round: 0,
      );
      expect(round0!['status'], 'running');

      // 目录结构符合约定
      expect(
        ws.roundDir('group_test3', sessionId, 1),
        'group_group_test3/shared/orchestration/group_session1/round-0001',
      );
    });

    test('readRoundSummary 合并 state + dispatch', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test3',
        members: [(agentId: 'she', role: 'admin')],
      );
      await ws.writeRoundState(
        groupId: 'group_test3',
        sessionId: 'group_session1',
        round: 1,
        payload: {
          'status': 'round_complete',
          'round': 1,
          'admin_summary': '已完成基础架构',
        },
      );
      await ws.writeRoundDispatch(
        groupId: 'group_test3',
        sessionId: 'group_session1',
        round: 1,
        payload: {
          'status': 'dispatched',
          'steps': [
            {
              'step': 1,
              'agents': ['agent-b'],
              'task': '实现功能',
              'mode': 'concurrent',
            },
          ],
        },
      );
      final summary = await ws.readRoundSummary(
        groupId: 'group_test3',
        sessionId: 'group_session1',
        round: 1,
      );
      expect(summary!['status'], 'round_complete');
      expect(summary['admin_summary'], '已完成基础架构');
      final steps = (summary['dispatch'] as Map<String, dynamic>)['steps'] as List;
      expect(steps.single['task'], '实现功能');
    });

    test('writeRoundDispatch 写 dispatch.json，与 state 同轮共存', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test3',
        members: [(agentId: 'she', role: 'admin')],
      );
      await ws.writeRoundDispatch(
        groupId: 'group_test3',
        sessionId: 'group_session1',
        round: 0,
        payload: {
          'status': 'dispatched',
          'steps': [
            {
              'step': 1,
              'agents': ['agent-b'],
              'task': '实现功能',
              'mode': 'concurrent',
            },
          ],
        },
      );
      // dispatch 文件可经 URI 读回（成员可见性路径）。
      final bytes = await StoreUriReader.instance.read(
        'store://workspaces/${(await ws.loadMeta('group_test3'))!.homeDevice}/'
        'group_group_test3/shared/orchestration/group_session1/'
        'round-0000/dispatch.json',
      );
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['status'], 'dispatched');
      final steps = json['steps'] as List;
      expect(steps.single['task'], '实现功能');
    });

    test('writeEventLog 写 events/<seq>.json，与轮次目录隔离', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_test4',
        members: [(agentId: 'she', role: 'admin')],
      );
      await ws.writeEventLog(
        groupId: 'group_test4',
        sessionId: 'session_event',
        seq: 1,
        payload: {'kind': 'group_event', 'type': 'stepFailed', 'summary': 'boom'},
      );
      await ws.writeEventLog(
        groupId: 'group_test4',
        sessionId: 'session_event',
        seq: 2,
        payload: {'kind': 'group_event', 'type': 'stepCompleted'},
      );

      // 目录结构与轮次隔离
      expect(
        ws.eventsDir('group_test4', 'session_event'),
        'group_group_test4/shared/orchestration/session_event/events',
      );

      // 可经 URI 读回（补零 6 位序号）
      final home = (await ws.loadMeta('group_test4'))!.homeDevice;
      final bytes = await StoreUriReader.instance.read(
        'store://workspaces/$home/group_group_test4/shared/orchestration/'
        'session_event/events/000002.json',
      );
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['kind'], 'group_event');
      expect(json['type'], 'stepCompleted');
    });
  });

  group('store CLI 群空间权限', () {
    test('sanitizeMemberRelPath 拒绝路径穿越', () {
      expect(sanitizeMemberRelPath('report.md'), 'report.md');
      expect(sanitizeMemberRelPath('sub/note.txt'), 'sub/note.txt');
      expect(sanitizeMemberRelPath('../evil.md'), isNull);
      expect(sanitizeMemberRelPath('a/../../b.md'), isNull);
      expect(sanitizeMemberRelPath('.hidden'), isNull);
      expect(sanitizeMemberRelPath('  '), isNull);
    });

    test('groupWorkspaceAccessError：成员可读，非成员拒绝，非群空间放行',
        () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_perm',
        members: [
          (agentId: 'agent-member', role: 'member'),
          (agentId: 'agent-admin', role: 'admin'),
        ],
      );
      final meta = await ws.loadMeta('group_perm');
      final root = 'store://workspaces/${meta!.homeDevice}/group_group_perm';
      const member = 'agent-member';
      const stranger = 'agent-stranger';

      await ChatAgentScope.runScoped(
        agentId: member,
        body: () async {
          expect(
              await groupWorkspaceAccessError(
                  '$root/shared/orchestration/x/state.json'),
              isNull);
          expect(
              await groupWorkspaceAccessError(
                  '$root/members/agent-member/f.md'),
              isNull);
        },
      );

      await ChatAgentScope.runScoped(
        agentId: stranger,
        body: () async {
          expect(
            await groupWorkspaceAccessError(
                '$root/shared/orchestration/x/state.json'),
            contains('not a member'),
          );
        },
      );

      // 非群空间（files / runtime）不校验
      expect(
        await groupWorkspaceAccessError('store://files/aaaa/note.txt'),
        isNull,
      );
    });
  });

  group('群记忆蒸馏 (writeSharedMemory)', () {
    test('写 session 文件 + latest.md 覆盖，返回 latest URI 可读回', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_mem',
        members: [(agentId: 'she', role: 'admin')],
      );

      final uri1 = await ws.writeSharedMemory(
        groupId: 'group_mem',
        sessionId: 'group_session_a',
        content: '任务 A 结论：完成基础架构。',
      );
      expect(uri1, isNotNull);
      expect(uri1, contains('group_group_mem/shared/memory/latest.md'));

      // 第二个任务覆盖 latest，session 文件保留
      await ws.writeSharedMemory(
        groupId: 'group_mem',
        sessionId: 'group_session_b',
        content: '任务 B 结论：修复了调度 bug。',
      );
      final latestBytes =
          await StoreUriReader.instance.read(uri1!);
      expect(utf8.decode(latestBytes), '任务 B 结论：修复了调度 bug。');

      final sessionABytes = await StoreUriReader.instance.read(
        'store://workspaces/${(await ws.loadMeta('group_mem'))!.homeDevice}/'
        'group_group_mem/shared/memory/group_session_a.md',
      );
      expect(utf8.decode(sessionABytes), '任务 A 结论：完成基础架构。');
    });
  });

  group('编排 inbox 读取 (readOrchestrationInbox)', () {
    test('since 过滤：只消费 issued_at 晚于本轮开始的文件', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_inbox',
        members: [(agentId: 'she', role: 'admin')],
      );
      final home = (await ws.loadMeta('group_inbox'))!.homeDevice;
      final inboxDir = ws.inboxDir('group_inbox', 'group_session_x');
      final writeInbox = (String file, Map<String, dynamic> payload) =>
          StoreService.instance.writeWorkspaceFile(
        homeDeviceId: home,
        relPath: '$inboxDir/$file',
        content: Uint8List.fromList(
          utf8.encode(jsonEncode(payload)),
        ),
      );

      // 旧决定（本轮开始前写入）→ 不消费
      await writeInbox('dispatch.json', {
        'issued_at': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(),
        'kind': 'dispatch',
        'mode': 'concurrent',
        'steps': [{'step': 1, 'agents': ['Coder'], 'task': '旧任务'}],
      });
      // 新决定（本轮开始后写入）→ 消费
      await writeInbox('finish.json', {
        'issued_at': DateTime.now().add(const Duration(seconds: 1)).toUtc().toIso8601String(),
        'kind': 'finish',
        'action': 'done',
      });
      await writeInbox('mentions.json', {
        'issued_at': DateTime.now().add(const Duration(seconds: 2)).toUtc().toIso8601String(),
        'kind': 'mention',
        'mentions': [{'name': 'Coder', 'notify': true, 'reason': '协助'}],
      });

      final inbox = await ws.readOrchestrationInbox(
        groupId: 'group_inbox',
        sessionId: 'group_session_x',
        since: DateTime.now(),
        homeDevice: home,
      );
      expect(inbox.dispatch, isNull); // 旧文件被过滤
      expect(inbox.finish!['action'], 'done');
      final mentions = inbox.mentions!['mentions'] as List;
      expect(mentions.single['name'], 'Coder');
      expect(inbox.isEmpty, isFalse);
    });

    test('homeDevice 为空或不存在的空间 → 空 inbox', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_inbox2',
        members: [(agentId: 'she', role: 'admin')],
      );
      final inbox = await ws.readOrchestrationInbox(
        groupId: 'group_inbox2',
        sessionId: 's',
        since: DateTime.now(),
        homeDevice: '',
      );
      expect(inbox.isEmpty, isTrue);
    });
  });

  group('跨设备 ACL (grantPeerAccess)', () {
    test('friend 设备追加成员目录与 shared 白名单；owner 设备不动；幂等',
        () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_acl',
        members: [(agentId: 'agent-peer', role: 'member')],
      );
      final ps = PeerStorageService();
      final now = DateTime.now().millisecondsSinceEpoch;
      PairedPeer peer(String id, String trust) => PairedPeer(
            id: id,
            deviceName: 'dev-$id',
            deviceId: id,
            publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
            fingerprint: 'fp-$id',
            pairedAt: now,
            trustLevel: trust,
          );
      await ps.savePeer(peer('peer-friend', 'friend'));
      await ps.savePeer(peer('peer-owner', 'owner'));

      await ws.grantPeerAccess(
        groupId: 'group_acl',
        agentId: 'agent-peer',
        peerId: 'peer-friend',
      );
      await ws.grantPeerAccess(
        groupId: 'group_acl',
        agentId: 'agent-peer',
        peerId: 'peer-owner',
      );

      // friend：显式前缀条目
      final friendPaths = (await ps.getSharedStoreEntries('peer-friend'))
          .where((e) => e.space == 'workspaces')
          .map((e) => e.path)
          .toList();
      expect(friendPaths, contains('group_group_acl/members/agent-peer'));
      expect(friendPaths, contains('group_group_acl/shared'));

      // owner：不动（默认整区开放，显式前缀会收窄访问）
      final ownerPaths = (await ps.getSharedStoreEntries('peer-owner'))
          .where((e) => e.space == 'workspaces')
          .map((e) => e.path)
          .toList();
      expect(ownerPaths, isEmpty);

      // 幂等：再次调用不产生重复条目
      await ws.grantPeerAccess(
        groupId: 'group_acl',
        agentId: 'agent-peer',
        peerId: 'peer-friend',
      );
      final again = (await ps.getSharedStoreEntries('peer-friend'))
          .where((e) => e.space == 'workspaces')
          .toList();
      expect(again.length, 2);
    });

    test('revokePeerAccess 移除成员目录条目，保留 shared', () async {
      await ws.ensureGroupWorkspace(
        groupId: 'group_acl2',
        members: [(agentId: 'agent-peer', role: 'member')],
      );
      final ps = PeerStorageService();
      await ps.savePeer(PairedPeer(
        id: 'peer-friend2',
        deviceName: 'dev',
        deviceId: 'peer-friend2',
        publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
        fingerprint: 'fp2',
        pairedAt: DateTime.now().millisecondsSinceEpoch,
        trustLevel: 'friend',
      ));
      await ws.grantPeerAccess(
        groupId: 'group_acl2',
        agentId: 'agent-peer',
        peerId: 'peer-friend2',
      );

      await ws.revokePeerAccess(
        groupId: 'group_acl2',
        agentId: 'agent-peer',
        peerId: 'peer-friend2',
      );
      final paths = (await ps.getSharedStoreEntries('peer-friend2'))
          .where((e) => e.space == 'workspaces')
          .map((e) => e.path)
          .toList();
      expect(paths, isNot(contains('group_group_acl2/members/agent-peer')));
      expect(paths, contains('group_group_acl2/shared')); // shared 保留
    });
  });
}
