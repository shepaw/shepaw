import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// AskUserQuestion 卡片不能只活在流式气泡的内存 metadata 上。
///
/// 以前聊天页一重开、控制器一重建，卡片就没了，而主机还在按 30 分钟等答案；
/// 重启后即使卡还在库里渲染出来，`submitForm` 也会因为内存账簿是空的而
/// 判成「不认识这张卡」。这里钉住三条：卡片落库、重复投递只留一行、
/// 提交/作废状态写回同一行，以及重启后的 known-guard。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  final db = LocalDatabaseService();
  final svc = PeerAgentClientService.instance;

  tearDown(() {
    svc.debugSendControlOverride = null;
  });

  Future<void> until(FutureOr<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('等待超时');
  }

  Map<String, dynamic> metadataOf(Map<String, dynamic> row) {
    final raw = row['metadata'];
    expect(raw, isA<String>());
    return Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
  }

  Future<String> newChannel() async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_form_$stamp';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Form',
        type: 'dm',
        memberIds: const ['user', 'agent'],
        isPrivate: true,
      ),
      'user',
    );
    addTearDown(() => svc.cancelInflightTurnsForChannel(channelId));
    return channelId;
  }

  Map<String, dynamic> formFrame({
    required String requestId,
    required String approvalId,
    String title = '用哪个端口',
  }) =>
      {
        'request_id': requestId,
        'approval_id': approvalId,
        'agent_id': 'remote-agent',
        'title': title,
        'fields': [
          {'id': 'port', 'type': 'string', 'label': '端口'},
        ],
      };

  test('卡片 id 由 approval_id 决定', () {
    expect(
      PeerApprovalPayload.formCardMessageId('appr-1'),
      'peer_form_appr-1',
    );
  });

  test('活动回合的表单落成确定性消息行', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestId = 'req-persist-$stamp';
    final approvalId = 'appr-persist-$stamp';
    svc
        .debugSeedPendingTurn(
          requestId: requestId,
          peerId: 'peer-1',
          channelId: channelId,
          localAgentId: 'agent-1',
        )
        .then((_) {}, onError: (_) {});

    svc.debugInjectControlForTest(
      'agent_form_req',
      formFrame(requestId: requestId, approvalId: approvalId),
      peerId: 'peer-1',
    );

    final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
    await until(() async => await db.getMessageById(cardId) != null);

    final row = (await db.getMessageById(cardId))!;
    expect(row['channel_id'], channelId);
    expect(row['sender_id'], 'agent-1');
    expect(row['sender_type'], 'agent');

    final form = metadataOf(row)['form'] as Map;
    expect(form['form_id'], approvalId);
    expect(form['request_id'], requestId);
    expect(form['title'], '用哪个端口');
    // 归属单独留一份，重开页面后 dock / 提交校验才认得出这是不是本会话的卡。
    expect(metadataOf(row)['card_channel_id'], channelId);
    final peerForm = form['peer_form'] as Map;
    expect(peerForm['peer_id'], 'peer-1');
    expect(peerForm['approval_id'], approvalId);
  });

  test('重复补发同一张卡不会写出第二条消息', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestId = 'req-dup-$stamp';
    final approvalId = 'appr-dup-$stamp';
    svc
        .debugSeedPendingTurn(
          requestId: requestId,
          peerId: 'peer-1',
          channelId: channelId,
          localAgentId: 'agent-1',
        )
        .then((_) {}, onError: (_) {});
    final frame = formFrame(requestId: requestId, approvalId: approvalId);

    svc.debugInjectControlForTest('agent_form_req', frame, peerId: 'peer-1');
    final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
    await until(() async => await db.getMessageById(cardId) != null);

    // 主机重连补发 / 跨设备广播会重投同一张卡。
    svc.debugInjectControlForTest('agent_form_req', frame, peerId: 'peer-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final rows = await db.findMessagesByMetadataMatch(approvalId);
    expect(rows.map((r) => r['id']), [cardId]);
  });

  test('提交后的答案写回卡片行', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestId = 'req-submit-$stamp';
    final approvalId = 'appr-submit-$stamp';
    svc
        .debugSeedPendingTurn(
          requestId: requestId,
          peerId: 'peer-1',
          channelId: channelId,
          localAgentId: 'agent-1',
        )
        .then((_) {}, onError: (_) {});
    svc.debugInjectControlForTest(
      'agent_form_req',
      formFrame(requestId: requestId, approvalId: approvalId),
      peerId: 'peer-1',
    );
    final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
    await until(() async => await db.getMessageById(cardId) != null);

    svc.debugSendControlOverride = (_, __) async => true;
    await svc.submitForm(
      peerId: 'peer-1',
      approvalId: approvalId,
      values: const {'port': '3000'},
    );

    await until(() async {
      final row = await db.getMessageById(cardId);
      if (row == null) return false;
      final form = metadataOf(row)['form'];
      return form is Map && form['submitted_values'] != null;
    });
    final form = metadataOf((await db.getMessageById(cardId))!)['form'] as Map;
    expect(form['submitted_values'], {'port': '3000'});
  });

  test('重启后从库里渲染出的卡片仍然答得出去', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final approvalId = 'appr-restart-$stamp';
    final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
    // 进程重启后的样子：内存账簿全空，只剩 SQLite 里的卡片行。
    await db.createMessage(
      id: cardId,
      channelId: channelId,
      senderId: 'agent-1',
      senderType: 'agent',
      senderName: 'Agent',
      content: '用哪个端口',
      metadata: {
        'form': {
          'form_id': approvalId,
          'title': '用哪个端口',
          'fields': const [],
          'peer_form': {'peer_id': 'peer-1', 'approval_id': approvalId},
        },
      },
    );

    svc.debugSendControlOverride = (_, __) async => true;
    await expectLater(
      svc.submitForm(
        peerId: 'peer-1',
        approvalId: approvalId,
        values: const {'port': '3000'},
      ),
      completes,
      reason: '卡片行证明这张卡本机见过，不该被 known-guard 判成过期',
    );
  });

  test('已经作废的卡片仍然拒绝提交', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final approvalId = 'appr-closed-$stamp';
    await db.createMessage(
      id: PeerApprovalPayload.formCardMessageId(approvalId),
      channelId: channelId,
      senderId: 'agent-1',
      senderType: 'agent',
      senderName: 'Agent',
      content: '用哪个端口',
      metadata: {
        'form': {
          'form_id': approvalId,
          'title': '用哪个端口',
          'fields': const [],
          'closed': 'timeout',
          'peer_form': {'peer_id': 'peer-1', 'approval_id': approvalId},
        },
      },
    );

    await expectLater(
      svc.submitForm(
        peerId: 'peer-1',
        approvalId: approvalId,
        values: const {'port': '3000'},
      ),
      throwsA(isA<PeerApprovalExpiredException>()),
    );
  });

  test('重启后从库里渲染出的孤儿审批卡仍然答得出去', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final approvalId = 'approv-restart-$stamp';
    // 第 7 轮 `_publishOrphanCardToHub` 会给无归属孤儿审批卡落这条确定性行。
    // 内存账簿全空时点 Allow，不能因为 submitApproval 只认内存就被判过期。
    await db.createMessage(
      id: PeerApprovalPayload.approvalCardMessageId(approvalId),
      channelId: channelId,
      senderId: 'agent-1',
      senderType: 'agent',
      senderName: 'Agent',
      content: '要允许吗',
      metadata: {
        'action_confirmation': {
          'confirmation_id': approvalId,
          'confirmation_context': 'peer',
          'prompt': '要允许吗',
          'actions': const [
            {'id': 'allow', 'label': '允许'}
          ],
          'orphan': true,
        },
        'card_peer_id': 'peer-1',
      },
    );

    svc.debugSendControlOverride = (_, __) async => true;
    await expectLater(
      svc.submitApproval(
        peerId: 'peer-1',
        approvalId: approvalId,
        selectedActionId: 'allow',
        hostChannelId: hostSessionIdForChannel(channelId),
      ),
      completes,
      reason: '确定性审批行证明这张卡本机见过，不该被 known-guard 判成过期',
    );
  });

  test('已点过 / 别的会话的孤儿审批卡仍然拒绝提交', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final approvalId = 'approv-answered-$stamp';
    await db.createMessage(
      id: PeerApprovalPayload.approvalCardMessageId(approvalId),
      channelId: channelId,
      senderId: 'agent-1',
      senderType: 'agent',
      senderName: 'Agent',
      content: '要允许吗',
      metadata: {
        'action_confirmation': {
          'confirmation_id': approvalId,
          'confirmation_context': 'peer',
          'selected_action_id': 'allow',
        },
        'card_peer_id': 'peer-1',
      },
    );
    await expectLater(
      svc.submitApproval(
        peerId: 'peer-1',
        approvalId: approvalId,
        selectedActionId: 'deny',
      ),
      throwsA(isA<PeerApprovalExpiredException>()),
    );

    // 归属别的会话的行也不能借 persisted 兜底绕过会话校验。
    final foreignId = 'approv-foreign-$stamp';
    await db.createMessage(
      id: PeerApprovalPayload.approvalCardMessageId(foreignId),
      channelId: 'dm_other_session',
      senderId: 'agent-1',
      senderType: 'agent',
      senderName: 'Agent',
      content: '要允许吗',
      metadata: {
        'action_confirmation': {
          'confirmation_id': foreignId,
          'confirmation_context': 'peer',
        },
        'card_peer_id': 'peer-1',
      },
    );
    await expectLater(
      svc.submitApproval(
        peerId: 'peer-1',
        approvalId: foreignId,
        selectedActionId: 'allow',
        hostChannelId: hostSessionIdForChannel(channelId),
      ),
      throwsA(isA<PeerApprovalExpiredException>()),
    );
  });
}
