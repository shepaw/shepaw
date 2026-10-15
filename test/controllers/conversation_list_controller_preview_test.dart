import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/conversation_list_controller.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/app_lifecycle_service.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_api_service.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

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

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  test('预览跨会话取最新一条，正在看的会话不计未读', () async {
    final db = LocalDatabaseService();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-preview-$suffix';
    final older = 'dm_older_$suffix';
    final newer = 'dm_newer_$suffix';

    for (final channelId in [older, newer]) {
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
    await db.createMessage(
      id: 'm-older-$suffix',
      channelId: older,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: '旧回复',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      isRead: 0,
    );
    await db.createMessage(
      id: 'm-newer-$suffix',
      channelId: newer,
      senderId: agentId,
      senderType: 'agent',
      senderName: 'A',
      content: '新回复',
      createdAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
      isRead: 0,
    );

    AppLifecycleService().setActiveChannel(newer);
    addTearDown(() => AppLifecycleService().setActiveChannel(null));

    final controller = ConversationListController(
      apiService: _FakeApiService([_agent(agentId, 'Preview')]),
      databaseService: db,
      chatService: _FakeChatService(),
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.latestMessages[agentId]?['id'], 'm-newer-$suffix');
    // 预览指向有消息的那条会话，而不是最近被碰过的空壳。
    expect(controller.agentChannelId(agentId), newer);
    // 两条未读里扣掉正在看的那条，只剩旧会话的 1 条。
    expect(controller.unreadCounts[agentId], 1);
  });

  test('没有会话的 agent 回落到生成的频道 id', () async {
    final controller = ConversationListController(
      apiService: _FakeApiService([_agent('agent-no-session', 'Empty')]),
      databaseService: LocalDatabaseService(),
      chatService: _FakeChatService(),
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.agentChannelId('agent-no-session'), 'ch_agent-no-session');
    expect(controller.latestMessages['agent-no-session'], isNull);
    expect(controller.unreadCounts['agent-no-session'], 0);
  });
}
