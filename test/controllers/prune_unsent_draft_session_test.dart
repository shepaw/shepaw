import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/composer_draft_service.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 新建/切换会话时，输入框里还有没发出去的内容就不要把这条空会话清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  late ComposerDraftService drafts;

  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    db = LocalDatabaseService();
    await db.database;
  });

  setUp(() async {
    drafts = ComposerDraftService();
    if (getIt.isRegistered<ComposerDraftService>()) {
      await getIt.unregister<ComposerDraftService>();
    }
    getIt.registerSingleton<ComposerDraftService>(drafts);
  });

  const agentId = 'agent-unsent';
  const userId = 'user-unsent';

  Future<ChatController> openDm(String channelId) async {
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'DM',
        type: 'dm',
        memberIds: [userId, agentId],
      ),
      userId,
    );
    final controller = ChatController(
      agentId: agentId,
      initialChannelId: channelId,
      getUserId: () => userId,
      getUserName: () => 'User',
    );
    controller.currentChannelId = channelId;
    return controller;
  }

  test('私聊：输入框有未发送草稿时，新建会话不删除当前会话', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_${agentId}_${userId}_$suffix';
    final controller = await openDm(channelId);
    addTearDown(controller.dispose);

    drafts.setDraft(channelId, '还没发出去', agentId: agentId);

    await controller.pruneEmptySessionBeforeSwitch(
      nextChannelId: 'dm_${agentId}_${userId}_${suffix + 1}',
    );

    expect(await db.getChannelById(channelId), isNotNull);
    expect(drafts.getDraft(channelId), '还没发出去');
  });

  test('私聊：输入框是空的，误点新建会话仍删除空会话', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_${agentId}_${userId}_empty_$suffix';
    final controller = await openDm(channelId);
    addTearDown(controller.dispose);

    await controller.pruneEmptySessionBeforeSwitch(
      nextChannelId: 'dm_${agentId}_${userId}_next_$suffix',
    );

    expect(await db.getChannelById(channelId), isNull);
  });

  test('私聊：只有列表别名上的草稿不算这条会话的未发送内容', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_${agentId}_${userId}_alias_$suffix';
    final controller = await openDm(channelId);
    addTearDown(controller.dispose);

    drafts.setDraft(ComposerDraftService.agentListKey(agentId), '别的会话留下的');

    await controller.pruneEmptySessionBeforeSwitch(
      nextChannelId: 'dm_${agentId}_${userId}_alias_next_$suffix',
    );

    expect(await db.getChannelById(channelId), isNull);
  });

  test('群聊：子会话输入框有未发送草稿时留下，空白子会话仍删除', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final parentId = 'group_parent_$suffix';
    final draftedId = 'group_draft_$suffix';
    final emptyId = 'group_empty_$suffix';
    final parent = Channel.withMemberIds(
      id: parentId,
      name: 'Group',
      type: 'group',
      memberIds: [userId, agentId],
    );
    await db.createChannel(parent, userId);
    for (final id in [draftedId, emptyId]) {
      await db.createChannel(
        Channel.withMemberIds(
          id: id,
          name: id,
          type: 'group',
          memberIds: [userId, agentId],
          parentGroupId: parentId,
        ),
        userId,
      );
    }

    final controller = ChatController(
      agentId: agentId,
      getUserId: () => userId,
      getUserName: () => 'User',
    );
    addTearDown(controller.dispose);
    controller.isGroupMode = true;
    controller.groupChannel = parent;

    drafts.setDraft(draftedId, '群里还没发', groupFamilyId: parentId);
    controller.currentChannelId = draftedId;
    await controller.pruneEmptySessionBeforeSwitch(
      nextChannelId: 'group_next_$suffix',
    );
    expect(await db.getChannelById(draftedId), isNotNull);

    controller.currentChannelId = emptyId;
    await controller.pruneEmptySessionBeforeSwitch(
      nextChannelId: 'group_next_$suffix',
    );
    expect(await db.getChannelById(emptyId), isNull);
  });
}
