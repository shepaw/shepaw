import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 重连续传（suspend）命中 `lost` 时，必须和投递探活一样区分
/// 「主机没收到」和「主机跑过但记录没了」：
///
/// - 没收到（`retryable: true` / 旧主机且没收到过任何帧）→ 用同一个
///   request_id 补发一次 `agent_chat`，主机按 request_id 去重；
/// - 跑过（`retryable: false` 或 `expired`）→ 不补发，交给历史对账。
///
/// 以前的实现只在投递探活路径补发，suspend 路径直接把整个回合判死，
/// 于是网络一抖 / 一息屏就冒「对端任务已结束或丢失」。
void main() {
  group('PeerAgentClientService.suspend resume', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    List<Map<String, dynamic>> chatResends() => sentFrames
        .map((f) => f.json)
        .where((j) => j['type'] == 'agent_chat')
        .toList();

    setUp(() {
      sentFrames.clear();
      svc.debugResumeResponseTimeoutOverride = const Duration(seconds: 5);
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      svc.debugResumeResponseTimeoutOverride = null;
      svc.debugSendControlOverride = null;
      for (final channel in [
        'ch-suspend-resend-ok',
        'ch-suspend-resend-fail',
        'ch-suspend-known',
        'ch-suspend-expired',
      ]) {
        await svc.cancelInflightTurnsForChannel(channel);
      }
    });

    test('主机没收到 → 自动补发一次 agent_chat，不判死', () async {
      var resumeCalls = 0;
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          resumeCalls++;
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': 'lost',
              'retryable': true,
            },
            peerId: peerId,
          );
        } else if (json['type'] == 'agent_chat') {
          // 补发到了主机：用一条业务帧确认收下。
          svc.debugInjectControlForTest(
            'agent_metadata',
            {
              'request_id': json['request_id'],
              'metadata': <String, dynamic>{},
            },
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'suspend-resend-ok',
            peerId: 'peer-1',
            channelId: 'ch-suspend-resend-ok',
            suspended: true,
            agentChatFrame: <String, dynamic>{
              'type': 'agent_chat',
              'request_id': 'suspend-resend-ok',
              'agent_id': 'agent-1',
              'message': '你好',
            },
          )
          .then((_) {}, onError: errors.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      await _waitUntil(() => chatResends().isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(resumeCalls, 1);
      expect(chatResends(), hasLength(1));
      expect(chatResends().single['request_id'], 'suspend-resend-ok');
      expect(chatResends().single['message'], '你好');
      expect(errors, isEmpty, reason: '补发成功就不该判死');
      expect(svc.hasInflightForChannel('ch-suspend-resend-ok'), isTrue);
    });

    test('补发后仍然 lost → 判失败，且只补发一次', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': 'lost',
              'retryable': true,
            },
            peerId: peerId,
          );
        } else if (json['type'] == 'agent_chat') {
          // 补发也没到（或被主机当成重复帧挡回）。
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': 'lost',
              'retryable': true,
            },
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'suspend-resend-fail',
            peerId: 'peer-1',
            channelId: 'ch-suspend-resend-fail',
            suspended: true,
            agentChatFrame: <String, dynamic>{
              'type': 'agent_chat',
              'request_id': 'suspend-resend-fail',
              'agent_id': 'agent-1',
              'message': '你好',
            },
          )
          .then((_) {}, onError: errors.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      await _waitUntil(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('消息未能送达主机'));
      expect(
        errors.single.toString(),
        isNot(contains('对端任务已结束或丢失')),
        reason: '不要再把主机原始文案透给用户',
      );
      expect(chatResends(), hasLength(1), reason: '只自动补发一次');
      expect(svc.hasInflightForChannel('ch-suspend-resend-fail'), isFalse);
    });

    test('主机受理过但记录没了（retryable=false）→ 不补发，直接失败', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': 'lost',
              'retryable': false,
            },
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'suspend-known',
            peerId: 'peer-1',
            channelId: 'ch-suspend-known',
            suspended: true,
            agentChatFrame: <String, dynamic>{
              'type': 'agent_chat',
              'request_id': 'suspend-known',
              'agent_id': 'agent-1',
              'message': '你好',
            },
          )
          .then((_) {}, onError: errors.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      await _waitUntil(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(chatResends(), isEmpty, reason: '补发会被去重挡回，不要浪费一次往返');
      expect(svc.hasInflightForChannel('ch-suspend-known'), isFalse);
    });

    test('expired（跑过、正文已清理）→ 走对账，不补发', () async {
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        if (json['type'] == 'agent_turn_resume_req') {
          svc.debugInjectControlForTest(
            'agent_turn_resume_resp',
            {
              'request_id': json['request_id'],
              'status': 'expired',
              'turn_status': 'done',
              'retryable': false,
            },
            peerId: peerId,
          );
        }
        return true;
      };

      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'suspend-expired',
            peerId: 'peer-1',
            channelId: 'ch-suspend-expired',
            suspended: true,
            agentChatFrame: <String, dynamic>{
              'type': 'agent_chat',
              'request_id': 'suspend-expired',
              'agent_id': 'agent-1',
              'message': '你好',
            },
          )
          .then((_) {}, onError: errors.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      await _waitUntil(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('任务已结束'));
      expect(chatResends(), isEmpty);
      expect(svc.hasInflightForChannel('ch-suspend-expired'), isFalse);
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
