import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/session_runtime_mirror.dart';
import 'package:shepaw/service_locator.dart' show getIt;
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 用户主动停止时，无论 controller 的 cancel token 是否已与 turn 失联
/// （页面 reattach / 进程重启 hydrate 后 token 是新建的），都必须按 channel
/// 清掉 inflight turn 并通知对端中断 —— 否则下一次发送会被
/// 「上一轮回复仍在继续」拦截，直到 300s 空闲 watchdog 超时。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  group('PeerAgentClientService.cancelInflightTurnsForChannel', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    setUp(() {
      sentFrames.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      // 兜底清理种子 turn，避免跨用例污染单例状态。
      await svc.cancelInflightTurnsForChannel('ch-a');
      await svc.cancelInflightTurnsForChannel('ch-b');
      svc.debugSendControlOverride = null;
    });

    test('取消后 hasInflightForChannel 立即为 false，completer 以 [Stopped] 完成',
        () async {
      final future = svc.debugSeedPendingTurn(
        requestId: 'req-1',
        peerId: 'peer-1',
        channelId: 'ch-a',
      );
      expect(svc.hasInflightForChannel('ch-a'), isTrue);

      await svc.cancelInflightTurnsForChannel('ch-a');

      expect(svc.hasInflightForChannel('ch-a'), isFalse);
      final result = await future;
      expect(result.content, '[Stopped]');
      expect(result.requestId, 'req-1');
    });

    test('向对端发送 agent_cancel 控制帧', () async {
      svc.debugSeedPendingTurn(
        requestId: 'req-2',
        peerId: 'peer-1',
        channelId: 'ch-a',
      );

      await svc.cancelInflightTurnsForChannel('ch-a');

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.peerId, 'peer-1');
      expect(sentFrames.single.json['type'], 'agent_cancel');
      expect(sentFrames.single.json['request_id'], 'req-2');
    });

    test('suspended turn 取消后登记 _cancelledWhileSuspended（重连补发 cancel 而非 resume）',
        () async {
      svc.debugSeedPendingTurn(
        requestId: 'req-3',
        peerId: 'peer-9',
        channelId: 'ch-a',
        suspended: true,
      );

      await svc.cancelInflightTurnsForChannel('ch-a');

      expect(svc.debugCancelledWhileSuspended['req-3'], 'peer-9');
    });

    test('只取消匹配 channel 的 turn，其他 channel 不受影响', () async {
      svc.debugSeedPendingTurn(
        requestId: 'req-a',
        peerId: 'peer-1',
        channelId: 'ch-a',
      );
      final other = svc.debugSeedPendingTurn(
        requestId: 'req-b',
        peerId: 'peer-1',
        channelId: 'ch-b',
      );

      await svc.cancelInflightTurnsForChannel('ch-a');

      expect(svc.hasInflightForChannel('ch-a'), isFalse);
      expect(svc.hasInflightForChannel('ch-b'), isTrue);
      expect(sentFrames.map((f) => f.json['request_id']), ['req-a']);

      await svc.cancelInflightTurnsForChannel('ch-b');
      expect((await other).content, '[Stopped]');
    });

    test('空 channel / 无匹配 turn 时为空操作', () async {
      await svc.cancelInflightTurnsForChannel('');
      await svc.cancelInflightTurnsForChannel('ch-nonexistent');

      expect(sentFrames, isEmpty);
      expect(svc.hasInflightForChannel('ch-nonexistent'), isFalse);
    });
  });

  group('PeerAgentClientService.cancelInflightTurnForAgent', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    setUp(() {
      sentFrames.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      await svc.cancelInflightTurnsForChannel('ch-a');
      await svc.cancelInflightTurnsForChannel('ch-b');
      svc.debugSendControlOverride = null;
    });

    test('只取消匹配 channel+localAgentId 的 turn，同 channel 其他 agent 不受影响', () async {
      final mine = svc.debugSeedPendingTurn(
        requestId: 'req-1',
        peerId: 'peer-1',
        channelId: 'ch-a',
        localAgentId: 'agent-1',
      );
      final other = svc.debugSeedPendingTurn(
        requestId: 'req-2',
        peerId: 'peer-1',
        channelId: 'ch-a',
        localAgentId: 'agent-2',
      );

      await svc.cancelInflightTurnForAgent('ch-a', 'agent-1');

      // 只有 agent-1 的 turn 被 [Stopped] 完成；agent-2 仍在途。
      expect((await mine).content, '[Stopped]');
      expect(svc.hasInflightForChannel('ch-a'), isTrue);

      await svc.cancelInflightTurnForAgent('ch-a', 'agent-2');
      expect((await other).content, '[Stopped]');
      expect(svc.hasInflightForChannel('ch-a'), isFalse);
    });

    test('只向对端发送匹配 requestId 的 agent_cancel 控制帧', () async {
      svc.debugSeedPendingTurn(
        requestId: 'req-1',
        peerId: 'peer-1',
        channelId: 'ch-a',
        localAgentId: 'agent-1',
      );
      svc.debugSeedPendingTurn(
        requestId: 'req-2',
        peerId: 'peer-1',
        channelId: 'ch-a',
        localAgentId: 'agent-2',
      );

      await svc.cancelInflightTurnForAgent('ch-a', 'agent-1');

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.json['type'], 'agent_cancel');
      expect(sentFrames.single.json['request_id'], 'req-1');
    });

    test('空 channel / 空 localAgentId / 无匹配 turn 时为空操作', () async {
      svc.debugSeedPendingTurn(
        requestId: 'req-1',
        peerId: 'peer-1',
        channelId: 'ch-a',
        localAgentId: 'agent-1',
      );

      await svc.cancelInflightTurnForAgent('', 'agent-1');
      await svc.cancelInflightTurnForAgent('ch-a', '');
      await svc.cancelInflightTurnForAgent('ch-nonexistent', 'agent-1');
      await svc.cancelInflightTurnForAgent('ch-a', 'agent-9');

      expect(sentFrames, isEmpty);
      expect(svc.hasInflightForChannel('ch-a'), isTrue);
    });
  });

  group('P4: 主机发起的流程回合没有本地 _pending', () {
    const channelId = 'psess_flow_deadbe12_impl';
    const sessionKey = 'agent:agent-7:flow_deadbe12_impl';
    const turnId = 'flow-deadbe12-impl-a1';
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];
    late SessionRuntimeMirror mirror;

    void seedSnapshot({
      required String requestId,
      required bool running,
      String key = sessionKey,
      String peerId = 'peer-1',
    }) {
      mirror.apply({
        'session_key': key,
        'state': running ? 'running' : 'idle',
        'turn_id': requestId,
        if (peerId.isNotEmpty) 'peer_id': peerId,
        'revision': 1,
        'at': 1,
        'hub_id': 'hub-1',
      }, force: true);
    }

    setUp(() async {
      sentFrames.clear();
      mirror = SessionRuntimeMirror();
      if (getIt.isRegistered<SessionRuntimeMirror>()) {
        await getIt.unregister<SessionRuntimeMirror>();
      }
      getIt.registerSingleton<SessionRuntimeMirror>(mirror);
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      svc.debugSendControlOverride = null;
      if (getIt.isRegistered<SessionRuntimeMirror>()) {
        await getIt.unregister<SessionRuntimeMirror>();
      }
    });

    test('按 session.state 的 turn_id 发 agent_cancel', () async {
      seedSnapshot(requestId: turnId, running: true);
      expect(svc.hasInflightForChannel(channelId), isFalse);

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: sessionKey,
      );

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.peerId, 'peer-1');
      expect(sentFrames.single.json, {
        'type': 'agent_cancel',
        'request_id': turnId,
      });
    });

    test('不知道精确 sessionKey 时按 channel id 后缀兜底', () async {
      seedSnapshot(requestId: turnId, running: true);

      await svc.cancelInflightTurnsForChannel(channelId);

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.json['request_id'], turnId);
    });

    test('快照已 idle 时用 ChatController 缓存的 turn id 兜底', () async {
      seedSnapshot(requestId: turnId, running: false);

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: sessionKey,
        runtimeTurnId: turnId,
      );

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.json['request_id'], turnId);
    });

    test('普通 DM 不额外发 cancel（非 flow- 前缀且已在 _pending 里）', () async {
      seedSnapshot(requestId: 'req-dm-1', running: true);
      final future = svc.debugSeedPendingTurn(
        requestId: 'req-dm-1',
        peerId: 'peer-1',
        channelId: channelId,
      );

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: sessionKey,
        runtimeTurnId: 'req-dm-1',
      );

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.json['request_id'], 'req-dm-1');
      expect((await future).content, '[Stopped]');
    });

    test('idle 且无缓存 turn id 时为空操作', () async {
      seedSnapshot(requestId: turnId, running: false);

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: sessionKey,
      );

      expect(sentFrames, isEmpty);
    });

    test('A5-5 快照缺 peer_id 时按 session key 的 agent 归属发往正确主机', () async {
      await LocalDatabaseService().createRemoteAgent(RemoteAgent(
        id: 'peeragent_p2_remote-a',
        name: 'Agent A',
        token: 'tok',
        endpoint: 'peer://p2/peeragent_p2_remote-a',
        protocol: ProtocolType.peer,
        connectionType: ConnectionType.websocket,
        metadata: {
          'source_peer_id': 'p2',
          'remote_agent_id': 'agent-7',
        },
        createdAt: 1,
        updatedAt: 1,
      ));
      // 两台主机都连着时，第一条 state 没有 peer_id。
      seedSnapshot(requestId: turnId, running: true, peerId: '');

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: sessionKey,
      );

      expect(sentFrames, hasLength(1));
      expect(sentFrames.single.peerId, 'p2',
          reason: '应按 session key 里的 agent 归属解析主机，不能随便挑第一个');
      expect(sentFrames.single.json['request_id'], turnId);
    });

    test('A5-5 归属解析不到时不乱发 agent_cancel', () async {
      const unknownKey = 'agent:unknown-agent:flow_deadbe12_impl';
      seedSnapshot(
        requestId: turnId,
        running: true,
        key: unknownKey,
        peerId: '',
      );

      await svc.cancelInflightTurnsForChannel(
        channelId,
        sessionKey: unknownKey,
      );

      expect(sentFrames, isEmpty, reason: '解析不到归属主机时宁可不发，也不能把停止发给另一台主机');
    });
  });
}
