import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/screens/agent_source_badge.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  test('惜宝和主机上的智能体不画徽标，工作设备画设备名', () {
    expect(
      agentSourceBadge(
        agentId: SheService.sheId,
        metadata: const {
          'source_peer_id': 'host',
          'source_peer_name': 'EDENZOU-MB2',
        },
        hostPeerId: 'host',
      ),
      isNull,
    );
    expect(
      agentSourceBadge(
        agentId: 'other',
        metadata: const {
          'is_she': true,
          'source_peer_id': 'worker',
          'source_peer_name': '公司 Mac',
        },
        hostPeerId: 'host',
      ),
      isNull,
    );
    expect(
      agentSourceBadge(
        agentId: 'cli',
        metadata: const {
          'source_peer_id': 'host',
          'source_peer_name': 'EDENZOU-MB2',
        },
        hostPeerId: 'host',
      ),
      isNull,
    );
    expect(
      agentSourceBadge(
        agentId: 'codex',
        metadata: const {
          'source_peer_id': 'worker-local',
          'source_peer_name': '公司 Mac mini',
        },
        hostPeerId: 'host',
      ),
      '公司 Mac mini',
    );
    expect(
      agentSourceBadge(
        agentId: 'local',
        metadata: const {'name': 'plain'},
        hostPeerId: 'host',
      ),
      isNull,
    );
  });
}
