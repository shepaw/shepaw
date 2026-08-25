import 'dart:async';

import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../acp_agent_connection.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import 'group_agent_executor.dart';
import 'group_dispatch_parser.dart';

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
/// All scheduling is fire-and-forget: [schedule] never throws and never blocks
/// the membership operation itself. LLM failures are logged and swallowed.
class GroupMembershipPerceptionScheduler {
  final LocalDatabaseService _db;
  final GroupAgentExecutor _executor;
  final Map<String, ACPAgentConnection> _acpConnections;
  final Future<List<Message>> Function(String channelId, {int limit})
      _loadChannelMessages;
  final GroupDispatchParser _dispatchParser;
  final Duration _debounce;

  /// Pending changes per channel, coalesced within the debounce window.
  final Map<String, List<MembershipChangeEvent>> _pending = {};
  final Map<String, Timer> _timers = {};

  /// Channels with an in-flight perception turn — prevents overlapping
  /// `processGroupAgent` calls for the same channel.
  final Set<String> _running = {};

  GroupMembershipPerceptionScheduler({
    required LocalDatabaseService db,
    required GroupAgentExecutor executor,
    required Map<String, ACPAgentConnection> acpConnections,
    required Future<List<Message>> Function(String channelId, {int limit})
        loadChannelMessages,
    GroupDispatchParser? dispatchParser,
    Duration debounce = const Duration(seconds: 3),
  })  : _db = db,
        _executor = executor,
        _acpConnections = acpConnections,
        _loadChannelMessages = loadChannelMessages,
        _dispatchParser = dispatchParser ?? GroupDispatchParser(db),
        _debounce = debounce;

  /// Record a membership change. Synchronous and non-blocking.
  void schedule({
    required String channelId,
    required String memberId,
    required String memberName,
    required bool isJoin,
  }) {
    _pending.putIfAbsent(channelId, () => []).add(MembershipChangeEvent(
          memberId: memberId,
          memberName: memberName,
          isJoin: isJoin,
        ));
    _arm(channelId);
  }

  void _arm(String channelId) {
    _timers[channelId]?.cancel();
    _timers[channelId] = Timer(_debounce, () {
      _timers.remove(channelId);
      unawaited(_drain(channelId));
    });
  }

  Future<void> _drain(String channelId) async {
    if (_running.contains(channelId)) {
      // A turn is already in flight; keep the changes pending and re-arm so
      // they are picked up once the current turn settles.
      _arm(channelId);
      return;
    }
    final changes = _pending.remove(channelId);
    if (changes == null || changes.isEmpty) return;

    _running.add(channelId);
    try {
      await _runTurn(channelId, changes);
    } finally {
      _running.remove(channelId);
    }
  }

  Future<void> _runTurn(
    String channelId,
    List<MembershipChangeEvent> changes,
  ) async {
    try {
      final channel = await _db.getChannelById(channelId);
      final adminId = channel?.adminAgentId;
      if (channel == null || adminId == null) return;

      // Never notify the admin about its own join/leave.
      final filtered =
          changes.where((c) => c.memberId != adminId).toList();
      if (filtered.isEmpty) return;

      final adminAgent = await _db.getRemoteAgentById(adminId);
      if (adminAgent == null) return;
      if (!canAdminExecuteTurn(
        adminAgent: adminAgent,
        acpConnections: _acpConnections,
      )) {
        return;
      }

      // Current member agents — used both for the prompt and the executor's
      // `allAgents` so the admin sees the up-to-date roster.
      final memberIds = await _db.getChannelMemberIds(channelId);
      final allAgents = <RemoteAgent>[];
      for (final id in memberIds) {
        final a = await _db.getRemoteAgentById(id);
        if (a != null) allAgents.add(a);
      }

      // Snapshot history, mirroring orchestration's non-system filter. The
      // roster-change details come from the content prompt below.
      final raw = await _loadChannelMessages(channelId, limit: 50);
      final history = raw
          .where((m) =>
              m.type != MessageType.system &&
              m.type != MessageType.permissionAudit)
          .toList();

      final content = buildMembershipChangePrompt(
        changes: filtered,
        currentMembers: allAgents,
        groupName: channel.name,
      );

      await _executor.processGroupAgent(
        agent: adminAgent,
        channelId: channelId,
        content: content,
        userId: LocalUserIdentity.id,
        userName: LocalUserIdentity.displayName,
        groupName: channel.name,
        groupDescription: channel.description ?? '',
        allAgents: allAgents,
        historyMessages: history,
        mentionedAgentIds: const [],
        isFirstMessage: false,
        isAdmin: true,
        customSystemPrompt: perceptionSystemPrompt,
        channelMembers: channel.members,
        adminAgent: adminAgent,
        isFlowMode: false,
        messageVersion: null,
      );

      // Safety net: a perception turn must never leave a raw dispatch JSON
      // block in the channel message (no orchestration loop runs here).
      await _dispatchParser
          .stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
    } catch (e, st) {
      LoggerService().error(
        'Group membership perception turn failed for $channelId',
        tag: 'GroupMembershipPerception',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Whether a perception turn can execute for [adminAgent] right now.
  ///
  /// Local and peer agents always can (the executor has dedicated paths);
  /// remote ACP admins need a live connection.
  static bool canAdminExecuteTurn({
    required RemoteAgent adminAgent,
    required Map<String, ACPAgentConnection> acpConnections,
  }) {
    if (adminAgent.isLocal) return true;
    if (adminAgent.isPeerAgent) return true;
    return acpConnections[adminAgent.id]?.isConnected == true;
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
