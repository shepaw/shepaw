import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/conversation_list_controller.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/composer_draft_service.dart';
import 'package:shepaw/services/local_api_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/session/activated_session_recorder.dart';
import 'package:shepaw/services/session/last_activated_session_store.dart';

import '../storage/test_harness.dart';

/// 对话入口要回到「用户最近一次亲手点开、而且保留下来」的那条会话。
///
/// 主机同步会覆写 channels.updated_at，所以这个指针单独存在
/// SharedPreferences 里；只有有消息或还有未发送草稿的会话才算「保留下来」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  late ComposerDraftService drafts;
  late LastActivatedSessionStore store;

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    // 每次重置 mock，指针和草稿都不串到下一个用例。
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = LastActivatedSessionStore(prefs: prefs);
    drafts = ComposerDraftService();
    if (getIt.isRegistered<ComposerDraftService>()) {
      await getIt.unregister<ComposerDraftService>();
    }
    getIt.registerSingleton<ComposerDraftService>(drafts);
    db = LocalDatabaseService();
  });

  tearDown(() async {
    if (getIt.isRegistered<ComposerDraftService>()) {
      await getIt.unregister<ComposerDraftService>();
    }
    if (getIt.isRegistered<LastActivatedSessionStore>()) {
      await getIt.unregister<LastActivatedSessionStore>();
    }
  });

  Future<void> seedChannel(String channelId, String agentId) async {
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: channelId,
        type: 'dm',
        memberIds: ['user', agentId],
      ),
      'user',
    );
  }

  Future<void> seedMessage(
    String id,
    String channelId,
    String agentId,
    int epochMs,
  ) async {
    await db.createMessage(
      id: id,
      channelId: channelId,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: '回复 $id',
      createdAt: DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true),
      isRead: 0,
    );
  }

  ConversationListController controllerFor(
    String agentId, {
    LastActivatedSessionStore? activatedStore,
  }) {
    final controller = ConversationListController(
      apiService: _FakeApiService([_agent(agentId, 'Preview')]),
      databaseService: db,
      chatService: _FakeChatService(),
      lastActivatedStore: activatedStore ?? store,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('新建会话只有未发送草稿时，对话入口回到这条会话', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-draft-$suffix';
    final older = 'dm_older_$suffix';
    final fresh = 'dm_fresh_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(fresh, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    drafts.setDraft(fresh, '还没发出去', agentId: agentId);
    await store.remember(
      LastActivatedSessionStore.agentKey(agentId),
      fresh,
    );

    final controller = controllerFor(agentId);
    await controller.refresh();

    // 入口落在保留下来的新会话；列表预览文字仍取跨会话最新一条消息。
    expect(controller.agentChannelId(agentId), fresh);
    expect(controller.latestMessages[agentId]?['id'], 'm-old-$suffix');
  });

  test('人工点开的旧会话胜过别的会话里更新的消息', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-manual-$suffix';
    final older = 'dm_older_$suffix';
    final newer = 'dm_newer_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(newer, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    await seedMessage('m-new-$suffix', newer, agentId, 9000);
    await store.remember(
      LastActivatedSessionStore.agentKey(agentId),
      older,
    );

    final controller = controllerFor(agentId);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), older);
  });

  test('没有消息也没有草稿的空壳不算「保留下来」，不进空白页', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-shell-$suffix';
    final withMessage = 'dm_msg_$suffix';
    final shell = 'dm_shell_$suffix';

    await seedChannel(withMessage, agentId);
    await seedChannel(shell, agentId);
    await seedMessage('m-$suffix', withMessage, agentId, 1000);
    await store.remember(
      LastActivatedSessionStore.agentKey(agentId),
      shell,
    );

    final controller = controllerFor(agentId);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), withMessage);
  });

  test('激活的会话被删掉后回落到有消息的那条', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-deleted-$suffix';
    final withMessage = 'dm_msg_$suffix';
    final gone = 'dm_gone_$suffix';

    await seedChannel(withMessage, agentId);
    await seedChannel(gone, agentId);
    await seedMessage('m-$suffix', withMessage, agentId, 1000);
    drafts.setDraft(gone, '还没发出去', agentId: agentId);
    await store.remember(
      LastActivatedSessionStore.agentKey(agentId),
      gone,
    );
    await db.deleteChannel(gone);

    final controller = controllerFor(agentId);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), withMessage);
  });

  test('没有指针时仍按最新消息预览', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-nopointer-$suffix';
    final older = 'dm_older_$suffix';
    final newer = 'dm_newer_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(newer, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    await seedMessage('m-new-$suffix', newer, agentId, 9000);

    final controller = controllerFor(agentId);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), newer);
  });

  test('生产路径：store 只注册在 getIt 时入口也认指针', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-getit-$suffix';
    final older = 'dm_older_$suffix';
    final fresh = 'dm_fresh_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(fresh, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    drafts.setDraft(fresh, '还没发出去', agentId: agentId);
    await store.remember(LastActivatedSessionStore.agentKey(agentId), fresh);

    // HomeScreen 构造 controller 时不注入 store，只靠组合根注册的那一份。
    getIt.registerSingleton<LastActivatedSessionStore>(store);
    final controller = ConversationListController(
      apiService: _FakeApiService([_agent(agentId, 'Preview')]),
      databaseService: db,
      chatService: _FakeChatService(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), fresh);
  });

  test('没有指针时回落到最近活跃、且保留下来的那条会话', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-active-$suffix';
    final older = 'dm_older_$suffix';
    final newer = 'dm_newer_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(newer, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    await seedMessage('m-new-$suffix', newer, agentId, 9000);
    // updated_at 是「最近打开 / 最近活动」的代理：older 被后碰过。
    await db.touchChannelUpdatedAt(newer);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.touchChannelUpdatedAt(older);

    final controller = controllerFor(agentId);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), older);
    // 列表上的预览文字仍取跨会话最新一条，不受入口落点影响。
    expect(controller.latestMessages[agentId]?['id'], 'm-new-$suffix');
  });

  test('生产链路：点选落盘 → 无注入的 controller 刷回到草稿会话', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-chain-$suffix';
    final older = 'dm_older_$suffix';
    final fresh = 'dm_fresh_$suffix';

    await seedChannel(older, agentId);
    await seedChannel(fresh, agentId);
    await seedMessage('m-old-$suffix', older, agentId, 1000);
    drafts.setDraft(fresh, '还没发出去', agentId: agentId);
    // 让 updated_at 指向旧会话：只有指针能把入口带到草稿新会话。
    await db.touchChannelUpdatedAt(fresh);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.touchChannelUpdatedAt(older);

    // 组合根只注册 store；controller 不注入，走 getIt 兜底。
    getIt.registerSingleton<LastActivatedSessionStore>(store);
    await rememberActivatedDmChannel(fresh, agentId: agentId);

    final controller = ConversationListController(
      apiService: _FakeApiService([_agent(agentId, 'Preview')]),
      databaseService: db,
      chatService: _FakeChatService(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();

    expect(controller.agentChannelId(agentId), fresh);
    expect(controller.latestMessages[agentId]?['id'], 'm-old-$suffix');
  });

  test('rememberAgentChannel 只回写列表缓存，不把桌面原位换频道当人工点选', () async {
    const agentId = 'agent-writeback';
    final controller = controllerFor(agentId);
    controller.rememberAgentChannel(agentId, 'dm_picked');

    expect(controller.agentChannelId(agentId), 'dm_picked');
    // 群 / 中转会话也会走这个回写，指针只能由会话点选处校验后写入。
    expect(
      await store.read(LastActivatedSessionStore.agentKey(agentId)),
      isNull,
    );
  });
}

Agent _agent(String id, String name) {
  return Agent(
    id: id,
    name: name,
    avatar: 'A',
    provider: const AgentProvider(
      name: 'local',
      platform: 'local',
      type: 'local',
    ),
    status: const AgentStatus(state: 'online'),
    metadata: const {},
  );
}

class _FakeApiService implements LocalApiService {
  _FakeApiService(this.agents);

  final List<Agent> agents;

  @override
  Future<List<Agent>> getAgents() async => agents;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeChatService implements ChatService {
  @override
  final ValueNotifier<Set<String>> typingAgentIds =
      ValueNotifier<Set<String>>({});
  @override
  final ValueNotifier<Set<String>> typingChannelIds =
      ValueNotifier<Set<String>>({});

  @override
  Future<String?> getLatestActiveChannelId(
      String userId, String agentId) async {
    return null;
  }

  @override
  String generateChannelId(String userId, String agentId) => 'ch_$agentId';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
