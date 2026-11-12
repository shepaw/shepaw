import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/chat_events.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/conversation_selection.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/chat_navigation_service.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/route_gate.dart';
import 'package:shepaw/services/session/last_activated_session_store.dart';
import 'package:shepaw/storage/pouch_session.dart';

import '../storage/test_harness.dart';

/// 深链 / 「发起对话」的真实接线：只有用户点进一条明确会话时才记指针，
/// 兜底算出来的频道不能把上一次人工点选钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LastActivatedSessionStore store;
  late LocalDatabaseService db;
  final opened = <ConversationSelection>[];

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LastActivatedSessionStore(
      prefs: await SharedPreferences.getInstance(),
    );
    getIt.registerSingleton<LastActivatedSessionStore>(store);
    getIt.registerSingleton<ChatService>(_FakeChatService());
    db = LocalDatabaseService();

    // 让 deepLinkLoginRoute 放行，并用桌面 handler 接住 selection，避免
    // 单元测试里搭整棵 Navigator。
    PouchSessionStore.readOverride = () async => PouchSession(
          hubUrl: 'ws://hub',
          pouchId: 'pouch',
          pouchName: 'Pouch',
          hostPeerId: 'peer',
          token: 'token',
          sessionId: 'sid',
          expiresAtMs:
              DateTime.now().millisecondsSinceEpoch + const Duration(days: 1).inMilliseconds,
        );
    RouteGateObserver.onGate.value = false;
    opened.clear();
    ChatNavigationService.instance.setDesktopHandler(opened.add);
  });

  tearDown(() async {
    ChatNavigationService.instance.setDesktopHandler(null);
    PouchSessionStore.readOverride = null;
    PouchSessionStore.debugResetCache();
    RouteGateObserver.onGate.value = true;
    await getIt.unregister<LastActivatedSessionStore>();
    await getIt.unregister<ChatService>();
  });

  Future<void> seedDm(String channelId, String agentId) async {
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

  Future<String?> pointer(String agentId) =>
      store.read(LastActivatedSessionStore.agentKey(agentId));

  /// recorder 是 unawaited 的（生产里也不能让平台通道挡住跳转），等它落盘。
  Future<String?> eventually(String agentId) async {
    for (var i = 0; i < 100; i++) {
      final value = await pointer(agentId);
      if (value != null) return value;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return pointer(agentId);
  }

  /// 断言整个窗口里都没有写入：固定 sleep 会漏掉晚到的 unawaited 写。
  Future<void> expectNeverRecorded(String agentId) async {
    for (var i = 0; i < 20; i++) {
      expect(await pointer(agentId), isNull, reason: 'tick $i 不该写入指针');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('通知 / 深链点进明确的 DM 会记人工激活', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-deeplink-$suffix';
    final channelId = 'dm_deeplink_$suffix';
    await seedDm(channelId, agentId);

    await ChatNavigationService.instance.openChannel(
      channelId: channelId,
      agentId: agentId,
    );

    expect(opened, hasLength(1));
    expect(await eventually(agentId), channelId);
  });

  test('「发起对话」兜底出来的频道不覆盖已有指针', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-contacts-$suffix';
    final shell = 'dm_shell_$suffix';
    await seedDm(shell, agentId);
    // 指针指向一条已不「保留」的空壳：resolve 会回落到活跃时间兜底，
    // 但这次兜底是算出来的，不是用户点选，不能写回指针。
    await store.remember(
      LastActivatedSessionStore.agentKey(agentId),
      shell,
    );

    await ChatNavigationService.instance.openAgentConversation(
      agentId: agentId,
      agentName: 'A',
    );

    expect(opened.single.channelId, 'ch_$agentId');
    expect(await pointer(agentId), shell);
  });

  test('群会话深链不写 agent 指针', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-groupdeeplink-$suffix';
    final groupId = 'group_$suffix';
    await db.createChannel(
      Channel.withMemberIds(
        id: groupId,
        name: groupId,
        type: 'group',
        memberIds: ['user', agentId],
      ),
      'user',
    );

    await ChatNavigationService.instance.openChannel(
      channelId: groupId,
      agentId: agentId,
    );

    expect(opened.single.groupFamilyId, isNotNull);
    await expectNeverRecorded(agentId);
  });

  test('深链被丢弃（没有 navigator / 桌面 handler）时不写指针', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-dropped-$suffix';
    final channelId = 'dm_dropped_$suffix';
    await seedDm(channelId, agentId);
    ChatNavigationService.instance.setDesktopHandler(null);

    await ChatNavigationService.instance.openChannel(
      channelId: channelId,
      agentId: agentId,
    );

    await expectNeverRecorded(agentId);
  });

  test('清空 / 删除补位事件标为非人工点选，正常新建事件默认是人工点选', () {
    expect(NavigateToSessionEvent(channelId: 'ch-a').manualActivation, isTrue);
    expect(
      NavigateToSessionEvent(
        channelId: 'ch-b',
        manualActivation: false,
      ).manualActivation,
      isFalse,
    );
  });
}

class _FakeChatService implements ChatService {
  @override
  final ValueNotifier<Set<String>> typingAgentIds = ValueNotifier<Set<String>>({});
  @override
  final ValueNotifier<Set<String>> typingChannelIds = ValueNotifier<Set<String>>({});

  @override
  Future<String?> getLatestActiveChannelId(String userId, String agentId) async =>
      null;

  @override
  String generateChannelId(String userId, String agentId) => 'ch_$agentId';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
