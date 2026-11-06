import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// A7-8：删除正在跑的节点会话时，必须和 stop 两处一样把 sessionKey +
/// runtimeTurnId 传给 cancelActiveDmTask，主机发起的 `flow-` 回合才会被停掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelId = 'psess_flow_deadbe12_impl';
  const sessionKey = 'agent:agent-7:flow_deadbe12_impl';
  const turnId = 'flow-deadbe12-impl-a1';

  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  test('删除运行中的节点会话会发 flow- 取消', () async {
    final mirror = SessionRuntimeMirror();
    if (getIt.isRegistered<SessionRuntimeMirror>()) {
      await getIt.unregister<SessionRuntimeMirror>();
    }
    getIt.registerSingleton<SessionRuntimeMirror>(mirror);
    mirror.apply({
      'session_key': sessionKey,
      'state': 'running',
      'turn_id': turnId,
      'peer_id': 'p1',
      'revision': 1,
      'hub_id': 'hub-a',
      'flow': true,
    }, force: true);

    final sentFrames = <Map<String, dynamic>>[];
    final svc = PeerAgentClientService.instance;
    svc.debugSendControlOverride = (peerId, json) async {
      sentFrames.add(Map<String, dynamic>.from(json));
      return true;
    };
    addTearDown(() async {
      svc.debugSendControlOverride = null;
      if (getIt.isRegistered<SessionRuntimeMirror>()) {
        await getIt.unregister<SessionRuntimeMirror>();
      }
    });

    final controller = ChatController(
      agentId: 'agent-7',
      initialChannelId: channelId,
      getUserId: () => 'user',
      getUserName: () => 'User',
    );
    addTearDown(controller.dispose);
    controller.currentChannelId = channelId;
    expect(controller.currentChannelRuntimeTurnId, turnId);

    await controller.batchDeleteSessions([channelId], isGroup: false);

    for (var i = 0; i < 50; i++) {
      if (sentFrames.any((frame) => frame['type'] == 'agent_cancel')) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      sentFrames.where((frame) =>
          frame['type'] == 'agent_cancel' && frame['request_id'] == turnId),
      hasLength(1),
      reason: '裸调 cancelActiveDmTask 找不到主机发起的 flow- 回合，删除后主机继续跑',
    );
  });

  test('A8-6: 批量删两个运行中的节点会话，两个 flow- 取消都发出', () async {
    const channelA = 'psess_flow_a86_a';
    const channelB = 'psess_flow_a86_b';
    const keyA = 'agent:agent-7:flow_a86_a';
    const keyB = 'agent:agent-7:flow_a86_b';
    const turnA = 'flow-a86-a1';
    const turnB = 'flow-a86-b1';

    final mirror = SessionRuntimeMirror();
    if (getIt.isRegistered<SessionRuntimeMirror>()) {
      await getIt.unregister<SessionRuntimeMirror>();
    }
    getIt.registerSingleton<SessionRuntimeMirror>(mirror);
    for (final entry in [
      (key: keyA, turn: turnA),
      (key: keyB, turn: turnB),
    ]) {
      mirror.apply({
        'session_key': entry.key,
        'state': 'running',
        'turn_id': entry.turn,
        'peer_id': 'p1',
        'revision': 1,
        'flow': true,
      }, force: true);
    }

    final sentFrames = <Map<String, dynamic>>[];
    final svc = PeerAgentClientService.instance;
    svc.debugSendControlOverride = (peerId, json) async {
      sentFrames.add(Map<String, dynamic>.from(json));
      return true;
    };
    addTearDown(() async {
      svc.debugSendControlOverride = null;
      if (getIt.isRegistered<SessionRuntimeMirror>()) {
        await getIt.unregister<SessionRuntimeMirror>();
      }
    });

    final controller = ChatController(
      agentId: 'agent-7',
      initialChannelId: channelA,
      getUserId: () => 'user',
      getUserName: () => 'User',
    );
    addTearDown(controller.dispose);
    controller.currentChannelId = channelA;

    await controller.batchDeleteSessions([channelA, channelB], isGroup: false);

    for (var i = 0; i < 50; i++) {
      if (sentFrames.where((f) => f['type'] == 'agent_cancel').length >= 2) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final cancelled = sentFrames
        .where((f) => f['type'] == 'agent_cancel')
        .map((f) => f['request_id'])
        .toSet();
    expect(cancelled, containsAll(<String>[turnA, turnB]),
        reason: '只停当前频道会让另一个节点回合继续跑，下一条消息又把它建回来');
  });
}
