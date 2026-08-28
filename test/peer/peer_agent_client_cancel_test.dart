import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 用户主动停止时，无论 controller 的 cancel token 是否已与 turn 失联
/// （页面 reattach / 进程重启 hydrate 后 token 是新建的），都必须按 channel
/// 清掉 inflight turn 并通知对端中断 —— 否则下一次发送会被
/// 「上一轮回复仍在继续」拦截，直到 300s 空闲 watchdog 超时。
void main() {
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

    test('取消后 hasInflightForChannel 立即为 false，completer 以 [Stopped] 完成', () async {
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

    test('suspended turn 取消后登记 _cancelledWhileSuspended（重连补发 cancel 而非 resume）', () async {
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
}
