import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/chat_navigation_service.dart';
import 'package:shepaw/services/composer_draft_service.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 通讯录 / Agent 详情「发起对话」也认人工激活指针，但落点必须和会话列表
/// 入口同口径：本 agent 的普通 DM、且真的保留下来了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() {
    db = LocalDatabaseService();
  });

  tearDown(() async {
    if (getIt.isRegistered<ComposerDraftService>()) {
      await getIt.unregister<ComposerDraftService>();
    }
  });

  Future<void> seedChannel(
    String channelId,
    String agentId, {
    String type = 'dm',
    String? sourceGroupChannelId,
    String? sourceSheChannelId,
  }) async {
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: channelId,
        type: type,
        memberIds: ['user', agentId],
        sourceGroupChannelId: sourceGroupChannelId,
        sourceSheChannelId: sourceSheChannelId,
      ),
      'user',
    );
  }

  Future<void> seedMessage(String id, String channelId, String agentId) async {
    await db.createMessage(
      id: id,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: '回复 $id',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      isRead: 0,
    );
  }

  Future<String?> resolve(String agentId, String? remembered) =>
      ChatNavigationService.resolveRememberedAgentChannel(
        db: db,
        agentId: agentId,
        remembered: remembered,
      );

  test('有消息的普通 DM 可以作为落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-msg-$suffix';
    final channelId = 'dm_msg_$suffix';
    await seedChannel(channelId, agentId);
    await seedMessage('m-$suffix', channelId, agentId);

    expect(await resolve(agentId, channelId), channelId);
  });

  test('只有未发送草稿的新会话也可以作为落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-draft-$suffix';
    final channelId = 'dm_draft_$suffix';
    await seedChannel(channelId, agentId);
    final drafts = ComposerDraftService();
    getIt.registerSingleton<ComposerDraftService>(drafts);
    drafts.setDraft(channelId, '还没发出去', agentId: agentId);

    expect(await resolve(agentId, channelId), channelId);
  });

  test('没消息也没草稿的空壳不作落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-shell-$suffix';
    final channelId = 'dm_shell_$suffix';
    await seedChannel(channelId, agentId);

    expect(await resolve(agentId, channelId), isNull);
  });

  test('空指针 / 会话已被删掉不作落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-gone-$suffix';
    final channelId = 'dm_gone_$suffix';
    await seedChannel(channelId, agentId);
    await seedMessage('m-$suffix', channelId, agentId);
    await db.deleteChannel(channelId);

    expect(await resolve(agentId, null), isNull);
    expect(await resolve(agentId, ''), isNull);
    expect(await resolve(agentId, channelId), isNull);
  });

  test('别的 agent 的会话不作落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_other_$suffix';
    await seedChannel(channelId, 'agent-owner-$suffix');
    await seedMessage('m-$suffix', channelId, 'agent-owner-$suffix');

    expect(await resolve('agent-stranger-$suffix', channelId), isNull);
  });

  test('群会话 / 群成员中转 / She 中转不作落点', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-group-$suffix';
    final group = 'group_$suffix';
    final member = 'dm_member_$suffix';
    final relay = 'dm_relay_$suffix';

    await seedChannel(group, agentId, type: 'group');
    await seedChannel(
      member,
      agentId,
      sourceGroupChannelId: group,
    );
    await seedChannel(relay, agentId, sourceSheChannelId: 'she_$suffix');
    for (final id in [group, member, relay]) {
      await seedMessage('m-$id', id, agentId);
    }

    for (final id in [group, member, relay]) {
      expect(await resolve(agentId, id), isNull, reason: id);
    }
  });
}
