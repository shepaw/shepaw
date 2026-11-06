import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 回复中继续发消息 = 主机会话队列的核心路径。
///
/// 回归背景：`chat_controller_messaging.dart` 曾在 processMessage 开头挡下
/// 「本会话有在途回合」的第二条消息，`sendChat` 里还有一层
/// `hasInflightForSession` 抛 PeerTurnInFlightException。两层都是旧「同一
/// 会话只能有一个在途 turn」假设的残留，和主机 SessionRuntime 的排队模型
/// 冲突。这里锁住修复后的契约：
///   - 第二条 `agent_chat` 照常发出，两个 request_id 并存；
///   - `session_ack{queued}` 之后，出队的分片仍能按原 request_id 路由；
///   - 停止当前回合不得删掉排队回合的 pending。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('同一会话的排队发送', () {
    final svc = PeerAgentClientService.instance;
    const channelId = 'ch-host-queue-followup';
    const peerId = 'peer-host-queue';
    const agentId = 'remote-agent-queue';
    const sessionId = 'session-queue-followup';

    final frames = <Map<String, dynamic>>[];
    final seededIds = <String>{};

    Future<void> waitUntil(bool Function() ready) async {
      for (var i = 0; i < 200; i++) {
        if (ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('条件在 2s 内没有满足');
    }

    setUp(() {
      frames.clear();
      seededIds.clear();
      svc.debugSendControlOverride = (peer, frame) async {
        frames.add(frame);
        return true;
      };
    });

    tearDown(() async {
      svc.debugSendControlOverride = null;
      final ids = <String>{
        ...seededIds,
        for (final frame in frames)
          if (frame['type'] == 'agent_chat' &&
              frame['request_id'] is String)
            frame['request_id'] as String,
      };
      for (final id in ids) {
        svc.debugInjectControlForTest(
          'agent_done',
          {'request_id': id, 'content': ''},
          peerId: peerId,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('首轮在途时第二条 agent_chat 照常发出，且分片按原 request_id 回送',
        () async {
      final firstErrors = <Object>[];
      final first = svc.sendChat(
        peerId: peerId,
        remoteAgentId: agentId,
        message: '第一条',
        sessionId: sessionId,
        channelId: channelId,
      );
      unawaited(first.then((_) {}, onError: firstErrors.add));

      await waitUntil(() => frames.length == 1);
      expect(frames.single['type'], 'agent_chat');
      final firstId = frames.single['request_id'] as String;

      svc.debugInjectControlForTest(
        'session_ack',
        {'request_id': firstId, 'disposition': 'started'},
        peerId: peerId,
      );

      final secondChunks = <String>[];
      final secondErrors = <Object>[];
      final second = svc.sendChat(
        peerId: peerId,
        remoteAgentId: agentId,
        message: '第二条',
        sessionId: sessionId,
        channelId: channelId,
        onChunk: secondChunks.add,
      );
      unawaited(second.then((_) {}, onError: secondErrors.add));

      await waitUntil(() => frames.length == 2);
      expect(
        secondErrors,
        isEmpty,
        reason: '旧守卫抛 PeerTurnInFlightException 会把消息堵在 App 里',
      );
      final secondId = frames[1]['request_id'] as String;
      expect(secondId, isNot(firstId));

      // 主机把第二条排进队列。
      svc.debugInjectControlForTest(
        'session_ack',
        {
          'request_id': secondId,
          'disposition': 'queued',
          'position': 1,
        },
        peerId: peerId,
      );
      expect(
        svc.hasInflightForChannel(channelId),
        isTrue,
        reason: '两条 turn 都要留在 _pending，等各自的 agent_done',
      );

      // 出队后主机仍用原 request_id 推 chunk。
      svc.debugInjectControlForTest(
        'agent_chunk',
        {'request_id': secondId, 'content': '排队后开跑'},
        peerId: peerId,
      );
      expect(secondChunks.join(), contains('排队后开跑'));
      expect(firstErrors, isEmpty);
      expect(secondErrors, isEmpty);

      for (final id in <String>[firstId, secondId]) {
        svc.debugInjectControlForTest(
          'agent_done',
          {'request_id': id, 'content': ''},
          peerId: peerId,
        );
      }
      await first;
      await second;
    });

    test('停止当前回合不会把排队回合的 pending 一起删掉', () async {
      var runningDone = false;
      final running = svc.debugSeedPendingTurn(
        requestId: 'q-running',
        peerId: peerId,
        channelId: channelId,
        sessionId: sessionId,
      );
      seededIds.add('q-running');
      unawaited(running.then(
        (_) => runningDone = true,
        onError: (Object _) => runningDone = true,
      ));

      var queuedDone = false;
      final queued = svc.debugSeedPendingTurn(
        requestId: 'q-waiting',
        peerId: peerId,
        channelId: channelId,
        sessionId: sessionId,
      );
      seededIds.add('q-waiting');
      unawaited(queued.then(
        (_) => queuedDone = true,
        onError: (Object _) => queuedDone = true,
      ));

      svc.debugInjectControlForTest(
        'session_ack',
        {
          'request_id': 'q-waiting',
          'disposition': 'queued',
          'position': 1,
        },
        peerId: peerId,
      );

      await svc.cancelInflightTurnsForChannel(channelId);

      expect(runningDone, isTrue, reason: '当前回合应该被停掉');
      expect(
        queuedDone,
        isFalse,
        reason: '主机随后仍会按 q-waiting 推 chunk，删了 pending 就会丢回复',
      );
      expect(svc.hasInflightForChannel(channelId), isTrue);

      svc.debugInjectControlForTest(
        'agent_done',
        {'request_id': 'q-waiting', 'content': ''},
        peerId: peerId,
      );
      await queued;
    });
  });
}
