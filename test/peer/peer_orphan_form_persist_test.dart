import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 卡片到达时没有回合能接（上一轮已被主机收口、或这台设备不是发起方）会走
/// 「孤儿卡」那条路。它和活动回合的卡一样等着人答，但此前只有活动回合那条路
/// 落库，孤儿卡只活在内存里——App 一重启，用户就再也答不上那一轮。
///
/// 10-31 那张 20:13 的 ask_user 卡就是这么丢的：主机还在等，本机两个库里
/// 都查不到它。
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
    final channelId = 'dm_orphan_$stamp';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Orphan',
        type: 'dm',
        memberIds: const ['user', 'agent'],
        isPrivate: true,
      ),
      'user',
    );
    addTearDown(() => svc.cancelInflightTurnsForChannel(channelId));
    return channelId;
  }

  test('没有回合能接的卡片也要落库', () async {
    final channelId = await newChannel();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestId = 'req-orphan-$stamp';
    final approvalId = 'appr-orphan-$stamp';

    // 没有 debugSeedPendingTurn：`_pending` 里没有这一轮，走孤儿卡分支。
    svc.debugInjectControlForTest(
      'agent_form_req',
      {
        'request_id': requestId,
        'approval_id': approvalId,
        'agent_id': 'remote-agent',
        'channel_id': channelId,
        'title': '用哪个端口',
        'fields': [
          {'id': 'port', 'type': 'string', 'label': '端口'},
        ],
      },
      peerId: 'peer-1',
    );

    final cardId = PeerApprovalPayload.formCardMessageId(approvalId);
    await until(() async => await db.getMessageById(cardId) != null);

    final row = (await db.getMessageById(cardId))!;
    expect(row['channel_id'], channelId);
    final form = metadataOf(row)['form'] as Map;
    expect(form['form_id'], approvalId);
    expect(form['request_id'], requestId);
    expect(form['peer_form'], {'peer_id': 'peer-1', 'approval_id': approvalId});

    // 落了库就够：聊天页从这条确定性行渲染，`submitForm` 也认它
    // （`_isPersistedOpenForm`）。「重启后答得出去」由
    // `peer_form_persist_test.dart` 那条用例钉着，这里不重复。
  });
}
