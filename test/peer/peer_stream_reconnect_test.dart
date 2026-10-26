import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 主机把 agent 流改推到「设备当前连接」后，重连后的 live 分片和 resume
/// 增量会交错。分片上的 UTF-16 偏移让客户端能丢掉重复、发现缺口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PeerAgentClientService live chunk offsets', () {
    final svc = PeerAgentClientService.instance;
    final sent = <Map<String, dynamic>>[];

    Map<String, dynamic>? resumeReq(String requestId) {
      for (final frame in sent) {
        if (frame['type'] == 'agent_turn_resume_req' &&
            frame['request_id'] == requestId) {
          return frame;
        }
      }
      return null;
    }

    setUp(() {
      sent.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sent.add(json);
        return true;
      };
      svc.debugResumeResponseTimeoutOverride = const Duration(milliseconds: 40);
      svc.debugReconnectCatchUpIntervalOverride =
          const Duration(milliseconds: 20);
    });

    tearDown(() async {
      svc.debugSendControlOverride = null;
      svc.debugResumeResponseTimeoutOverride = null;
      svc.debugReconnectCatchUpIntervalOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-offset');
    });

    test('重叠的 live 分片不会重复计入已收长度', () async {
      final turn = svc.debugSeedPendingTurn(
        requestId: 'offset-1',
        peerId: 'peer-1',
        channelId: 'ch-offset',
        suspended: true,
      );
      turn.then((_) {}, onError: (_) {});

      svc.debugInjectControlForTest(
        'agent_chunk',
        {'request_id': 'offset-1', 'content': 'AB', 'offset': 0},
        peerId: 'peer-1',
      );
      // resume 已经补过这一段，live 帧又到了一次。
      svc.debugInjectControlForTest(
        'agent_chunk',
        {'request_id': 'offset-1', 'content': 'AB', 'offset': 0},
        peerId: 'peer-1',
      );
      svc.debugInjectControlForTest(
        'agent_chunk',
        {'request_id': 'offset-1', 'content': 'CD', 'offset': 2},
        peerId: 'peer-1',
      );

      await svc.debugResumeSuspendedTurns('peer-1');
      expect(resumeReq('offset-1')?['known_content_length'], 4);
    });

    test('分片跳在已收长度前面时先补缺口，不跳过拼接', () async {
      final turn = svc.debugSeedPendingTurn(
        requestId: 'offset-2',
        peerId: 'peer-1',
        channelId: 'ch-offset',
      );
      turn.then((_) {}, onError: (_) {});

      svc.debugInjectControlForTest(
        'agent_chunk',
        {'request_id': 'offset-2', 'content': 'XYZ', 'offset': 5},
        peerId: 'peer-1',
      );

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (resumeReq('offset-2') == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        resumeReq('offset-2')?['known_content_length'],
        0,
        reason: '缺口没补上之前不能假装收到了 5 个码元',
      );
    });
  });
}
