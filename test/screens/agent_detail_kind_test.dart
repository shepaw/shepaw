import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/screens/agent_detail/agent_detail_kind.dart';
import 'package:shepaw/services/she_service.dart';

RemoteAgent _agent({
  String id = 'a1',
  String? remoteAgentId,
  Map<String, dynamic>? metadata,
}) =>
    RemoteAgent(
      id: id,
      name: 'Agent',
      avatar: '🤖',
      token: '',
      endpoint: 'peer://peer/remote',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      metadata: {
        'source_peer_id': 'peer',
        'remote_agent_id': remoteAgentId ?? 'remote-$id',
        ...?metadata,
      },
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('agentDetailKindOf', () {
    test('惜宝（is_she 标记）', () {
      final agent = _agent(metadata: {'is_she': true});
      expect(agentDetailKindOf(agent), AgentDetailKind.she);
    });

    test('惜宝（remote_agent_id 命中 she id）', () {
      final agent = _agent(remoteAgentId: SheService.sheId);
      expect(agentDetailKindOf(agent), AgentDetailKind.she);
    });

    test('可管理实例', () {
      final agent = _agent(metadata: {'manageable': true});
      expect(agentDetailKindOf(agent), AgentDetailKind.manageable);
    });

    test('其余 peer agent 落到只读', () {
      expect(agentDetailKindOf(_agent()), AgentDetailKind.readOnly);
    });
  });

  group('agentDetailStatusOf', () {
    test('主机没连上就是主机离线，不看实例状态', () {
      final agent = _agent(
        metadata: {'manageable': true, 'enabled': true, 'running': true},
      );
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: false),
        AgentDetailStatus.hostOffline,
      );
    });

    test('节点离线', () {
      final agent = _agent(
        metadata: {'manageable': true, 'online': false, 'running': true},
      );
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: true),
        AgentDetailStatus.nodeOffline,
      );
    });

    test('已禁用优先于已停止', () {
      final agent = _agent(
        metadata: {'manageable': true, 'enabled': false, 'running': false},
      );
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: true),
        AgentDetailStatus.disabled,
      );
    });

    test('没在运行就是已停止', () {
      final agent = _agent(
        metadata: {'manageable': true, 'running': false},
      );
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: true),
        AgentDetailStatus.stopped,
      );
    });

    test('运行中', () {
      final agent = _agent(
        metadata: {'manageable': true, 'running': true},
      );
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: true),
        AgentDetailStatus.running,
      );
    });

    test('惜宝随主机在线', () {
      final agent = _agent(metadata: {'is_she': true});
      expect(
        agentDetailStatusOf(agent: agent, hostConnected: true),
        AgentDetailStatus.online,
      );
    });
  });

  group('AgentDetailCapabilities', () {
    test('惜宝：不改头像、不改名字、无工作区、无危险操作', () {
      final caps =
          AgentDetailCapabilities.of(_agent(metadata: {'is_she': true}));
      expect(caps.canEditAvatar, isFalse);
      expect(caps.canEditName, isFalse);
      expect(caps.canEditWorkspace, isFalse);
      expect(caps.showWorkspace, isFalse);
      expect(caps.showDangerZone, isFalse);
      expect(caps.showModeAndSync, isFalse);
    });

    test('可管理实例：可改名、可改工作区、移除走主机', () {
      final caps =
          AgentDetailCapabilities.of(_agent(metadata: {'manageable': true}));
      expect(caps.canEditAvatar, isTrue);
      expect(caps.canEditName, isTrue);
      expect(caps.canEditWorkspace, isTrue);
      expect(caps.showWorkspace, isTrue);
      expect(caps.showDangerZone, isTrue);
      expect(caps.removesFromHost, isTrue);
    });

    test('只读外接：不能改名、移除改成本机隐藏', () {
      final caps = AgentDetailCapabilities.of(_agent());
      expect(caps.canEditAvatar, isTrue);
      expect(caps.canEditName, isFalse);
      expect(caps.showDangerZone, isTrue);
      expect(caps.removesFromHost, isFalse);
    });
  });
}
