import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 主机不再等一张卡片时会发 `agent_interaction_closed`。
///
/// 卡片的等待有上限（`SHEPAW_ACP_APPROVAL_SECS`，默认 30 分钟）：到点主机不等
/// 了，按最合理的默认继续往下跑（表单会把问题交回模型，见 stdio.rs 的
/// `elicitation_outcome`；审批走保守的拒绝），同时告诉客户端这张卡作废。
///
/// app 收到就得把本地账簿一起收掉 —— 卡片留在 `_approvalToRequest` 里的话，
/// 它继续撑着 `openApprovals`：`agent_done` 被无限缓冲、聊天永远转圈，用户再
/// 点一下也只会发一条对端必然丢弃的裁决。
void main() {
  group('PeerAgentClientService interaction closed', () {
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

    Map<String, dynamic> approvalFrame({
      required String requestId,
      required String approvalId,
    }) => {
      'request_id': requestId,
      'approval_id': approvalId,
      'prompt': '允许执行 rm -rf build？',
      'actions': [
        {'id': 'allow', 'label': 'Allow'},
        {'id': 'deny', 'label': 'Deny'},
      ],
    };

    tearDown(() async {
      svc.debugSendControlOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-closed');
    });

    test('作废帧把卡片从账簿里摘掉，之后提交直接报失效', () async {
      const approvalId = 'appr-closed-form';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: 'req-closed-form', approvalId: approvalId),
        peerId: 'peer-1',
      );
      expect(svc.debugIsCardActive(approvalId), isTrue);

      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      svc.debugInjectControlForTest(
        'agent_interaction_closed',
        {'approval_id': approvalId, 'reason': 'timeout'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(svc.debugIsCardActive(approvalId), isFalse);
      expect(closed, [(approvalId: approvalId, reason: 'timeout')]);
      // 用户若还点得到这张卡，也只会撞上「已失效」——所以 UI 必须自己收起可点态。
      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        throwsA(isA<PeerApprovalExpiredException>()),
      );
    });

    test('审批卡同样处理', () async {
      const approvalId = 'appr-closed-approval';
      svc.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(requestId: 'req-closed-approval', approvalId: approvalId),
        peerId: 'peer-1',
      );
      expect(svc.debugIsCardActive(approvalId), isTrue);

      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      svc.debugInjectControlForTest(
        'agent_interaction_closed',
        {'approval_id': approvalId, 'reason': 'cancelled'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(svc.debugIsCardActive(approvalId), isFalse);
      expect(closed, [(approvalId: approvalId, reason: 'cancelled')]);
      await expectLater(
        svc.submitApproval(
          peerId: 'peer-1',
          approvalId: approvalId,
          selectedActionId: 'allow',
        ),
        throwsA(isA<PeerApprovalExpiredException>()),
      );
    });

    test('作废帧把回合的等待闸门也放开', () async {
      const requestId = 'req-gate';
      const approvalId = 'appr-gate';
      final turn = svc.debugSeedPendingTurn(
        requestId: requestId,
        peerId: 'peer-1',
        channelId: 'ch-closed',
      );
      turn.then((_) {}, onError: (_) {});
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );

      // 卡片答不出来，主机自己跑完了：done 到达时 openApprovals 还挂着，
      // 只能先缓冲（_onDone 的既有行为）。
      svc.debugInjectControlForTest(
        'agent_done',
        {'request_id': requestId, 'content': '好，我按默认继续了'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      // 作废帧落下 → 闸门归零 → 缓冲的 done 立刻放行，回合结束。
      svc.debugInjectControlForTest(
        'agent_interaction_closed',
        {'approval_id': approvalId, 'reason': 'timeout'},
        peerId: 'peer-1',
      );
      final result = await turn.timeout(const Duration(seconds: 5));
      expect(result.content, '好，我按默认继续了');
      expect(svc.debugIsCardActive(approvalId), isFalse);
    });

    test('回合结束时兜底作废还挂着的卡片（作废帧可能没送到）', () async {
      const requestId = 'req-sweep';
      const approvalId = 'appr-sweep';
      final turn = svc.debugSeedPendingTurn(
        requestId: requestId,
        peerId: 'peer-1',
        channelId: 'ch-closed',
      );
      turn.then((_) {}, onError: (_) {});
      svc.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      expect(svc.debugIsCardActive(approvalId), isTrue);

      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      // 手机当时不在线，作废帧丢了；续传探到回合已结束 —— 同一件事的第二个
      // 信号，用它补一次，别让屏幕上留一张点不动的卡。
      svc.debugInjectControlForTest(
        'agent_turn_resume_resp',
        {'request_id': requestId, 'status': 'done', 'content': '已按默认继续'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(closed, [(approvalId: approvalId, reason: 'turn_ended')]);
      expect(svc.debugIsCardActive(approvalId), isFalse);
    });

    test('没带 approval_id 的作废帧既不炸也不误伤', () async {
      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      svc.debugInjectControlForTest(
        'agent_interaction_closed',
        {'reason': 'timeout'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(closed, isEmpty);
    });
  });
}
