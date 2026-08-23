import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/storage/storage_folder_label.dart';
import 'package:shepaw/storage/store_protocol.dart';

import 'test_harness.dart';

/// 储物袋目录名 → Agent/群可读标签解析器单测。
void main() {
  late LocalDatabaseService db;

  setUpAll(() async {
    await StorageTestHarness.init();
    db = LocalDatabaseService();
  });

  setUp(() async {
    await db.database; // 确保已建库
    await db.clearAllData();
  });

  Future<void> seedGroup(
    String id,
    String name, {
    String type = 'group',
    String avatar = '',
  }) {
    return db.createChannel(
      Channel(
        id: id,
        name: name,
        type: type,
        members: const [],
        avatar: avatar,
      ),
      'owner',
    );
  }

  Future<void> seedAgent(
    String id,
    String name, {
    String avatar = '🤖',
  }) {
    return db.createAgent(
      Agent(
        id: id,
        name: name,
        avatar: avatar,
        capabilities: const [],
        provider: const AgentProvider(name: 'test', platform: 'test', type: 'test'),
        status: const AgentStatus(state: 'offline'),
      ),
      'owner',
    );
  }

  test('runtime 下 group_<uuid> 目录解析为群', () async {
    await seedGroup('group_abc', '产品讨论群', avatar: '👥');

    final label = await resolveStorageFolderLabel(StoreSpace.runtime, 'group_abc');

    expect(label.resolved, isTrue);
    expect(label.isGroup, isTrue);
    expect(label.label, '产品讨论群');
    expect(label.avatar, '👥');
  });

  test('workspaces 下 group_group_<uuid> 目录剥一层前缀解析为群', () async {
    await seedGroup('group_abc', '产品讨论群');

    final label =
        await resolveStorageFolderLabel(StoreSpace.workspaces, 'group_group_abc');

    expect(label.resolved, isTrue);
    expect(label.isGroup, isTrue);
    expect(label.label, '产品讨论群');
  });

  test('runtime 下 agent id 目录解析为 Agent（含头像）', () async {
    await seedAgent('agent_xyz', '小助手', avatar: 'https://x/avatar.png');

    final label =
        await resolveStorageFolderLabel(StoreSpace.runtime, 'agent_xyz');

    expect(label.resolved, isTrue);
    expect(label.isGroup, isFalse);
    expect(label.label, '小助手');
    expect(label.avatar, 'https://x/avatar.png');
  });

  test('未知 id / 设备指纹保持原样 unresolved', () async {
    final label =
        await resolveStorageFolderLabel(StoreSpace.runtime, 'no_such_id');

    expect(label.resolved, isFalse);
    expect(label.label, 'no_such_id');
    expect(label.avatar, isEmpty);
  });

  test('files 分区即使目录名等于已播种 agent id 也不解析', () async {
    await seedAgent('agent_xyz', '小助手');

    final label = await resolveStorageFolderLabel(StoreSpace.files, 'agent_xyz');

    expect(label.resolved, isFalse);
    expect(label.label, 'agent_xyz');
  });

  test('DM channel 不标为群，回落 unresolved', () async {
    await seedGroup('dm_1', '单聊会话', type: 'dm');

    final label = await resolveStorageFolderLabel(StoreSpace.runtime, 'dm_1');

    expect(label.resolved, isFalse);
    expect(label.isGroup, isFalse);
    expect(label.label, 'dm_1');
  });

  test('群头像为空时 avatar 为空串、isGroup 为 true（驱动默认群图标）', () async {
    await seedGroup('group_empty', '空头像群');

    final label =
        await resolveStorageFolderLabel(StoreSpace.runtime, 'group_empty');

    expect(label.resolved, isTrue);
    expect(label.isGroup, isTrue);
    expect(label.avatar, isEmpty);
  });

  test('边界：目录名恰为 group_ 时不抛异常、保持 unresolved', () async {
    final label = await resolveStorageFolderLabel(StoreSpace.runtime, 'group_');

    expect(label.resolved, isFalse);
    expect(label.label, 'group_');
  });
}
