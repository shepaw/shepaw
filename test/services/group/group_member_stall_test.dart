import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/group/group_event.dart';
import 'package:shepaw/services/group/group_member_stall.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_result_writer.dart';
import 'package:shepaw/services/group/group_task_status.dart';
import 'package:shepaw/services/group/group_turn_result.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      token: 't',
      endpoint: 'e',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  tearDown(() {
    GroupOrchestrationFeatures.stalledTimeout = true;
    GroupOrchestrationFeatures.maxStallsBeforeFail = 2;
    GroupOrchestrationFeatures.memberStallGraceRounds = 1;
  });

  group('GroupMemberStallTracker', () {
    test('first stall marks stalled, second escalates to failed', () {
      final tracker = GroupMemberStallTracker();
      final failed = <String>[];
      final stalled = <String>[];

      expect(
        tracker.recordStall(
          agentName: 'Coder',
          failedAgentNames: failed,
          stalledAgentNames: stalled,
        ),
        isFalse,
      );
      expect(stalled, ['Coder']);
      expect(failed, isEmpty);
      expect(tracker.countFor('Coder'), 1);

      expect(
        tracker.recordStall(
          agentName: 'Coder',
          failedAgentNames: failed,
          stalledAgentNames: stalled,
        ),
        isTrue,
      );
      expect(stalled, isEmpty);
      expect(failed, ['Coder']);
      expect(tracker.countFor('Coder'), 2);
    });

    test('buildRequests maps stalled names to agent ids', () {
      final tracker = GroupMemberStallTracker();
      final failed = <String>[];
      final stalled = <String>[];
      tracker.recordStall(
        agentName: 'Coder',
        failedAgentNames: failed,
        stalledAgentNames: stalled,
      );

      final requests = GroupMemberStallTracker.buildRequests(
        stalledAgentNames: stalled,
        agents: [_agent('coder', 'Coder')],
        tracker: tracker,
        timeout: const Duration(minutes: 10),
      );

      expect(requests.single.name, 'Coder');
      expect(requests.single.agentId, 'coder');
      expect(requests.single.stallCount, 1);
    });
  });

  group('GroupMemberStallHandler', () {
    test('MemberStalledException records stall instead of immediate fail', () {
      final tracker = GroupMemberStallTracker();
      final failed = <String>[];
      final stalled = <String>[];
      var doneCalled = false;

      final turn = GroupMemberStallHandler.handleExecutionError(
        error: MemberStalledException(agentName: 'Coder'),
        agent: _agent('coder', 'Coder'),
        tracker: tracker,
        failedAgentNames: failed,
        stalledAgentNames: stalled,
        onAgentDone: (_, __, ___) => doneCalled = true,
      );

      expect(turn, const GroupTurnResult());
      expect(stalled, ['Coder']);
      expect(failed, isEmpty);
      expect(doneCalled, isTrue);
    });

    test('legacy flag off keeps immediate failed behavior', () {
      GroupOrchestrationFeatures.stalledTimeout = false;
      final tracker = GroupMemberStallTracker();
      final failed = <String>[];
      final stalled = <String>[];

      GroupMemberStallHandler.handleExecutionError(
        error: MemberStalledException(agentName: 'Coder'),
        agent: _agent('coder', 'Coder'),
        tracker: tracker,
        failedAgentNames: failed,
        stalledAgentNames: stalled,
      );

      expect(failed, ['Coder']);
      expect(stalled, isEmpty);
    });
  });

  group('GroupTaskStatusParser.adminStalledFollowUpNote', () {
    test('lists stalled members with timeout label', () {
      final note = GroupTaskStatusParser.adminStalledFollowUpNote(const [
        MemberStallRequest(
          agentId: 'coder',
          name: 'Coder',
          timeout: Duration(minutes: 10),
          stallCount: 1,
        ),
      ]);

      expect(note, contains('Coder'));
      expect(note, contains('10 分钟'));
      expect(note, contains('group_dispatch'));
    });
  });

  group('GroupResultWriter stalled status', () {
    test('maps stalled agents to results.json status', () {
      final member = GroupResultWriter.fromTurnResult(
        agentId: 'coder',
        agentName: 'Coder',
        turn: const GroupTurnResult(content: ''),
        round: 1,
        stalledAgentNames: ['Coder'],
      );

      expect(member!.taskStatus, GroupTaskMemberResult.statusStalled);
      expect(member.summary, contains('10'));
    });
  });

  group('GroupEvent.memberStalled', () {
    test('renders compact stalled line', () {
      final e = GroupEvent.memberStalled(
        channelId: 'chan',
        agentId: 'coder',
        agentName: 'Coder',
        timeoutSeconds: acpTaskTimeout.inSeconds,
        stallCount: 2,
        round: 1,
        orchestrationId: 'msg-1',
      );

      expect(e.type, GroupEventType.memberStalled);
      expect(renderEventLine(e), contains('stalled'));
      expect(renderEventLine(e), contains('第 2 次'));
    });
  });
}
