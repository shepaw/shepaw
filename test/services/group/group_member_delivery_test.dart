import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_member_delivery.dart';
import 'package:shepaw/services/group/group_member_stall.dart';
import 'package:shepaw/services/group/group_member_task_context.dart';

RemoteAgent _agent({
  required String id,
  required String name,
  ProtocolType protocol = ProtocolType.acp,
  Map<String, dynamic> metadata = const {},
}) =>
    RemoteAgent(
      id: id,
      name: name,
      token: 't',
      endpoint: 'e',
      protocol: protocol,
      connectionType: ConnectionType.websocket,
      metadata: metadata,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('GroupMemberDelivery', () {
    test('buildDeliveryNote mentions peer cross-device limits', () {
      final agent = _agent(
        id: 'peer1',
        name: 'peer-cursor',
        protocol: ProtocolType.peer,
        metadata: {'manageable': true},
      );
      final note = GroupMemberDelivery.buildDeliveryNote(agent);
      expect(note, contains('【宿主约束'));
      expect(note, contains('跨设备'));
    });

    test('classifyFailure distinguishes stall vs connection', () {
      expect(
        GroupMemberDelivery.classifyFailure(
          MemberStalledException(agentName: 'A'),
        ),
        contains('超时未响应'),
      );
      expect(
        GroupMemberDelivery.classifyFailure(
          Exception('WritableIterable is closed'),
        ),
        contains('连接中断'),
      );
    });

    test('deliveryContextFor encodes peer delivery mode', () {
      final agent = _agent(
        id: 'peer1',
        name: 'peer-cursor',
        protocol: ProtocolType.peer,
        metadata: {'manageable': true},
      );
      final ctx = GroupMemberDelivery.deliveryContextFor(agent);
      expect(ctx['mode'], 'hub_peer');
      expect(ctx['prefer_workspace_mount'], isTrue);
    });

    test('buildMemberDispatchContent adds recon footer for recon steps', () {
      final agent = _agent(
        id: 'local',
        name: 'local1',
        metadata: {'llm_provider': 'test'},
      );
      final content = GroupMemberDelivery.buildMemberDispatchContent(
        agent: agent,
        memberBrief: '摸底 channel 段',
        taskContext: const GroupMemberTaskContext(
          globalRequirement: '排查链路',
        ),
        memoryNote: '',
        steps: const [
          DispatchStep(
            step: 1,
            agentIds: ['local'],
            task: '摸底',
            mode: 'concurrent',
            isRecon: true,
          ),
        ],
        agents: [agent],
        peerResultsNote: '',
        loopEventNote: '',
        currentRound: 1,
      );
      expect(content, contains('摸底时间盒'));
      expect(content, contains('【宿主约束'));
    });
  });
}
