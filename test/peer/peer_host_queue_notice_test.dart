import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_turn_resume.dart';

/// 正文停了、工具还在跑时，回合不能算「回复已结束」——主机侧的
/// `turn_followup_can_start` 同样要求 `answer_settled`（正文后没有工具）。
/// App 之前只看正文与静默时长，会把还在跑工具的回合提前收掉，下一条
/// 直接发出去才被主机排队，界面上既没有排队、也看不到上一轮还在输出。
void main() {
  group('PeerAgentClientService tool status settle gate', () {
    final svc = PeerAgentClientService.instance;
    const channelId = 'ch-tool-settle';

    tearDown(() async {
      await svc.cancelInflightTurnsForChannel(channelId);
    });

    test('工具在跑时不算结束，工具收尾后才放行', () async {
      final future = svc.debugSeedPendingTurn(
        requestId: 'tool-settle-1',
        peerId: 'peer-tool-settle',
        channelId: channelId,
      );
      svc.noteInflightAnswer('tool-settle-1', '先看一下构建结果');

      svc.debugInjectControlForTest('agent_metadata', {
        'request_id': 'tool-settle-1',
        'metadata': {'tool_status': 'in_progress'},
      });

      await Future<void>.delayed(
        kFollowUpSettle + const Duration(milliseconds: 300),
      );

      // 正文已有、静默已超过 1s，但工具仍在跑 —— 不能放行，也不能本地收尾。
      expect(svc.followUpBlockedByChannel(channelId), isTrue);
      svc.completeSettledTurns(channelId, fallbackAnswer: '先看一下构建结果');
      expect(svc.hasInflightForChannel(channelId), isTrue);

      // 工具收尾（completed）后才允许跟进。
      svc.debugInjectControlForTest('agent_metadata', {
        'request_id': 'tool-settle-1',
        'metadata': {'tool_status': 'completed'},
      });
      await Future<void>.delayed(
        kFollowUpSettle + const Duration(milliseconds: 300),
      );

      expect(svc.followUpBlockedByChannel(channelId), isFalse);
      svc.completeSettledTurns(channelId, fallbackAnswer: '先看一下构建结果');
      expect(svc.hasInflightForChannel(channelId), isFalse);

      final result = await future;
      expect(result.content, '先看一下构建结果');
    });
  });

  group('PeerAgentClientService host queue events', () {
    final svc = PeerAgentClientService.instance;
    const channelId = 'ch-host-queue';

    tearDown(() async {
      await svc.cancelInflightTurnsForChannel(channelId);
    });

    test('直接发出的回合被主机排队 / 开跑时发出事件', () async {
      final events = <({String channelId, String requestId, bool queued})>[];
      final sub = svc.hostQueueEvents.listen(events.add);
      addTearDown(sub.cancel);

      final future = svc.debugSeedPendingTurn(
        requestId: 'host-queue-1',
        peerId: 'peer-host-queue',
        channelId: channelId,
      );

      svc.debugInjectControlForTest(
        'agent_queued',
        {'request_id': 'host-queue-1'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(svc.hostQueuedDirectTurnCount(channelId), 1);
      expect(events.last.queued, isTrue);
      expect(events.last.requestId, 'host-queue-1');

      // 排队回合结束（或开跑后收尾）：提示必须收起。
      svc.debugInjectControlForTest(
        'agent_done',
        {'request_id': 'host-queue-1', 'content': '跑完了'},
      );
      await future;
      await Future<void>.delayed(Duration.zero);

      expect(svc.hostQueuedDirectTurnCount(channelId), 0);
      expect(events.last.queued, isFalse);
    });
  });
}
