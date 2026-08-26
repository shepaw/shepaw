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

    /// 该频道是否正在运行编排 loop（M2）。感知回合是后台通知，编排 loop 正在
    /// 处理用户消息时让位（drop），避免与编排 admin 回合交错。
    bool Function(String channelId)? isChannelOrchestrating,
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
        _debounce = debounce,
        _isChannelOrchestrating = isChannelOrchestrating;

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
  final bool Function(String channelId)? _isChannelOrchestrating;

  /// Pending active-notify events per channel, coalesced in the debounce
  /// window and drained into a single admin turn.
  final Map<String, List<GroupEvent>> _pending = {};
  final Map<String, Timer> _timers = {};

  /// Channels with an in-flight perception turn — prevents overlapping
  /// `processGroupAgent` calls for the same channel.
  final Set<String> _running = {};

  /// L17: 回合 in-flight 期间有事件到达且 drain 已被调用时置位，等当前回合
  /// finally 收尾后再补一次 drain——避免 3s 轮询式 re-arm 一直空转。
  final Set<String> _needsDrain = {};

  /// 全局管理员回合互斥（M2）。
  ///
  /// 两个 scheduler 实例（event / membership）各自持有 `_running`，互不知晓；
  /// 且门闸/收尾/编排 loop 会直接 `processGroupAgent`，同样不受 `_running`
  /// 约束。这里提供「同一 admin 同时只能有一个进行中的 LLM 回合」的共享锁：
  /// - 感知回合（后台通知）用 [tryBeginAdminTurn]：admin 已被占用时让位（drop）。
  /// - 显式回合（门闸/收尾/编排 admin）用 [forceBeginAdminTurn]：抢占，使
  ///   被抢占的感知回合在写盘前发现 holder 已变更而中止（配合预写 re-check）。
  ///
  /// value 为当前持有者标识；[endAdminTurn] 仅当仍是自己持有时才释放，避免
  /// 抢占方把被抢占方的 `finally` 释放误判为自己的释放（double-release）。
  static final Map<String, String> _adminTurnHolder = {};
  static int _adminTurnSeq = 0;

  static String _nextHolderId() => 'admin-turn-${_adminTurnSeq++}';

  static bool tryBeginAdminTurn(String adminId, String holderId) {
    final existing = _adminTurnHolder[adminId];
    if (existing != null && existing != holderId) return false;
    _adminTurnHolder[adminId] = holderId;
    return true;
  }

  static void forceBeginAdminTurn(String adminId, String holderId) {
    _adminTurnHolder[adminId] = holderId;
  }

  /// 显式回合（门闸/收尾/编排 admin）开始：生成唯一 holder 并抢占全局锁。
  /// 返回 holderId，供 [endAdminTurn] 对称释放。
  static String beginExplicitAdminTurn(String adminId) {
    final holderId = _nextHolderId();
    forceBeginAdminTurn(adminId, holderId);
    return holderId;
  }

  static void endAdminTurn(String adminId, String holderId) {
    if (_adminTurnHolder[adminId] == holderId) {
      _adminTurnHolder.remove(adminId);
    }
  }

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

  /// 释放全部 debounce timer（L15）。App 退出 / ChatService.dispose 时调用，
  /// 避免一次性实例泄漏 Timer（当前实现里每个 timer 回调后自清理，但 in-flight
  /// 期间的 re-arm 循环可能残留一个待触发的 timer）。
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
    _needsDrain.clear();
  }

  Future<void> _drain(String channelId) async {
    if (_running.contains(channelId)) {
      // A turn is already in flight; record that a drain is still needed and
      // let the running turn's `finally` re-arm once. L17：不再在 in-flight
      // 期间每 3s 重新 arm 空转（长回合会一直轮询），事件在收尾后统一补拾。
      _needsDrain.add(channelId);
      return;
    }
    _needsDrain.remove(channelId);
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
      if (_needsDrain.remove(channelId)) {
        // 回合进行中到达的事件：补一次 drain（debounce 后统一处理），
        // 而不是让它们在 `_pending` 里无限等待。
        _arm(channelId);
      }
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

      // M2: 编排 loop 正在处理该频道用户消息时，感知回合让位（drop），避免
      // 与编排 admin 回合交错（编排 admin 回合不被 `_running`/互斥覆盖）。
      if (_isChannelOrchestrating?.call(channelId) == true) {
        LoggerService().debug(
          'Perception turn dropped: channel $channelId is orchestrating',
          tag: 'GroupEventPerception',
        );
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

      // M2: 全局管理员回合互斥 —— 感知回合是后台通知。另一 scheduler 实例或
      // 门闸/收尾/编排 loop 已占用该 admin 时，本次感知让位（drop，不排队，
      // 避免与显式回合交错或经「Agent busy」被静默吞掉）。
      final holderId = _nextHolderId();
      if (!tryBeginAdminTurn(adminId, holderId)) {
        LoggerService().debug(
          'Perception turn dropped: admin ${adminAgent.name} already in a turn',
          tag: 'GroupEventPerception',
        );
        return;
      }
      try {
        // 被抢占（门闸/收尾 forceBegin 换 holder）后在写盘前中止：避免被
        // 抢占的感知回合仍输出冗余管理员消息。
        if (token.isCancelled ||
            epoch != (_epoch[channelId] ?? 0) ||
            _adminTurnHolder[adminId] != holderId) {
          return;
        }
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
      } finally {
        endAdminTurn(adminId, holderId);
      }
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
