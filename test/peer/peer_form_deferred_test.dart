import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection.dart';

/// 回合内没等到回答时，主机把卡片改投 `agent_form_deferred`：
/// 这一轮收束，卡片留着等用户以后点。作答时由 App 另开一轮，
/// 拒绝则只关卡、不开回合。
void main() {
  group('PeerAgentClientService deferred form', () {
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

    Map<String, dynamic> deferredFrame({
      required String requestId,
      required String approvalId,
    }) => {
      ...formFrame(requestId: requestId, approvalId: approvalId),
      'deferred': true,
    };

    tearDown(() async {
      svc.debugSendControlOverride = null;
      await svc.cancelInflightTurnsForChannel('ch-deferred');
    });

    test('deferred 帧直接结束本轮，不必等迟到的 agent_done', () async {
      const requestId = 'req-deferred-end';
      const approvalId = 'appr-deferred-end';
      final turn = svc.debugSeedPendingTurn(
        requestId: requestId,
        peerId: 'peer-1',
        channelId: 'ch-deferred',
      );
      turn.then((_) {}, onError: (_) {});

      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );

      // 主机还在等引擎吃完 session/cancel，真正的 agent_done 会晚几秒才到；
      // 独立卡片一出现就该收掉本轮。
      final result = await turn.timeout(const Duration(seconds: 2));
      expect(result.metadata?['deferred'], isTrue);
    });

    test('deferred 帧放掉等待闸门，空收束的 done 不再被缓冲', () async {
      const requestId = 'req-deferred-gate';
      const approvalId = 'appr-deferred-gate';
      final turn = svc.debugSeedPendingTurn(
        requestId: requestId,
        peerId: 'peer-1',
        channelId: 'ch-deferred',
      );
      turn.then((_) {}, onError: (_) {});

      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      expect(svc.debugIsCardActive(approvalId), isTrue);

      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      // 卡片本身还留着（可能在孤儿表里），只是不再占旧回合的审批额度。
      svc.debugInjectControlForTest(
        'agent_done',
        {'request_id': requestId, 'content': '', 'deferred': true},
        peerId: 'peer-1',
      );

      final result = await turn.timeout(const Duration(seconds: 5));
      expect(result.content, isEmpty);
      expect(result.metadata?['deferred'], isTrue);
    });

    test('deferred 事件广播出来，之后作答返回「要另开回合」', () async {
      const requestId = 'req-deferred-submit';
      const approvalId = 'appr-deferred-submit';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );

      final events =
          <({String approvalId, String requestId, bool reopened})>[];
      final sub = svc.formDeferredEvents.listen(events.add);
      addTearDown(sub.cancel);

      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();
      expect(events, [
        (approvalId: approvalId, requestId: requestId, reopened: false),
      ]);

      final sent = <Map<String, dynamic>>[];
      svc.debugSendControlOverride = (peerId, json) async {
        sent.add(json);
        return true;
      };

      final wasDeferred = await svc.submitForm(
        peerId: 'peer-1',
        approvalId: approvalId,
        values: const {'port': '3000'},
      );

      expect(wasDeferred, isTrue);
      expect(sent, hasLength(1));
      expect(sent.single['type'], 'agent_form_resp');
      expect(sent.single['approval_id'], approvalId);
      expect(sent.single['action'], 'accept');
      expect(sent.single['content'], {'port': '3000'});
    });

    test('拒绝只发一条 decline，不开新回合', () async {
      const requestId = 'req-deferred-decline';
      const approvalId = 'appr-deferred-decline';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );

      final sent = <Map<String, dynamic>>[];
      svc.debugSendControlOverride = (peerId, json) async {
        sent.add(json);
        return true;
      };

      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      await svc.declineForm(peerId: 'peer-1', approvalId: approvalId);
      await pumpEventQueue();

      expect(sent, hasLength(1));
      expect(sent.single['type'], 'agent_form_resp');
      expect(sent.single['action'], 'decline');
      expect(sent.single.containsKey('content'), isFalse);
      expect(closed, [(approvalId: approvalId, reason: 'declined')]);

      // 关卡之后不能再提交。
      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        throwsA(isA<PeerApprovalExpiredException>()),
      );
    });

    test('已提交后迟到的 deferred 帧不会把卡片放回可答状态', () async {
      const requestId = 'req-deferred-late';
      const approvalId = 'appr-deferred-late';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      svc.debugSendControlOverride = (peerId, json) async => true;
      expect(
        await svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        isTrue,
      );

      // 补发帧晚到：不能把卡重新记成待答。
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      await expectLater(
        svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        throwsA(isA<PeerApprovalExpiredException>()),
      );
    });

    test('回合内提交的答案没送到主机：deferred 帧把卡退回可答，再答另开回合',
        () async {
      const requestId = 'req-deferred-lost';
      const approvalId = 'appr-deferred-lost';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      // 半开连接：本地「发送成功」，主机其实没收到。
      svc.debugSendControlOverride = (peerId, json) async => true;
      expect(
        await svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        isFalse,
      );

      final events =
          <({String approvalId, String requestId, bool reopened})>[];
      final sub = svc.formDeferredEvents.listen(events.add);
      addTearDown(sub.cancel);

      // 主机等到超时转 deferred，说明它没收到那次回答。
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();
      expect(events, [
        (approvalId: approvalId, requestId: requestId, reopened: true),
      ]);
      // 本机认得这张卡：不能当成没见过的卡再按孤儿表单投一遍。
      expect(
        svc
            .pendingOrphanFormsFor(
              peerId: 'peer-1',
              remoteAgentId: 'remote-agent',
            )
            .where((e) => e['form_id'] == approvalId),
        isEmpty,
      );

      // 再答一次：主机已不在旧回合等，调用方要另开一轮。
      final sent = <Map<String, dynamic>>[];
      svc.debugSendControlOverride = (peerId, json) async {
        sent.add(json);
        return true;
      };
      expect(
        await svc.submitForm(
          peerId: 'peer-1',
          approvalId: approvalId,
          values: const {'port': '3000'},
        ),
        isTrue,
      );
      expect(sent.single['type'], 'agent_form_resp');

      // 之后再补发的 deferred 帧不能再把卡放回可答。
      events.clear();
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();
      expect(events, isEmpty);
    });

    test('本地没有这张卡时，补发的 deferred 卡按孤儿表单投出去', () async {
      const requestId = 'req-deferred-replay';
      const approvalId = 'appr-deferred-replay';
      final events = <Map<String, dynamic>>[];
      final sub = svc.orphanFormEvents.listen(events.add);
      addTearDown(sub.cancel);

      // 重连 / 另一台设备第一次看到这张卡：之前没有 agent_form_req。
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      final mine = events.where((e) => e['form_id'] == approvalId).toList();
      expect(mine, hasLength(1));
      expect(mine.single['request_id'], requestId);
      expect(mine.single['deferred'], isTrue);
      expect(
        svc
            .pendingOrphanFormsFor(
              peerId: 'peer-1',
              remoteAgentId: 'remote-agent',
            )
            .where((e) => e['form_id'] == approvalId),
        hasLength(1),
      );

      // 清掉留底，别影响其他用例。
      svc.debugInjectControlForTest(
        'agent_interaction_closed',
        {'approval_id': approvalId, 'reason': 'declined'},
        peerId: 'peer-1',
      );
      await pumpEventQueue();
    });

    test('旧回合收尾不会把 deferred 卡广播成作废', () async {
      const requestId = 'req-deferred-sweep';
      const approvalId = 'appr-deferred-sweep';
      svc.debugInjectControlForTest(
        'agent_form_req',
        formFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );
      svc.debugInjectControlForTest(
        'agent_form_deferred',
        deferredFrame(requestId: requestId, approvalId: approvalId),
        peerId: 'peer-1',
      );

      final closed = <({String approvalId, String reason})>[];
      final sub = svc.interactionClosedEvents.listen(closed.add);
      addTearDown(sub.cancel);

      // 续传探到旧回合已结束，走「回合结束兜底收卡」这条路。
      svc.debugInjectControlForTest(
        'agent_turn_resume_resp',
        {'request_id': requestId, 'status': 'done', 'content': ''},
        peerId: 'peer-1',
      );
      await pumpEventQueue();

      expect(closed, isEmpty);
    });

    test('PeerConnection 控制帧白名单包含 agent_form_deferred', () {
      expect(PeerConnection.isControlFrameType('agent_form_deferred'), isTrue);
    });
  });
}
