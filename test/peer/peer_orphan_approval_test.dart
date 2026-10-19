import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 单聊审批卡曾经没有会话归属：卡晚于 `agent_done` 到达时会落进任何恰好
/// 打开着的群聊。主机现在在帧里带 `channel_id`，这里锁住两点：
/// 帧的归属被保留到补投缓存，补投时按会话过滤。
void main() {
  group('PeerAgentClientService orphan approval', () {
    final svc = PeerAgentClientService.instance;

    Map<String, dynamic> approvalFrame({
      required String requestId,
      required String approvalId,
      String channelId = 'dm_remote-agent_user_1',
    }) =>
        {
          'request_id': requestId,
          'approval_id': approvalId,
          'agent_id': 'remote-agent',
          'channel_id': channelId,
          'prompt': 'run ls',
          'actions': [
            {'id': 'allow', 'label': 'Allow', 'style': 'primary'},
            {'id': 'deny', 'label': 'Deny', 'style': 'danger'},
          ],
          'tool_kind': 'execute',
          'tool_call_id': 't1',
        };

    test('孤儿卡带着会话归属，补投只给对应会话', () {
      const approvalId = 'appr-orphan-channel';
      svc.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(requestId: 'req-orphan-channel', approvalId: approvalId),
        peerId: 'peer-1',
      );

      final events = svc.pendingOrphanApprovalsFor(
        peerId: 'peer-1',
        remoteAgentId: 'remote-agent',
        hostChannelId: 'dm_remote-agent_user_1',
      );
      final event =
          events.firstWhere((e) => e['confirmation_id'] == approvalId);
      expect(event['channel_id'], 'dm_remote-agent_user_1');
      expect(event['remote_agent_id'], 'remote-agent');
      expect(event['orphan'], isTrue);
      expect(event['actions'], isNotEmpty);

      // 别的会话不能拿到这张卡。
      expect(
        svc.pendingOrphanApprovalsFor(
          peerId: 'peer-1',
          remoteAgentId: 'remote-agent',
          hostChannelId: 'dm_other_user_1',
        ),
        isEmpty,
      );
    });

    test('帧归属与 App 频道是同一口径（psess_ 剥掉）', () {
      expect(hostSessionIdForChannel('psess_abc'), 'abc');
      expect(hostSessionIdForChannel('dm_a_user_1'), 'dm_a_user_1');
    });
  });
}
