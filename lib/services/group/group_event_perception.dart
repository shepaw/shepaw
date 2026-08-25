import 'dart:async';

import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../acp_agent_connection.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import 'group_agent_executor.dart';
import 'group_dispatch_parser.dart';
import 'group_event.dart';
import 'group_event_store.dart';

/// Whether an event type triggers an admin perception turn (active-notify) or
/// is only recorded for passive context injection.
class EventPerceptionPolicy {
  final Set<GroupEventType> activeNotifyTypes;

  const EventPerceptionPolicy({required this.activeNotifyTypes});

  /// Default: membership changes and step failures activate the admin. Step
  /// successes are passive — the admin is not woken up per node.
  factory EventPerceptionPolicy.defaultPolicy() => const EventPerceptionPolicy(
        activeNotifyTypes: {
          GroupEventType.memberJoined,
          GroupEventType.memberLeft,
          GroupEventType.stepFailed,
        },
      );

  bool isActiveNotify(GroupEventType type) => activeNotifyTypes.contains(type);
}

/// Builds the turn content for an admin perception turn.
typedef GroupEventPromptBuilder = String Function({
  required String groupName,
  required List<GroupEvent> events,
  required List<RemoteAgent> currentMembers,
});

/// Fires a single "admin perception turn" after active-notify group events.
///
/// Generalizes [GroupMembershipPerceptionScheduler] to arbitrary event kinds:
/// coalesces rapid events per channel (debounced), guards against overlapping
/// turns, and runs one [GroupAgentExecutor.processGroupAgent] turn with a
/// no-tools custom prompt so the admin acknowledges without re-dispatching.
///
/// All scheduling is fire-and-forget — [schedule] never throws and never
/// blocks the caller. LLM failures are logged and swallowed.
class GroupEventPerceptionScheduler {
  GroupEventPerceptionScheduler({
    required LocalDatabaseService db,
    required GroupAgentExecutor executor,
    required Map<String, ACPAgentConnection> acpConnections,
    required Future<List<Message>> Function(String channelId, {int limit})
        loadChannelMessages,
    GroupDispatchParser? dispatchParser,
    GroupEventStore? eventStore,
    EventPerceptionPolicy? policy,
    GroupEventPromptBuilder? promptBuilder,
    String? customSystemPrompt,
    Duration debounce = const Duration(seconds: 3),
  })  : _db = db,
        _executor = executor,
        _acpConnections = acpConnections,
        _loadChannelMessages = loadChannelMessages,
        _dispatchParser = dispatchParser ?? GroupDispatchParser(db),
        _eventStore = eventStore,
        _policy = policy ?? EventPerceptionPolicy.defaultPolicy(),
        _promptBuilder = promptBuilder ?? buildGenericPerceptionPrompt,
        _customSystemPrompt =
            customSystemPrompt ?? genericPerceptionSystemPrompt,
        _debounce = debounce;

  final LocalDatabaseService _db;
  final GroupAgentExecutor _executor;
  final Map<String, ACPAgentConnection> _acpConnections;
  final Future<List<Message>> Function(String channelId, {int limit})
      _loadChannelMessages;
  final GroupDispatchParser _dispatchParser;
  final GroupEventStore? _eventStore;
  final EventPerceptionPolicy _policy;
  final GroupEventPromptBuilder _promptBuilder;
  final String _customSystemPrompt;
  final Duration _debounce;

  /// Pending active-notify events per channel, coalesced in the debounce
  /// window and drained into a single admin turn.
  final Map<String, List<GroupEvent>> _pending = {};
  final Map<String, Timer> _timers = {};

  /// Channels with an in-flight perception turn — prevents overlapping
  /// `processGroupAgent` calls for the same channel.
  final Set<String> _running = {};

  /// Per-channel generation counter. `cancelPendingForChannel` bumps it so a
  /// superseded in-flight turn aborts before writing its admin message.
  final Map<String, int> _epoch = {};

  /// In-flight turn cancellation tokens, keyed by channel.
  final Map<String, ACPCancellationToken> _turnTokens = {};

  /// Record an event. Synchronous and non-blocking.
  ///
  /// Every event is written to the event store (passive awareness); only
  /// active-notify types additionally enqueue an admin perception turn.
  void schedule(GroupEvent event) {
    _eventStore?.record(event);
    if (_policy.isActiveNotify(event.type)) {
      _pending.putIfAbsent(event.channelId, () => []).add(event);
      _arm(event.channelId);
    }
  }

