import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/session/activated_session_recorder.dart';
import 'package:shepaw/services/session/last_activated_session_store.dart';

import '../storage/test_harness.dart';

/// 会话点选处的写入统一走 recorder：只认本 agent 的普通 DM，别让群 / 中转
/// 会话把已经记下的有效指针冲掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  late LastActivatedSessionStore store;

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LastActivatedSessionStore(
      prefs: await SharedPreferences.getInstance(),
    );
    db = LocalDatabaseService();
    if (getIt.isRegistered<LastActivatedSessionStore>()) {
      await getIt.unregister<LastActivatedSessionStore>();
    }
    getIt.registerSingleton<LastActivatedSessionStore>(store);
    // 不注册 LocalDatabaseService：recorder 会自己 new 一个，ffi 下同一个
    // 数据库路径仍是同一份数据。
  });

  tearDown(() async {
    await getIt.unregister<LastActivatedSessionStore>();
  });

  Future<void> seed(
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

  Future<String?> pointer(String agentId) =>
      store.read(LastActivatedSessionStore.agentKey(agentId));

  test('普通 DM 会记指针，agentId 为空时从成员里解析', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-rec-$suffix';
    final channelId = 'dm_rec_$suffix';
    await seed(channelId, agentId);
    // 让 agents 表里有这行，getChannelMembers 才会把该成员标成 agent。
    await db.createRemoteAgent(_remoteAgent(agentId));

    await rememberActivatedDmChannel(channelId);

    expect(await pointer(agentId), channelId);
  });

  test('调用方给出 agentId 时按它归档（跨 agent 复制会话）', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-target-$suffix';
    final channelId = 'dm_copied_$suffix';
    await seed(channelId, agentId);

    await rememberActivatedDmChannel(channelId, agentId: agentId);

    expect(await pointer(agentId), channelId);
  });

  test('群 / 群成员中转 / She 中转 / 不存在的频道都不写', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final agentId = 'agent-skip-$suffix';
    final group = 'group_$suffix';
    final member = 'dm_member_$suffix';
    final relay = 'dm_relay_$suffix';
    await seed(group, agentId, type: 'group');
    await seed(member, agentId, sourceGroupChannelId: group);
    await seed(relay, agentId, sourceSheChannelId: 'she_$suffix');

    for (final id in [group, member, relay, 'dm_missing_$suffix']) {
      await rememberActivatedDmChannel(id, agentId: agentId);
    }

    expect(await pointer(agentId), isNull);
  });
}

RemoteAgent _remoteAgent(String id) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: 'Recorder',
    token: 't',
    endpoint: 'local',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.http,
    createdAt: now,
    updatedAt: now,
  );
}
