import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 排队消息的 `agent_queued` 确认帧可能丢在断线上。主机已经受理时
/// resume 会回 streaming，不能因为 20s 没等到确认就判失败 —— 否则
/// 主机照常执行，用户看到失败重发，同一条消息会跑两遍。
void main() {
  group('PeerAgentClientService.queue ack', () {
    final svc = PeerAgentClientService.instance;
    final sent = <Map<String, dynamic>>[];

    List<Map<String, dynamic>> probes() =>
        sent.where((json) => json['type'] == 'agent_turn_resume_req').toList();

    setUp(() {
      sent.clear();
      svc.debugQueueAckTimeoutOverride = const Duration(milliseconds: 30);
      svc.debugResumeResponseTimeoutOverride =
          const Duration(milliseconds: 300);
      svc.debugSendControlOverride = (peerId, json) async {
        sent.add(json);
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {'request_id': json['request_id'], 'status': 'streaming'},
            peerId: peerId,
          );
        }
        return true;
      };
    });

    tearDown(() async {
      svc.debugQueueAckTimeoutOverride = null;
      svc.debugResumeResponseTimeoutOverride = null;
      svc.debugSendControlOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-queue-ack');
    });

    test('确认帧丢了，但 resume 证明主机收下了 → 保留排队态', () async {
      final parked = await svc.enqueueChat(
        peerId: 'peer-1',
        remoteAgentId: 'agent-1',
        requestId: 'queue-ack-1',
        message: '你好',
        channelId: 'ch-queue-ack',
      );

      expect(parked, isTrue);
      expect(probes(), hasLength(1));
      expect(probes().single['request_id'], 'queue-ack-1');
      expect(svc.hasInflightForChannel('ch-queue-ack'), isTrue);
    });
  });
}
