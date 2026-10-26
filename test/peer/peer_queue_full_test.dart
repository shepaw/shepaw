import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 主机那一路会话排满时会回 `agent_error`（`code: queue_full`）。
/// 这条错误必须带着主机给的文案落到发送方，用户才知道是「排队满了、
/// 等前面的回复结束再发」，而不是消息静默丢了或含糊地失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PeerAgentClientService queue full', () {
    final svc = PeerAgentClientService.instance;

    tearDown(() async {
      svc.debugSendControlOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-queue-full');
    });

    test('主机拒收新消息时把原因交给发送方', () async {
      final future = svc.debugSeedPendingTurn(
        requestId: 'queue-full-1',
        peerId: 'peer-1',
        channelId: 'ch-queue-full',
      );

      svc.debugInjectControlForTest(
        'agent_error',
        {
          'request_id': 'queue-full-1',
          'code': 'queue_full',
          'message': '这路会话已经有 50 条消息在排队，请等前面的回复结束再发。',
          'end_reason': 'error',
        },
        peerId: 'peer-1',
      );

      await expectLater(
        future,
        throwsA(predicate(
          (error) => '$error'.contains('已经有 50 条消息在排队'),
          '排队已满的提示要原样交给用户',
        )),
      );
      expect(
        svc.hasInflightForChannel('ch-queue-full'),
        isFalse,
        reason: '被拒收的消息不能继续显示为在途',
      );
    });
  });
}
