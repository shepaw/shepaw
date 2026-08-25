import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../acp_agent_connection.dart';
import '../local_database_service.dart';
import 'group_agent_executor.dart';
import 'group_dispatch_parser.dart';
import 'group_event.dart';
import 'group_event_perception.dart';

/// One roster change (join / leave) that should reach the group admin's
/// awareness.
class MembershipChangeEvent {
  final String memberId;
  final String memberName;
  final bool isJoin;

  const MembershipChangeEvent({
    required this.memberId,
    required this.memberName,
    required this.isJoin,
  });
}

/// Fires a single "admin perception turn" after group membership changes.
///
/// The group admin (She) never sees `MessageType.system` join/leave messages
/// — `GroupOrchestrationService.sendMessageToGroup` filters them out of agent
/// history — so the admin cannot react to roster changes on its own. This
/// scheduler coalesces rapid changes (e.g. a CLI `addMember` loop) per channel
/// and triggers one admin turn via [GroupAgentExecutor.processGroupAgent] so
/// the admin acknowledges the change and can note task reallocation.
///
/// This class is now a thin facade over [GroupEventPerceptionScheduler] with a
/// membership-specific prompt builder; all debounce/guard/merge mechanics live
/// in the generic engine. All scheduling is fire-and-forget: [schedule] never
/// throws and never blocks the membership operation itself.
class GroupMembershipPerceptionScheduler {
  final GroupEventPerceptionScheduler _inner;

  GroupMembershipPerceptionScheduler({
    required LocalDatabaseService db,
    required GroupAgentExecutor executor,
    required Map<String, ACPAgentConnection> acpConnections,
    required Future<List<Message>> Function(String channelId, {int limit})
        loadChannelMessages,
    GroupDispatchParser? dispatchParser,
    Duration debounce = const Duration(seconds: 3),
  }) : _inner = GroupEventPerceptionScheduler(
          db: db,
          executor: executor,
          acpConnections: acpConnections,
          loadChannelMessages: loadChannelMessages,
          dispatchParser: dispatchParser,
          debounce: debounce,
          promptBuilder: _buildMembershipPrompt,
          customSystemPrompt: perceptionSystemPrompt,
        );

  /// Record a membership change. Synchronous and non-blocking.
  void schedule({
    required String channelId,
    required String memberId,
    required String memberName,
    required bool isJoin,
  }) {
    _inner.schedule(GroupEvent.memberChange(
      channelId: channelId,
      memberId: memberId,
      memberName: memberName,
      isJoin: isJoin,
    ));
  }

  /// Adapt the generic event list back to the membership prompt shape so the
  /// admin sees the familiar 加入/离开/当前成员 rendering.
  static String _buildMembershipPrompt({
    required String groupName,
    required List<GroupEvent> events,
    required List<RemoteAgent> currentMembers,
  }) {
    final changes = events.map((e) => MembershipChangeEvent(
          memberId: e.agentId ?? '',
          memberName: e.agentName ?? '',
          isJoin: e.type == GroupEventType.memberJoined,
        )).toList();
    return buildMembershipChangePrompt(
      changes: changes,
      currentMembers: currentMembers,
      groupName: groupName,
    );
  }

  /// Whether a perception turn can execute for [adminAgent] right now.
  ///
  /// Local and peer agents always can (the executor has dedicated paths);
  /// remote ACP admins need a live connection.
  static bool canAdminExecuteTurn({
    required RemoteAgent adminAgent,
    required Map<String, ACPAgentConnection> acpConnections,
  }) {
    return GroupEventPerceptionScheduler.canAdminExecuteTurn(
      adminAgent: adminAgent,
      acpConnections: acpConnections,
    );
  }

  /// Build the perception prompt that reaches the admin as its turn content.
  static String buildMembershipChangePrompt({
    required List<MembershipChangeEvent> changes,
    required List<RemoteAgent> currentMembers,
    required String groupName,
  }) {
    final joined = changes.where((c) => c.isJoin).map((c) => c.memberName);
    final left = changes.where((c) => !c.isJoin).map((c) => c.memberName);

    final buffer = StringBuffer()
      ..writeln('【系统通知 · 群成员变动】')
      ..writeln()
      ..writeln('群聊「$groupName」最近发生了成员变动，请知悉，以便你后续分配与调整任务：')
      ..writeln();
    if (joined.isNotEmpty) buffer.writeln('加入：${joined.join('、')}');
    if (left.isNotEmpty) buffer.writeln('离开：${left.join('、')}');
    buffer.writeln();
    final memberNames = currentMembers.map((a) => a.name).toList();
    buffer.writeln('当前群成员（${memberNames.length} 人）：${memberNames.join('、')}');
    buffer.writeln();
    buffer.writeln('请基于此更新你对团队构成的认知。请用 1-3 句话简短确认已收到，'
        '并可说明你打算如何重新调整任务分配。这是系统自动发送的内部通知：'
        '不要执行任何委派或编排动作，不要调用任何工具。');
    return buffer.toString();
  }

  /// Custom system prompt for the perception turn — reinforces the "no tools"
  /// instruction on top of the base admin prompt.
  static const String perceptionSystemPrompt = '本次消息是群成员变动的自动内部通知。'
      '你只需知悉变动并简短确认，不要调用 group_dispatch、group_finish、group_mention、'
      'shepaw 等任何工具，不要输出 ```json 派发块，不要调用任何 UI 工具。'
      '直接回复 1-3 句话即可。';
}
