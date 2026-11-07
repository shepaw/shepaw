import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// H9-4 / H9-9：主机接不住 deferred 节点卡的回答时，不再静默写消息，而是
/// 回 `agent_error`（code = orphan_card / answer_pending）并**保留卡片**。
/// App 不能把这条帧当未知帧吞掉，也不能让本机继续显示「已提交」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = PeerAgentClientService.instance;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('H9-4: orphan_card 错误上抛、卡片退回可答、不假装回合失败', () async {
    const requestId = 'flow-h94-run-a1';
    const approvalId = 'approval-h94-node';
    const channelId = 'ch-h94';
    final errors = <({String requestId, String code, String message})>[];
    final deferred = <({String approvalId, String requestId, bool reopened})>[];
    final errorSub = svc.deferredCardErrors.listen(errors.add);
    final deferredSub = svc.formDeferredEvents.listen(deferred.add);
    addTearDown(() async {
      await errorSub.cancel();
      await deferredSub.cancel();
      await svc.cancelInflightTurnsForChannel(channelId);
    });

    svc.debugSeedSubmittedFormAnswer(
      approvalId: approvalId,
      requestId: requestId,
    );
    expect(svc.debugIsFormSubmitted(approvalId), isTrue);
    final inFlight = svc.debugSeedPendingTurn(
      requestId: requestId,
      peerId: 'peer-h94',
      channelId: channelId,
    );
    var completed = false;
    unawaited(inFlight.then(
      (_) => completed = true,
      onError: (_) => completed = true,
    ));

    svc.debugInjectControlForTest(
      'agent_error',
      {
        'request_id': requestId,
        'code': 'orphan_card',
        'error': '找不到这张卡片对应的工作流节点，回答没有保存；卡片保留，请稍后重试',
      },
      peerId: 'peer-h94',
    );
    await settle();

    expect(errors, hasLength(1), reason: '错误帧不能被当成未知帧吞掉');
    expect(errors.single.code, 'orphan_card');
    expect(errors.single.requestId, requestId);
    expect(errors.single.message, contains('卡片保留'));
    expect(deferred, hasLength(1));
    expect(deferred.single.approvalId, approvalId);
    expect(deferred.single.reopened, isTrue);
    expect(svc.debugIsFormSubmitted(approvalId), isFalse,
        reason: '主机没接住答案，不能继续显示「已提交」');
    expect(completed, isFalse, reason: '卡片错误不是 turn 终态，不能把在途回合判成失败完成');
    expect(svc.hasInflightForChannel(channelId), isTrue);
  });

  test('H9-9: answer_pending 错误也上抛且不关卡', () async {
    const requestId = 'flow-h99-run-a1';
    const channelId = 'ch-h99';
    final errors = <({String requestId, String code, String message})>[];
    final errorSub = svc.deferredCardErrors.listen(errors.add);
    addTearDown(() async {
      await errorSub.cancel();
      await svc.cancelInflightTurnsForChannel(channelId);
    });
    final inFlight = svc.debugSeedPendingTurn(
      requestId: requestId,
      peerId: 'peer-h99',
      channelId: channelId,
    );
    var completed = false;
    unawaited(inFlight.then(
      (_) => completed = true,
      onError: (_) => completed = true,
    ));

    svc.debugInjectControlForTest(
      'agent_error',
      {
        'request_id': requestId,
        'code': 'answer_pending',
        'error': '工作流驱动已结束，回答已暂存；卡片保留，请稍后重试',
      },
      peerId: 'peer-h99',
    );
    await settle();

    expect(errors, hasLength(1));
    expect(errors.single.code, 'answer_pending');
    expect(errors.single.message, contains('请稍后重试'));
    expect(completed, isFalse);
    expect(svc.hasInflightForChannel(channelId), isTrue);
  });
}
