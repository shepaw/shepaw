import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/chat_service.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// 排队回合（上一轮还没完就发的下一条）开跑后以 `agent_error` 收尾。
///
/// 以前只有成功分支会卸下流式挂接：报错时 ActiveTask 留在原地，气泡一直
/// 停在「正在输出」、半成品行每几秒刷一次库，看门狗那条 future 的报错
/// 还没人接，落成 Uncaught zone error。实际触发过的是引擎回
/// `incomplete_tool_call`——正文其实已经写完了。
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
  const channelId = 'ch-queued-error';

  Future<void> until(FutureOr<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('condition not met in time');
  }

  setUp(() {
    svc.debugSendControlOverride = (peerId, json) async => true;
  });

  tearDown(() async {
    svc.debugSendControlOverride = null;
    await svc.cancelInflightTurnsForChannel(channelId);
  });

  test('开跑后报错：卸下流式任务，正文和错误都落库', () async {
    const requestId = 'queued-error-1';
    final parked = svc.enqueueChat(
      peerId: 'peer-queued-error',
      remoteAgentId: 'agent-queued-error',
      requestId: requestId,
      message: '再改一下',
      channelId: channelId,
      userMessageId: 'u-queued-error-1',
      userId: 'user',
      userName: 'me',
      agentName: 'Claude',
    );
    svc.debugInjectControlForTest(
      'agent_queued',
      {'request_id': requestId},
      peerId: 'peer-queued-error',
    );
    expect(await parked, isTrue);

    svc.debugInjectControlForTest(
      'agent_chunk',
      {'request_id': requestId, 'content': '两件都做完了。'},
      peerId: 'peer-queued-error',
    );
    await until(() => ChatService().getActiveTask(channelId) != null);

    svc.debugInjectControlForTest(
      'agent_error',
      {
        'request_id': requestId,
        'message':
            '{"code":-32603,"data":{"errorKind":"incomplete_tool_call"}}',
      },
      peerId: 'peer-queued-error',
    );

    await until(() => ChatService().getActiveTask(channelId) == null);
    expect(svc.hasInflightForChannel(channelId), isFalse);

    final reply = await db.getMessageById('peerhist_$requestId');
    expect(reply?['content'], '两件都做完了。');
    final error = await db.getMessageById('$requestId-error');
    expect('${error?['content']}', contains('incomplete_tool_call'));
  });

  test('开跑前就报错：不碰聊天页上一轮的流式任务', () async {
    const requestId = 'queued-error-2';
    final parked = svc.enqueueChat(
      peerId: 'peer-queued-error',
      remoteAgentId: 'agent-queued-error',
      requestId: requestId,
      message: '排着的',
      channelId: channelId,
    );
    svc.debugInjectControlForTest(
      'agent_queued',
      {'request_id': requestId},
      peerId: 'peer-queued-error',
    );
    expect(await parked, isTrue);

    svc.debugInjectControlForTest(
      'agent_error',
      {'request_id': requestId, 'code': 'queue_full', 'message': '排满了'},
      peerId: 'peer-queued-error',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await db.getMessageById('$requestId-error'), isNull);
  });
}
