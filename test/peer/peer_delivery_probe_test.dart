import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// `agent_chat` 发出后 2.5s 仍无任何主机帧 → 发一次 resume_req 确认投递。
///
/// WebSocket / tunnel 的 send 在半开连接上会静默成功，帧其实到不了主机。
/// 主机收到 agent_chat 时同步 claim，因此 resume 返回 `lost` 基本等价于
/// 「这一帧没到」——应快速失败让用户重试，而不是等 120s 活性超时。
void main() {
  group('PeerAgentClientService.delivery probe', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    List<Map<String, dynamic>> probes() => sentFrames
        .map((f) => f.json)
        .where((j) => j['type'] == 'agent_turn_resume_req')
        .toList();

    List<Map<String, dynamic>> chatResends() => sentFrames
        .map((f) => f.json)
        .where((j) => j['type'] == 'agent_chat')
        .toList();

    setUp(() {
      sentFrames.clear();
      svc.debugDeliveryProbeDelayOverride = const Duration(milliseconds: 30);
      svc.debugResumeResponseTimeoutOverride = const Duration(seconds: 5);
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      svc.debugDeliveryProbeDelayOverride = null;
      svc.debugResumeResponseTimeoutOverride = null;
      svc.debugSendControlOverride = null;
      // 兜底清理种子 turn，避免跨用例污染单例状态。
      await svc.cancelInflightTurnsForChannel('ch-dp-lost');
      await svc.cancelInflightTurnsForChannel('ch-dp-signal');
      await svc.cancelInflightTurnsForChannel('ch-dp-streaming');
      await svc.cancelInflightTurnsForChannel('ch-dp-resend-ok');
      await svc.cancelInflightTurnsForChannel('ch-dp-resend-fail');
    });

    test('主机不认识该 turn（lost）→ 快速失败并提示重新发送', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {'request_id': json['request_id'], 'status': 'lost'},
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'dp-lost',
            peerId: 'peer-1',
            channelId: 'ch-dp-lost',
          )
          .then((_) {}, onError: errors.add);

      svc.debugScheduleDeliveryProbe('dp-lost', peerId: 'peer-1');
      await _waitUntil(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('消息未能送达主机，请重新发送'));
      expect(probes(), hasLength(1));
      expect(probes().single['request_id'], 'dp-lost');
      expect(probes().single['known_content_length'], 0);
      expect(svc.hasInflightForChannel('ch-dp-lost'), isFalse);
    });

    test('探活前收到主机任意业务帧 → 取消探测，不重发也不误杀', () async {
      var completed = false;
      svc
          .debugSeedPendingTurn(
            requestId: 'dp-signal',
            peerId: 'peer-1',
            channelId: 'ch-dp-signal',
          )
          .then((_) => completed = true, onError: (Object _) => completed = true);

      svc.debugScheduleDeliveryProbe('dp-signal', peerId: 'peer-1');
      svc.debugInjectControlForTest(
        'agent_metadata',
        {'request_id': 'dp-signal', 'metadata': <String, dynamic>{}},
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(probes(), isEmpty);
      expect(completed, isFalse);
      expect(svc.hasInflightForChannel('ch-dp-signal'), isTrue);
    });

    test('主机答复 streaming → 确认已收到，turn 继续', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {'request_id': json['request_id'], 'status': 'streaming'},
            peerId: peerId,
          );
        }
        return true;
      };

      var completed = false;
      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'dp-streaming',
            peerId: 'peer-1',
            channelId: 'ch-dp-streaming',
          )
          .then(
            (_) => completed = true,
            onError: (Object e) {
              completed = true;
              errors.add(e);
            },
          );

      svc.debugScheduleDeliveryProbe('dp-streaming', peerId: 'peer-1');
      await _waitUntil(() => probes().isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(errors, isEmpty);
      expect(completed, isFalse);
      expect(svc.hasInflightForChannel('ch-dp-streaming'), isTrue);
    });

    test('第一次 lost → 同一个 request_id 补发一次，第二次确认成功则继续', () async {
      var probeCount = 0;
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          probeCount++;
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': probeCount == 1 ? 'lost' : 'streaming',
            },
            peerId: peerId,
          );
        }
        return true;
      };

      var completed = false;
      final errors = <Object>[];
      final frame = <String, dynamic>{
        'type': 'agent_chat',
        'request_id': 'dp-resend-ok',
        'agent_id': 'agent-1',
        'message': '你好',
      };
      svc
          .debugSeedPendingTurn(
            requestId: 'dp-resend-ok',
            peerId: 'peer-1',
            channelId: 'ch-dp-resend-ok',
            agentChatFrame: frame,
          )
          .then(
            (_) => completed = true,
            onError: (Object e) {
              completed = true;
              errors.add(e);
            },
          );

      svc.debugScheduleDeliveryProbe('dp-resend-ok', peerId: 'peer-1');
      await _waitUntil(() => probes().length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final resends = chatResends();
      expect(resends, hasLength(1));
      expect(resends.single['request_id'], 'dp-resend-ok');
      expect(resends.single['message'], '你好');
      expect(errors, isEmpty);
      expect(completed, isFalse);
      expect(svc.hasInflightForChannel('ch-dp-resend-ok'), isTrue);
    });

    test('补发后仍然 lost → 判失败，且只补发一次', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {'request_id': json['request_id'], 'status': 'lost'},
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'dp-resend-fail',
            peerId: 'peer-1',
            channelId: 'ch-dp-resend-fail',
            agentChatFrame: <String, dynamic>{
              'type': 'agent_chat',
              'request_id': 'dp-resend-fail',
              'agent_id': 'agent-1',
              'message': '你好',
            },
          )
          .then((_) {}, onError: errors.add);

      svc.debugScheduleDeliveryProbe('dp-resend-fail', peerId: 'peer-1');
      await _waitUntil(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('消息未能送达主机，请重新发送'));
      expect(chatResends(), hasLength(1), reason: '只自动补发一次');
      expect(probes().length, lessThanOrEqualTo(2));
      expect(svc.hasInflightForChannel('ch-dp-resend-fail'), isFalse);
    });
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
