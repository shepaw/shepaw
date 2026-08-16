import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 流式 flush 落库的 partial 行 id 必须桥接进 inflight turn 记录并出现在
/// snapshot 里——否则进程被杀恢复后 deletePartial 找不到杀进程前那行，
/// 频道里会残留「半成品 + 完整消息」两条气泡。
void main() {
  group('PeerAgentClientService.noteInflightPartialMessageId', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    setUp(() {
      sentFrames.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() async {
      await svc.cancelInflightTurnsForChannel('ch-p');
      svc.debugSendControlOverride = null;
    });

    test('partial id 出现在 snapshotInflightTurns 记录里', () {
      svc.debugSeedPendingTurn(
        requestId: 'req-p1',
        peerId: 'peer-1',
        channelId: 'ch-p',
      );

      svc.noteInflightPartialMessageId('req-p1', 'partial-row-1');

      final snap = svc.snapshotInflightTurns();
      expect(snap.single.requestId, 'req-p1');
      expect(snap.single.partialMessageId, 'partial-row-1');
    });

    test('未知 requestId 为空操作，不抛异常', () {
      svc.noteInflightPartialMessageId('req-unknown', 'x');
      expect(svc.snapshotInflightTurns(), isEmpty);
    });

    test('重复相同 id 不再触发持久化，更新为新 id 生效', () {
      svc.debugSeedPendingTurn(
        requestId: 'req-p2',
        peerId: 'peer-1',
        channelId: 'ch-p',
      );

      svc.noteInflightPartialMessageId('req-p2', 'a');
      svc.noteInflightPartialMessageId('req-p2', 'a');
      svc.noteInflightPartialMessageId('req-p2', 'b');

      expect(svc.snapshotInflightTurns().single.partialMessageId, 'b');
    });
  });
}
