import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 作废不能只活在当前聊天页的内存里。页面不在、或者进程重启后账簿是空的，
/// 卡片还在 SQLite 里，下次打开必须已经是不可点的。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
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
    final decoded = jsonDecode(raw as String);
    return Map<String, dynamic>.from(decoded as Map);
  }

  test('作废帧直接落库，不依赖聊天页还开着', () async {
    final db = LocalDatabaseService();
    final svc = PeerAgentClientService.instance;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_close_$stamp';
    final messageId = 'msg-close-$stamp';
    final approvalId = 'form-close-$stamp';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Close',
        type: 'dm',
        memberIds: const ['user', 'agent'],
        isPrivate: true,
      ),
      'user',
    );
    await db.createMessage(
      id: messageId,
      channelId: channelId,
      senderId: 'agent',
      senderType: 'agent',
      senderName: 'Agent',
      content: '',
      metadata: {
        'form': {
          'form_id': approvalId,
          'title': '选哪个端口',
        },
      },
    );

    svc.debugInjectControlForTest(
      'agent_interaction_closed',
      {'approval_id': approvalId, 'reason': 'timeout'},
    );

    await until(() async {
      final row = await db.getMessageById(messageId);
      if (row == null) return false;
      final form = metadataOf(row)['form'];
      return form is Map && form['closed'] == 'timeout';
    });

    final form = metadataOf((await db.getMessageById(messageId))!)['form'] as Map;
    expect(form['submitted_values'], isNull);
  });

  test('进程重启后回合结束，仍收起流式消息上的卡片', () async {
    final db = LocalDatabaseService();
    final svc = PeerAgentClientService.instance;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final channelId = 'dm_turn_$stamp';
    final messageId = 'msg-turn-$stamp';
    final requestId = 'req-turn-$stamp';
    await db.createChannel(
      Channel.withMemberIds(
        id: channelId,
        name: 'Turn',
        type: 'dm',
        memberIds: const ['user', 'agent'],
        isPrivate: true,
      ),
      'user',
    );
    await db.createMessage(
      id: messageId,
      channelId: channelId,
      senderId: 'agent',
      senderType: 'agent',
      senderName: 'Agent',
      content: '',
      metadata: {
        'form': {
          'form_id': 'form-$stamp',
          'request_id': requestId,
          'title': '选哪个端口',
        },
      },
    );

    // 内存账簿是空的（重启后的样子），只剩进行中的回合和它的流式消息。
    final done = svc.debugSeedPendingTurn(
      requestId: requestId,
      peerId: 'peer-1',
      channelId: channelId,
    );
    svc.noteInflightPartialMessageId(requestId, messageId);
    svc.debugInjectControlForTest('agent_done', {
      'request_id': requestId,
      'content': '按默认继续了',
    });
    await done;

    await until(() async {
      final row = await db.getMessageById(messageId);
      if (row == null) return false;
      final form = metadataOf(row)['form'];
      return form is Map && form['closed'] == 'turn_ended';
    });
  });
}