  /// Drop any pending (not-yet-fired) perception turns for [channelId].
  ///
  /// Used by the workflow failure path: a failed step is already reported to
  /// the admin via the workflow closing summary, so the debounced stepFailed
  /// perception turn would otherwise produce a redundant second admin reply.
  void cancelPendingForChannel(String channelId) {
    _pending.remove(channelId);
    _timers.remove(channelId)?.cancel();
    // Bump the epoch and cancel any in-flight turn: the workflow failure path /
    // stage gate already replies to the admin, so a superseded perception turn
    // must not produce a redundant second admin message.
    _epoch[channelId] = (_epoch[channelId] ?? 0) + 1;
    _turnTokens.remove(channelId)?.cancel();
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
      // A turn is already in flight; keep the events pending and re-arm so
      // they are picked up once the current turn settles.
      _arm(channelId);
      return;
    }
    final events = _pending.remove(channelId);
    if (events == null || events.isEmpty) return;

    _running.add(channelId);
    final token = ACPCancellationToken();
    final epoch = _epoch[channelId] ?? 0;
    _turnTokens[channelId] = token;
    try {
      await _runTurn(channelId, events, token, epoch);
    } finally {
      if (identical(_turnTokens[channelId], token)) {
        _turnTokens.remove(channelId);
      }
      _running.remove(channelId);
    }
  }

  Future<void> _runTurn(
    String channelId,
    List<GroupEvent> events,
    ACPCancellationToken token,
    int epoch,
  ) async {
    try {
      final channel = await _db.getChannelById(channelId);
      final adminId = channel?.adminAgentId;
      if (channel == null || adminId == null) return;

      // Never notify the admin about its own event (join/leave/step).
      final filtered = events.where((e) => e.agentId != adminId).toList();
      if (filtered.isEmpty) return;

      // 感知回合的提示词 = 触发事件 + 事件日志里最近的被动事件（如失败前刚
      // 成功的节点），去重后取最近若干条，让管理员看到失败前的最新节点结果。
      // 无 event store（成员感知 facade）时退化为仅渲染触发事件。
      final storeEvents =
          _eventStore?.recent(channelId, limit: 10) ?? const <GroupEvent>[];
      final merged = <String, GroupEvent>{};
      for (final e in [...storeEvents, ...filtered]) {
        merged[e.id] = e;
      }
      var promptEvents = merged.values
          .where((e) => e.agentId != adminId)
          .toList();
      if (promptEvents.length > 8) {
        promptEvents = promptEvents.sublist(promptEvents.length - 8);
      }
      if (promptEvents.isEmpty) return;

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
      // event details come from the content prompt below.
      final raw = await _loadChannelMessages(channelId, limit: 50);
      final history = raw
          .where((m) =>
              m.type != MessageType.system &&
              m.type != MessageType.permissionAudit)
          .toList();

      final content = _promptBuilder(
        groupName: channel.name,
        events: promptEvents,
        currentMembers: allAgents,
      );

      // Re-check cancellation right before writing: the workflow failure path /
      // stage gate may have superseded this turn (cancelPendingForChannel bumps
      // the epoch). A superseded turn must not emit a redundant admin message.
      if (token.isCancelled || epoch != (_epoch[channelId] ?? 0)) return;

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
        customSystemPrompt: _customSystemPrompt,
        channelMembers: channel.members,
        adminAgent: adminAgent,
        isFlowMode: false,
        messageVersion: null,
        acpCancellationToken: token,
      );

      // Safety net: a perception turn must never leave a raw dispatch JSON
      // block in the channel message (no orchestration loop runs here).
      await _dispatchParser
          .stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
    } catch (e, st) {
      LoggerService().error(
        'Group event perception turn failed for $channelId',
        tag: 'GroupEventPerception',
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
}

/// Generic perception prompt rendering a list of events plus the current
/// roster, and forbidding dispatch/tools.
String buildGenericPerceptionPrompt({
  required String groupName,
  required List<GroupEvent> events,
  required List<RemoteAgent> currentMembers,
}) {
  final buffer = StringBuffer()
    ..writeln('【系统通知 · 群事件】')
    ..writeln()
    ..writeln('群聊「$groupName」最近发生了以下事件，请知悉，以便你调整任务分配与执行：')
    ..writeln();
  for (final e in events) {
    buffer.writeln('• ${renderEventLine(e)}');
  }
  buffer.writeln();
  buffer.writeln(
      '当前群成员（${currentMembers.length} 人）：${currentMembers.map((a) => a.name).join('、')}');
  buffer.writeln();
  buffer.writeln('请基于此更新你的认知。请用 1-3 句话简短确认已收到，并可说明你打算如何调整任务分配。'
      '这是系统自动发送的内部通知：不要执行任何委派或编排动作，不要调用任何工具。');
  return buffer.toString();
}

/// Custom system prompt for the generic perception turn — reinforces the
/// "no tools" instruction on top of the base admin prompt.
const String genericPerceptionSystemPrompt = '本次消息是群事件的自动内部通知。'
    '你只需知悉事件并简短确认，不要调用 group_dispatch、group_finish、group_mention、'
    'shepaw 等任何工具，不要输出 ```json 派发块，不要调用任何 UI 工具。'
    '直接回复 1-3 句话即可。';
