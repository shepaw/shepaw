import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/conversation_list_controller.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_api_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite/sqflite.dart' show Database;

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

/// 可注入的 LocalApiService 替身：仅覆写 getAgents，可配置前 N 次抛错，
/// 其余成员走 noSuchMethod（refresh 只用到 getAgents）。
class _FakeApiService implements LocalApiService {
  _FakeApiService(this.agents, {this.failuresBeforeSuccess = 0});

  final List<Agent> agents;
  final int failuresBeforeSuccess;
  int calls = 0;

  @override
  Future<List<Agent>> getAgents() async {
    calls++;
    if (calls <= failuresBeforeSuccess) {
      throw StateError('agents unavailable (attempt $calls)');
    }
    return agents;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// database 即抛错的 LocalDatabaseService 替身：任何 DAO（extension）最终都
/// 依赖 [LocalDatabaseService.database]，用它模拟「groups 这一路整体失败」。
class _BrokenDbService implements LocalDatabaseService {
  @override
  Future<Database> get database async => throw StateError('db unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 可注入的 ChatService 替身：仅实现预览查询用到的两个成员。
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

Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    // ffi + 临时目录的 method channel mock，让真实 LocalDatabaseService /
    // PeerStorageService 跑在纯单元测试环境（无需真机插件）。
    await StorageTestHarness.init();
  });

  group('ConversationListController.refresh 失败自愈', () {
    test('某一数据源失败不影响其余源，并暴露 hasLoadError', () async {
      final api = _FakeApiService([_agent('a1', 'Alpha')]);
      final controller = ConversationListController(
        apiService: api,
        // groups 一路（依赖 database 的 DAO）抛错。
        databaseService: _BrokenDbService(),
        chatService: _FakeChatService(),
      );

      await controller.refresh();

      // agents 这一路成功：即使 groups 失败，agent 仍被赋值并渲染。
      expect(controller.agents.map((a) => a.id), ['a1']);
      // 有失败 → UI 应展示错误而非「请添加 agent」。
      expect(controller.hasLoadError, isTrue);
      // 自动重试尚未耗尽，首刷转圈期间不释放 loading（避免错误一闪而过）。
      expect(controller.isLoading, isTrue);

      controller.dispose();
    });

    test('瞬时失败后 ~500ms 自动补刷自愈', () async {
      final api = _FakeApiService(
        [_agent('she', 'She')],
        failuresBeforeSuccess: 1,
      );
      final controller = ConversationListController(
        apiService: api,
        // 真实 DB（ffi 临时库）：groups / peers 两路均成功，只有 agents 首刷失败。
        databaseService: LocalDatabaseService(),
        chatService: _FakeChatService(),
      );

      await controller.refresh();
      expect(controller.hasLoadError, isTrue);
      expect(controller.agents, isEmpty);

      // 等待自动重试（500ms 防抖）把首刷失败的 agent 补进来。
      await _pumpUntil(
        () => controller.agents.isNotEmpty && !controller.hasLoadError,
      );

      expect(controller.agents.map((a) => a.id), ['she']);
      expect(controller.hasLoadError, isFalse);
      expect(controller.isLoading, isFalse);

      controller.dispose();
    });

    test('三路都成功（即便确实没数据）不触发自动重试', () async {
      final api = _FakeApiService(const []);
      final controller = ConversationListController(
        apiService: api,
        databaseService: LocalDatabaseService(),
        chatService: _FakeChatService(),
      );

      await controller.refresh();
      expect(controller.hasLoadError, isFalse);
      expect(controller.isLoading, isFalse);
      expect(api.calls, 1);

      // 停留超过一个重试窗口，确认没有多余的空转补刷。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(api.calls, 1);

      controller.dispose();
    });
  });
}
