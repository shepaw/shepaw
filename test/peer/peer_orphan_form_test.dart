import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 手机掉线时发出的 AskUserQuestion 卡片，曾经被彻底丢掉。
///
/// 背景：`agent_form_req` 只在 ACP `elicitation/create` 那一下发一次；手机不在线
/// 就进了黑洞，而主机还在按 `approval_wait()`（默认 24h）等回答。表现就是
/// 「会话卡了几个小时、app 里没有任何审核组件」。
///
/// hub 现在会在重连后补发卡片，但本地未必有地方能投递：`_pending` 可能已被
/// resume 重试耗尽清掉，或者 turn 刚从磁盘恢复、UI 还没重新挂上 `onForm`。
/// 这两种情况都必须把卡片存下来交给打开的聊天页，而不是 warning 一句就 return。
void main() {
  group('PeerAgentClientService orphan form', () {
    final svc = PeerAgentClientService.instance;

    Map<String, dynamic> formFrame({
      required String requestId,
      required String approvalId,
    }) => {
      'request_id': requestId,
      'approval_id': approvalId,
      'agent_id': 'remote-agent',
      'title': '选哪个端口',
      'fields': [
        {'id': 'port', 'type': 'string', 'label': '端口'},
      ],
    };

    tearDown(() async {
      svc.debugSendControlOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-orphan-form');
    });

    test('没有活动 turn 时表单不再被丢弃，而是存成待渲染的孤儿卡', () {
      const approvalId = 'appr-no-pending';
      expect(svc.debugIsOrphanFormBuffered(approvalId), isFalse);

      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: 'req-no-pending', approvalId: approvalId),
        peerId: 'peer-1',
      );

      expect(
        svc.debugIsOrphanFormBuffered(approvalId),
        isTrue,
        reason: '没有 _pending 时曾经直接 return，卡片就此消失',
      );
    });

    test('孤儿卡仍然答得出去 —— 不再被判成过期卡', () async {
      const approvalId = 'appr-submittable';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: 'req-submittable', approvalId: approvalId),
        peerId: 'peer-1',
      );

      // 没有真连接，发送必然失败；关键是它已经越过了「这张卡不认识」的守卫。
      // 改之前 _orphanedForms 里没有这条记录，这里抛的是
      // PeerApprovalExpiredException —— 用户点了等于没点。
      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        throwsA(
          isNot(isA<PeerApprovalExpiredException>()),
        ),
      );
    });

    test('完全不认识的表单仍然拒绝提交（守卫没有被放宽）', () async {
      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: 'appr-never-seen',
          values: const {'port': '3000'},
        ),
        throwsA(isA<PeerApprovalExpiredException>()),
      );
    });

    test('turn 还在但 onForm 没挂上（磁盘恢复）时同样存下来', () async {
      const approvalId = 'appr-hydrated';
      svc
          .debugSeedPendingTurn(
            requestId: 'req-hydrated',
            peerId: 'peer-1',
            channelId: 'ch-orphan-form',
          )
          .then((_) {}, onError: (_) {});

      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: 'req-hydrated', approvalId: approvalId),
        peerId: 'peer-1',
      );

      expect(
        svc.debugIsOrphanFormBuffered(approvalId),
        isTrue,
        reason: 'hydrate 出来的 turn 没有 UI 回调，光靠 onForm?.call 会静默丢失',
      );
    });

    test('repeat 补发同一张卡不重复入账', () {
      const approvalId = 'appr-duplicate';
      final frame = formFrame(
        requestId: 'req-duplicate',
        approvalId: approvalId,
      );

      svc.debugInjectControlForTest(
        'agent_form_req',
        frame,
        peerId: 'peer-1',
      );
      // 第二次补发时 _orphanedForms 已有该 id，走幂等分支直接返回。
      svc.debugInjectControlForTest(
        'agent_form_req',
        frame,
        peerId: 'peer-1',
      );

      expect(svc.debugIsOrphanFormBuffered(approvalId), isTrue);
    });

    test('resume 应答带回的 pending_interaction 走同一条分发', () async {
      const approvalId = 'appr-resume';
      const requestId = 'req-resume';
      svc
          .debugSeedPendingTurn(
            requestId: requestId,
            peerId: 'peer-1',
            channelId: 'ch-orphan-form',
          )
          .then((_) {}, onError: (_) {});

      // hub 在 agent_turn_resume_resp 里把还悬空的卡片一并交回来。
      svc.debugInjectControlForTest(
        'agent_turn_resume_resp',
        {
          'request_id': requestId,
          'status': 'streaming',
          'delta': '',
          'pending_interaction': {
            'type': 'agent_form_req',
            ...formFrame(requestId: requestId, approvalId: approvalId),
          },
        },
        peerId: 'peer-1',
      );

      expect(svc.debugIsOrphanFormBuffered(approvalId), isTrue);
    });
  });
}
