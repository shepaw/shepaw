import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../models/message.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../models/acp_protocol.dart';
import '../models/attachment_data.dart';
import 'local_database_service.dart';
import 'tool_result_database_service.dart';
import 'acp_agent_connection.dart';
import 'notification_service.dart';
// Sub-service imports (refactored)
import 'task/task_models.dart';
import 'task/plan_approval_service.dart';
import 'group/group_dispatch_parser.dart';
import 'group/group_prompt_builder.dart';
import 'group/group_interaction_handler.dart';
import 'group/planning_helpers.dart';
import 'group/group_agent_executor.dart';
import 'group/group_orchestration_service.dart';
import 'messaging/agent_messaging_service.dart';
import 'group/group_session_service.dart';
import 'session/session_history_service.dart';
import 'app_lifecycle_service.dart';
import '../providers/notification_provider.dart';
import 'foreground_task_service.dart';
import 'logger_service.dart';
import 'flow_executor.dart';
import 'os_tool_executor.dart' as os_exec;
import 'she_service.dart';
import 'paw_tool_registry.dart';

/// Result of a history supplement request, carrying both the agent's
/// re-answer message and how many history entries were actually sent.
class HistorySupplementResult {
  final Message message;
  final int actualSentCount;
  /// Non-null when the agent asked for even more history during this supplement.
  final Map<String, dynamic>? pendingHistoryRequest;
  const HistorySupplementResult({
    required this.message,
    required this.actualSentCount,
    this.pendingHistoryRequest,
  });
}

// ActiveTask, GroupActiveTask → see lib/services/task/task_models.dart
// PlanApprovalHandle → see lib/services/task/plan_approval_service.dart

/// Chat Service
/// Handles message sending and receiving with agents
class ChatService implements IPawChatSender {
  static final ChatService _instance = ChatService._internal(LocalDatabaseService(), ToolResultDatabaseService());
  factory ChatService([LocalDatabaseService? db]) => _instance;

  final LocalDatabaseService _databaseService;
  final ToolResultDatabaseService _toolResultService;
  final Uuid _uuid = const Uuid();

  // Stream controllers for real-time updates
  final Map<String, StreamController<List<Message>>> _messageControllers = {};

  // ACP connection pool (keyed by agent ID)
  final Map<String, ACPAgentConnection> _acpConnections = {};

  // Active tasks (keyed by channelId) — survives UI detach/reattach
  final Map<String, ActiveTask> _activeTasks = {};

  // Pending plan_approvals: managed by PlanApprovalService
  final PlanApprovalService _planApprovalService = PlanApprovalService();

  // Active group tasks: channelId -> { agentId -> GroupActiveTask }
  final Map<String, Map<String, GroupActiveTask>> _activeGroupTasks = {};

  // Active FlowExecutors: channelId -> FlowExecutor (one per group channel)
  final Map<String, FlowExecutor> _activeFlowExecutors = {};

  /// Sub-service: group session management (create/list/clear sessions)
  late final GroupSessionService _groupSessionService = GroupSessionService(
    db: _databaseService,
    uuid: _uuid,
    acpConnections: _acpConnections,
    notifyChannelUpdate: _notifyChannelUpdate,
  );

  /// Sub-service: group dispatch parsing (structured JSON dispatch blocks)
  late final GroupDispatchParser _groupDispatchParser = GroupDispatchParser(_databaseService);

  /// Sub-service: session management (create/list DM sessions)
  late final SessionService _sessionService = SessionService(_databaseService);

  /// Sub-service: message history (load/delete/rollback)
  late final HistoryService _historyService = HistoryService(_databaseService, _toolResultService);

  /// Sub-service: group system prompt and modality detection
  final GroupPromptBuilder _groupPromptBuilder = const GroupPromptBuilder();

  /// Sub-service: admin interaction decisions and group system messages
  late final GroupInteractionHandler _groupInteractionHandler = GroupInteractionHandler(
    db: _databaseService,
    uuid: _uuid,
    acpConnections: _acpConnections,
    notifyChannelUpdate: _notifyChannelUpdate,
    loadChannelMessages: (channelId, {int limit = 100}) => loadChannelMessages(channelId, limit: limit),
  );

  /// Sub-service: plan-mode helpers (strip blocks, task board, status parsing)
  late final PlanningHelpers _planningHelpers = PlanningHelpers(
    db: _databaseService,
    uuid: _uuid,
    notifyChannelUpdate: _notifyChannelUpdate,
  );

  /// Sub-service: per-agent group chat execution (local LLM + remote ACP)
  late final GroupAgentExecutor _groupAgentExecutor = GroupAgentExecutor(
    db: _databaseService,
    uuid: _uuid,
    acpConnections: _acpConnections,
    activeGroupTasks: _activeGroupTasks,
    promptBuilder: _groupPromptBuilder,
    interactionHandler: _groupInteractionHandler,
    notifyChannelUpdate: _notifyChannelUpdate,
    updateTypingAgentIds: _updateTypingAgentIds,
    getOrCreateACPConnection: _agentMessagingService.getOrCreateACPConnection,
  );

  /// Sub-service: 1:1 agent messaging (sendMessageToAgent + ACP + local LLM)
  late final AgentMessagingService _agentMessagingService = AgentMessagingService(
    db: _databaseService,
    toolResultDb: _toolResultService,
    uuid: _uuid,
    acpConnections: _acpConnections,
    activeTasks: _activeTasks,
    saveMessageToChannel: (message, agentId, {String? channelId}) =>
        _saveMessageToChannel(message, agentId, channelId: channelId),
    updateTypingAgentIds: _updateTypingAgentIds,
    releaseForegroundTask: (agentName) => ForegroundTaskService().releaseTask(agentName),
    loadChannelMessages: (channelId, {int limit = 100}) => loadChannelMessages(channelId, limit: limit),
    getMessageById: (id) => getMessageById(id),
  );

  /// Sub-service: group message orchestration (sendMessageToGroup routing)
  late final GroupOrchestrationService _groupOrchestrationService = GroupOrchestrationService(
    db: _databaseService,
    uuid: _uuid,
    executor: _groupAgentExecutor,
    dispatchParser: _groupDispatchParser,
    planningHelpers: _planningHelpers,
    notifyChannelUpdate: _notifyChannelUpdate,
    loadAndTruncateHistory: _loadAndTruncateHistory,
    awaitPlanApproval: ({
      required String channelId,
      required String agentId,
      required String agentName,
      required Map<String, dynamic> planData,
      required String messageId,
    }) => awaitPlanApproval(
      channelId: channelId,
      agentId: agentId,
      agentName: agentName,
      planData: planData,
      messageId: messageId,
    ),
    activeFlowExecutors: _activeFlowExecutors,
    loadChannelMessages: (channelId, {int limit = 100}) => loadChannelMessages(channelId, limit: limit),
    getMessageById: (id) => getMessageById(id),
  );

  /// Notifier that emits the set of agent IDs currently typing in 1:1 chats.
  final ValueNotifier<Set<String>> typingAgentIds = ValueNotifier<Set<String>>({});

  /// Notifier that emits the set of channel IDs that have typing activity
  /// (either 1:1 or group). Used by the conversation list to show typing
  /// indicators on the correct conversation tile.
  final ValueNotifier<Set<String>> typingChannelIds = ValueNotifier<Set<String>>({});

  ChatService._internal(this._databaseService, this._toolResultService) {
    // Register this instance as the IPawChatSender so She can dispatch
    // `shepaw agents chat` commands.
    PawToolRegistry.instance.chatSender = this;
  }

  /// Notification provider, injected from the widget layer.
  NotificationProvider? _notificationProvider;

  void setNotificationProvider(NotificationProvider provider) {
    _notificationProvider = provider;
  }

  // ── IPawChatSender implementation ──────────────────────────────────────────

  /// Send a message to [targetAgent] in [channelId] appearing as if She sent it.
  /// Used by `shepaw agents chat`.
  ///
  /// Fire-and-forget: we do NOT await ret1's LLM response here.
  /// Awaiting would deadlock She's own tool-calling loop, because She is
  /// suspended inside PawToolRegistry.execute() waiting for this method to
  /// return, while ret1's LLM is waiting for resources on the same thread.
  @override
  Future<void> sendAsSheTo({
    required RemoteAgent targetAgent,
    required String channelId,
    required String message,
  }) async {
    LoggerService().info(
      'She → ${targetAgent.name} [channel: $channelId]: ${message.length > 60 ? '${message.substring(0, 60)}…' : message}',
      tag: 'PawChat',
    );
    // Launch ret1's message handling concurrently so She's tool loop is not
    // blocked waiting for ret1's LLM to finish.
    unawaited(_agentMessagingService.sendMessageToAgent(
      content: message,
      agent: targetAgent,
      userId: SheService.sheId,
      userName: SheService.sheName,
      channelId: channelId,
    ).catchError((Object e, StackTrace st) {
      LoggerService().error(
        'sendAsSheTo: failed to deliver message to ${targetAgent.name}',
        tag: 'PawChat',
        error: e,
        stackTrace: st,
      );
    }));
  }

  /// Recompute and notify [typingAgentIds] and [typingChannelIds] based on current active tasks.
  void _updateTypingAgentIds() {
    // typingAgentIds: only 1:1 chat agents (not group tasks)
    final ids = _activeTasks.values
        .where((t) => !t.isComplete)
        .map((t) => t.agentId)
        .toSet();
    typingAgentIds.value = ids;

    // typingChannelIds: all channels with active typing (1:1 + group)
    final channelIds = _activeTasks.entries
        .where((e) => !e.value.isComplete)
        .map((e) => e.key)
        .toSet();
    for (final channelId in _activeGroupTasks.keys) {
      final agentMap = _activeGroupTasks[channelId]!;
      if (agentMap.values.any((t) => !t.isComplete)) {
        channelIds.add(channelId);
      }
    }
    typingChannelIds.value = channelIds;
  }

  /// Release the foreground task lock for [agentName].
  void _releaseForegroundTask(String agentName) {
    ForegroundTaskService().releaseTask(agentName);
  }

  /// Called when the app resumes from background after [backgroundDuration].
  /// Checks all active tasks and marks any that lost their connection as
  /// interrupted, saving partial content to the database.
  ///
  /// Local LLM tasks (no ACP connection) are left alone — the Dart isolate
  /// keeps running HTTP streams in the background on Android, so they should
  /// finish naturally. Only WebSocket-based ACP tasks are checked/interrupted.
  Future<void> handleAppResumed(Duration backgroundDuration) async {
    // Short background — connections likely survived.
    if (backgroundDuration.inSeconds < 3) return;

    final tasksToCleanup = <String>[];

    for (final entry in _activeTasks.entries) {
      final channelId = entry.key;
      final task = entry.value;
      if (task.isComplete) continue;

      // Check ACP connection liveness — only applies to remote agents that
      // communicate over WebSocket. Local LLM tasks use plain HTTP SSE which
      // survives app backgrounding on Android/iOS, so we skip them entirely.
      final conn = _acpConnections[task.agentId];
      if (conn != null) {
        if (!conn.isConnected) {
          final reconnected = await conn.tryReconnectNow();
          if (!reconnected) {
            tasksToCleanup.add(channelId);
          } else {
            // Even if reconnect succeeded, the server-side task is likely
            // lost (agent moved on), so still mark as interrupted.
            tasksToCleanup.add(channelId);
          }
        }
      }
      // else: local LLM task — leave it running, don't interrupt.
    }

    for (final channelId in tasksToCleanup) {
      await _markTaskInterrupted(channelId);
    }
  }

  /// Mark an active task as interrupted by background, save partial content
  /// to the database, and clean up.
  Future<void> _markTaskInterrupted(String channelId) async {
    final task = _activeTasks[channelId];
    if (task == null || task.isComplete) return;

    task.isComplete = true;
    task.wasInterruptedByBackground = true;

    // Save partial content to DB
    final partialContent = task.accumulatedContent.isNotEmpty
        ? '${task.accumulatedContent}\n\n[Connection interrupted]'
        : '[Connection interrupted]';

    final partialMessage = Message(
      id: _uuid.v4(),
      content: partialContent,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(
        id: task.agentId,
        type: 'agent',
        name: task.agentName,
      ),
      to: MessageFrom(
        id: task.userId,
        type: 'user',
        name: task.userName,
      ),
      type: MessageType.text,
      replyTo: task.userMessageId,
    );

    await _saveMessageToChannel(partialMessage, task.agentId, channelId: channelId);

    // Complete the DB save completer so any awaiting code resolves
    if (!task.dbSaveCompleter.isCompleted) {
      task.dbSaveCompleter.complete();
    }

    task.onTaskFinished?.call();

    // Store interrupted task info so the UI can read it for retry.
    _lastInterruptedTasks[channelId] = {
      'agentId': task.agentId,
      'partialContent': task.accumulatedContent,
      'userMessageId': task.userMessageId,
    };

    _activeTasks.remove(channelId);
    _updateTypingAgentIds();
    _releaseForegroundTask(task.agentName);
  }

  /// Returns info about an interrupted task for the given channel, or null.
  /// The returned map contains: agentId, partialContent, userMessageId.
  Map<String, String>? getInterruptedTaskInfo(String channelId) {
    // Look through tasks that were recently removed but flagged interrupted.
    // Since the task is already removed from _activeTasks after cleanup,
    // we store the last interrupted task info per channel.
    return _lastInterruptedTasks[channelId];
  }

  /// Storage for last interrupted task info per channel (set by _markTaskInterrupted).
  final Map<String, Map<String, String>> _lastInterruptedTasks = {};

  /// Clear interrupted task info after the UI has consumed it.
  void clearInterruptedTaskInfo(String channelId) {
    _lastInterruptedTasks.remove(channelId);
  }

  /// Query whether there is an in-progress task for [channelId].
  ActiveTask? getActiveTask(String channelId) {
    final task = _activeTasks[channelId];
    if (task != null && !task.isComplete) return task;
    return null;
  }

  /// Re-attach UI callbacks to a running background task.
  /// Returns the content accumulated so far, or null if no active task.
  String? attachTaskUI(
    String channelId, {
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic>)? onActionConfirmation,
    void Function(Map<String, dynamic>)? onSingleSelect,
    void Function(Map<String, dynamic>)? onMultiSelect,
    void Function(Map<String, dynamic>)? onFileUpload,
    void Function(Map<String, dynamic>)? onForm,
    Future<void> Function(Map<String, dynamic>)? onFileMessage,
    void Function(Map<String, dynamic>)? onMessageMetadata,
    void Function(Map<String, dynamic>)? onRequestHistory,
    void Function()? onTaskFinished,
  }) {
    final task = _activeTasks[channelId];
    if (task == null || task.isComplete) return null;

    task.onStreamChunk = onStreamChunk;
    task.onActionConfirmation = onActionConfirmation;
    task.onSingleSelect = onSingleSelect;
    task.onMultiSelect = onMultiSelect;
    task.onFileUpload = onFileUpload;
    task.onForm = onForm;
    task.onFileMessage = onFileMessage;
    task.onMessageMetadata = onMessageMetadata;
    task.onRequestHistory = onRequestHistory;
    task.onTaskFinished = onTaskFinished;

    return task.accumulatedContent;
  }

  /// Detach UI callbacks from the task on [channelId] without cancelling it.
  void detachTaskUI(String channelId) {
    _activeTasks[channelId]?.detachUI();
  }

  /// Get all active (non-complete) group tasks for a channel.
  Map<String, GroupActiveTask> getActiveGroupTasks(String channelId) {
    final agentMap = _activeGroupTasks[channelId];
    if (agentMap == null) return const {};
    // Return only tasks that are still in-progress
    final active = <String, GroupActiveTask>{};
    for (final entry in agentMap.entries) {
      if (!entry.value.isComplete) {
        active[entry.key] = entry.value;
      }
    }
    return active;
  }

  /// Attach UI callbacks to active group tasks for [channelId].
  /// Returns a map of agentId -> accumulated content so far.
  Map<String, String> attachGroupTaskUI(
    String channelId, {
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName)? onTaskFinished,
  }) {
    final agentMap = _activeGroupTasks[channelId];
    if (agentMap == null) return const {};
    final accumulated = <String, String>{};
    for (final entry in agentMap.entries) {
      final task = entry.value;
      if (task.isComplete) continue;
      accumulated[entry.key] = task.accumulatedContent;
      task.onStreamChunk = (chunk) {
        onStreamChunk?.call(task.agentId, task.agentName, chunk);
      };
      task.onTaskFinished = () {
        onTaskFinished?.call(task.agentId, task.agentName);
      };
    }
    return accumulated;
  }

  /// Detach UI callbacks from all group tasks for [channelId].
  void detachGroupTaskUI(String channelId) {
    final agentMap = _activeGroupTasks[channelId];
    if (agentMap == null) return;
    for (final task in agentMap.values) {
      task.detachUI();
    }
  }

  /// Force-complete and remove all active group tasks for [channelId].
  /// Called when the user stops group streaming to clean up typing indicators
  /// and prevent reattach from resuming cancelled tasks.
  void cancelActiveGroupTasks(String channelId) {
    final agentMap = _activeGroupTasks[channelId];
    if (agentMap == null) return;
    for (final task in agentMap.values) {
      task.isComplete = true;
      task.detachUI();
      _releaseForegroundTask(task.agentName);
    }
    _activeGroupTasks.remove(channelId);
    _updateTypingAgentIds();
  }

  // ---------------------------------------------------------------------------
  // Plan-approval persistence (survives channel navigation)
  // ---------------------------------------------------------------------------

  /// Called by sendMessageToGroup to create and await a plan_approval.
  /// Returns a Future that resolves when the user submits or the handle is cancelled.
  Future<Map<String, dynamic>?> awaitPlanApproval({
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> planData,
    required String messageId,
  }) => _planApprovalService.awaitPlanApproval(
    channelId: channelId,
    agentId: agentId,
    agentName: agentName,
    planData: planData,
    messageId: messageId,
  );

  /// Returns the pending plan_approval handle for [channelId], or null.
  PlanApprovalHandle? getPendingPlanApproval(String channelId) =>
      _planApprovalService.getPendingPlanApproval(channelId);

  /// Submit user's plan approval result (approve/reject/feedback).
  void completePlanApproval(String channelId, Map<String, dynamic> result) =>
      _planApprovalService.completePlanApproval(channelId, result);

  /// Cancel pending plan_approval for [channelId] (e.g. user explicitly stops).
  void cancelPlanApproval(String channelId) =>
      _planApprovalService.cancelPlanApproval(channelId);

  /// Close the message stream controller for a single [channelId].
  /// Use this when a ChatScreen for that channel is disposed, instead of
  /// the global [detachUI] which tears down controllers for every channel.
  void closeChannelStream(String channelId) {
    final controller = _messageControllers.remove(channelId);
    controller?.close();
  }

  /// Get message stream for a channel
  Stream<List<Message>> getMessageStream(String channelId) {
    if (!_messageControllers.containsKey(channelId)) {
      _messageControllers[channelId] = StreamController<List<Message>>.broadcast();
    }
    return _messageControllers[channelId]!.stream;
  }

  /// Send message to agent and get response
  Future<Message?> sendMessageToAgent({
    required String content,
    required RemoteAgent agent,
    required String userId,
    required String userName,
    String? channelId,
    String? replyToId,
    String? dmSystemPrompt,
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic> actionData)? onActionConfirmation,
    void Function(Map<String, dynamic> selectData)? onSingleSelect,
    void Function(Map<String, dynamic> selectData)? onMultiSelect,
    void Function(Map<String, dynamic> uploadData)? onFileUpload,
    void Function(Map<String, dynamic> formData)? onForm,
    Future<void> Function(Map<String, dynamic> fileData)? onFileMessage,
    void Function(Map<String, dynamic> metadata)? onMessageMetadata,
    void Function(Map<String, dynamic> historyRequestData)? onRequestHistory,
    Future<bool> Function(String toolName, Map<String, dynamic> args, os_exec.RiskLevel risk)? onOsToolConfirmation,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
    Message? existingUserMessage,
  }) => _agentMessagingService.sendMessageToAgent(
    content: content,
    agent: agent,
    userId: userId,
    userName: userName,
    channelId: channelId,
    replyToId: replyToId,
    dmSystemPrompt: dmSystemPrompt,
    onStreamChunk: onStreamChunk,
    onActionConfirmation: onActionConfirmation,
    onSingleSelect: onSingleSelect,
    onMultiSelect: onMultiSelect,
    onFileUpload: onFileUpload,
    onForm: onForm,
    onFileMessage: onFileMessage,
    onMessageMetadata: onMessageMetadata,
    onRequestHistory: onRequestHistory,
    onOsToolConfirmation: onOsToolConfirmation,
    acpCancellationToken: acpCancellationToken,
    attachments: attachments,
    existingUserMessage: existingUserMessage,
  );

  /// Returns the active ACP connection for [agentId], or null.
  ACPAgentConnection? getACPConnection(String agentId) =>
      _agentMessagingService.getACPConnection(agentId);

  /// Send additional history to agent as a supplement after REQUEST_HISTORY.
  /// Returns the agent's re-answer message, or null if no more history is
  /// available.  The caller receives `actualSentCount` via the returned
  /// [HistorySupplementResult] so it can update its offset correctly.
  Future<HistorySupplementResult?> sendHistorySupplement({
    required RemoteAgent agent,
    required String sessionId,
    required String requestId,
    required String originalQuestion,
    required int offset,
    required int batchSize,
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic>)? onRequestHistory,
    ACPCancellationToken? acpCancellationToken,
  }) async {
    // 1. Load ALL messages from DB so we can slice correctly.
    //    `offset` = number of most-recent messages already sent to agent.
    //    We want the `batchSize` messages right before those.
    final allMessages = await loadChannelMessages(sessionId, limit: offset + batchSize);
    // allMessages is sorted by time ascending
    final total = allMessages.length;

    // Already-sent region: the last `offset` messages (may be fewer if total < offset)
    final sentStart = (total - offset).clamp(0, total);
    // New region: up to `batchSize` messages before the already-sent ones
    final newStart = (sentStart - batchSize).clamp(0, total);
    final newEnd = sentStart;

    if (newStart >= newEnd) return null; // no more history

    final additionalMessages = allMessages.sublist(newStart, newEnd);
    final chatHistory = additionalMessages
        .where((m) => m.type == MessageType.text)
        .map((m) {
          return {
            'role': m.from.isAgent ? 'assistant' : 'user',
            'content': m.content,
          };
        })
        .toList();

    if (chatHistory.isEmpty) return null;

    return await _sendHistorySupplementViaACP(
      agent: agent,
      sessionId: sessionId,
      chatHistory: chatHistory,
      originalQuestion: originalQuestion,
      offset: offset,
      onStreamChunk: onStreamChunk,
      onRequestHistory: onRequestHistory,
      acpCancellationToken: acpCancellationToken,
    );
  }

  /// Send history supplement via ACP WebSocket protocol.
  Future<HistorySupplementResult?> _sendHistorySupplementViaACP({
    required RemoteAgent agent,
    required String sessionId,
    required List<Map<String, String>> chatHistory,
    required String originalQuestion,
    required int offset,
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic>)? onRequestHistory,
    ACPCancellationToken? acpCancellationToken,
  }) async {
    final connection = await _agentMessagingService.getOrCreateACPConnection(agent);
    final taskId = _uuid.v4();
    acpCancellationToken?.bind(connection, taskId);

    final taskCompleter = Completer<void>();
    String responseContent = '';
    Map<String, dynamic>? capturedHistoryRequest;

    // Hook cancellation token so the completer resolves immediately on cancel.
    acpCancellationToken?.onCancelled = () {
      if (!taskCompleter.isCompleted) {
        taskCompleter.complete();
      }
    };

    connection.registerTaskCallbacks(taskId, TaskCallbacks(
      onTextContent: (data) {
        final content = data['content'] as String? ?? '';
        responseContent += content;
        onStreamChunk?.call(content);
      },
      onRequestHistory: (data) {
        capturedHistoryRequest = Map<String, dynamic>.from(data);
        onRequestHistory?.call(data);
      },
      onTaskCompleted: (data) {
        if (!taskCompleter.isCompleted) taskCompleter.complete();
      },
      onTaskError: (data) {
        if (!taskCompleter.isCompleted) {
          taskCompleter.completeError(Exception(data['message'] ?? 'Task error'));
        }
      },
    ));

    await connection.sendChatMessage(
      taskId: taskId,
      sessionId: sessionId,
      message: '[HISTORY_SUPPLEMENT]',
      userId: '',
      messageId: _uuid.v4(),
      historySupplement: true,
      additionalHistory: chatHistory,
      originalQuestion: originalQuestion,
    );

    await taskCompleter.future.timeout(const Duration(seconds: 300));

    connection.unregisterTaskCallbacks(taskId);

    // If cancelled, return partial content immediately.
    if (acpCancellationToken?.isCancelled == true) {
      final responseMessage = Message(
        id: _uuid.v4(),
        content: responseContent.isNotEmpty ? responseContent : '[Stopped]',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        type: MessageType.text,
      );
      if (responseContent.isNotEmpty) {
        await _saveMessageToChannel(responseMessage, agent.id, channelId: sessionId);
      }
      return HistorySupplementResult(
        message: responseMessage,
        actualSentCount: chatHistory.length,
      );
    }

    // If the agent's entire response was a request_history directive (no text),
    // don't save a meaningless placeholder message.
    if (responseContent.isEmpty && capturedHistoryRequest != null) {
      return HistorySupplementResult(
        message: Message(
          id: _uuid.v4(),
          content: '',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          type: MessageType.text,
        ),
        actualSentCount: chatHistory.length,
        pendingHistoryRequest: capturedHistoryRequest,
      );
    }

    final responseMessage = Message(
      id: _uuid.v4(),
      content: responseContent.isNotEmpty ? responseContent : 'Task completed',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
      type: MessageType.text,
    );

    await _saveMessageToChannel(responseMessage, agent.id, channelId: sessionId);

    return HistorySupplementResult(
      message: responseMessage,
      actualSentCount: chatHistory.length,
      pendingHistoryRequest: capturedHistoryRequest,
    );
  }

  /// Submit action confirmation response
  /// Updates the original message's metadata and sends a new request to the agent.
  /// When confirmationContext is "mac_tool", the response is sent via
  /// connection.submitResponse() (in-band) rather than creating a new chat message.
  Future<Message?> submitActionConfirmationResponse({
    required Message originalMessage,
    required String confirmationId,
    required String selectedActionId,
    required String selectedActionLabel,
    required RemoteAgent agent,
    required String userId,
    required String userName,
    String? channelId,
    String? confirmationContext,
    void Function(String chunk)? onStreamChunk,
    ACPCancellationToken? acpCancellationToken,
  }) async {
    LoggerService().debug('Submitting action confirmation: id=$confirmationId, action=$selectedActionId ($selectedActionLabel), context=$confirmationContext', tag: 'ChatService');

    // Update original message's metadata in DB
    final updatedMetadata = Map<String, dynamic>.from(originalMessage.metadata ?? {});
    final actionConfirmation = Map<String, dynamic>.from(
      updatedMetadata['action_confirmation'] as Map<String, dynamic>? ?? {},
    );
    actionConfirmation['selected_action_id'] = selectedActionId;
    actionConfirmation['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    updatedMetadata['action_confirmation'] = actionConfirmation;

    await _databaseService.updateMessage(
      messageId: originalMessage.id,
      content: originalMessage.content,
      metadata: updatedMetadata,
    );

    // mac_tool confirmations: send in-band via submitResponse (no new chat message)
    if (confirmationContext == 'mac_tool') {
      final connection = _acpConnections[agent.id];
      if (connection != null && connection.isConnected) {
        final activeTask = getActiveTask(channelId ?? '');
        final taskId = activeTask?.taskId ?? '';
        await connection.submitResponse(
          taskId: taskId,
          responseType: 'action_confirmation',
          responseData: {
            'confirmation_id': confirmationId,
            'selected_action_id': selectedActionId,
            'selected_action_label': selectedActionLabel,
          },
        );
        LoggerService().debug('Sent mac_tool confirmation via submitResponse', tag: 'ChatService');
        return null; // No new message created for in-band confirmations
      }
    }

    // Default path: send the selection as a new message to the agent
    return await sendMessageToAgent(
      content: 'Selected action: $selectedActionLabel',
      agent: agent,
      userId: userId,
      userName: userName,
      channelId: channelId,
      onStreamChunk: onStreamChunk,
      acpCancellationToken: acpCancellationToken,
    );
  }

  /// Submit single-select or multi-select response
  /// Updates the original message's metadata in DB and sends a new request to the agent
  Future<Message?> submitSelectResponse({
    required Message originalMessage,
    required String metadataKey,
    required Map<String, dynamic> selectedData,
    required String responseText,
    required RemoteAgent agent,
    required String userId,
    required String userName,
    String? channelId,
    void Function(String chunk)? onStreamChunk,
    ACPCancellationToken? acpCancellationToken,
  }) async {
    LoggerService().debug('Submitting select response ($metadataKey): $responseText', tag: 'ChatService');

    // Update original message's metadata in DB
    final updatedMetadata = Map<String, dynamic>.from(originalMessage.metadata ?? {});
    final selectMeta = Map<String, dynamic>.from(
      updatedMetadata[metadataKey] as Map<String, dynamic>? ?? {},
    );
    selectMeta.addAll(selectedData);
    selectMeta['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    updatedMetadata[metadataKey] = selectMeta;

    await _databaseService.updateMessage(
      messageId: originalMessage.id,
      content: originalMessage.content,
      metadata: updatedMetadata,
    );

    // Send the selection as a new message to the agent
    return await sendMessageToAgent(
      content: responseText,
      agent: agent,
      userId: userId,
      userName: userName,
      channelId: channelId,
      onStreamChunk: onStreamChunk,
      acpCancellationToken: acpCancellationToken,
    );
  }

  /// Save message to agent channel.
  ///
  /// [channelId] should always be provided to ensure messages are saved to the
  /// correct session. The deterministic fallback is only used as a last resort
  /// for backward compatibility.
  Future<void> _saveMessageToChannel(Message message, String agentId, {String? channelId}) async {
    // Use provided channelId; fall back to the active session for this
    // user-agent pair so we don't accidentally save into the wrong session.
    final effectiveChannelId = channelId ?? await (() async {
      final otherPartyId = message.from.id == agentId ? (message.to?.id ?? message.from.id) : message.from.id;
      // Prefer the most recently active session over the deterministic channel
      final activeChannel = await getLatestActiveChannelId(otherPartyId, agentId);
      if (activeChannel != null) return activeChannel;
      return generateChannelId(otherPartyId, agentId);
    })();

    // Check if channel exists
    final existingChannel = await _databaseService.getChannelById(effectiveChannelId);

    if (existingChannel == null) {
      // Create channel if it doesn't exist
      final channel = Channel.withMemberIds(
        id: effectiveChannelId,
        name: 'Chat with ${message.from.type == 'user' ? agentId : message.from.name}',
        type: 'dm',
        memberIds: [message.from.id, agentId],
        isPrivate: true,
      );
      await _databaseService.createChannel(channel, message.from.id);
    }

    // Save message to database
    await _databaseService.createMessage(
      id: message.id,
      channelId: effectiveChannelId,
      senderId: message.from.id,
      senderType: message.from.type,
      senderName: message.from.name,
      content: message.content,
      messageType: message.type.toString().split('.').last,
      replyToId: message.replyTo,
      metadata: message.metadata,
    );

    // Update channel's updated_at so HomeScreen shows the correct active session
    await _databaseService.touchChannelUpdatedAt(effectiveChannelId);

    // 用户自己发送的消息直接标记为已读
    if (message.from.type == 'user') {
      await _databaseService.markMessageAsRead(message.id);
    }

    // Notify listeners
    _notifyChannelUpdate(effectiveChannelId);

    // Fire a local notification for non-user messages
    if (message.from.type != 'user') {
      _maybeShowNotification(
        channelId: effectiveChannelId,
        senderId: message.from.id,
        senderName: message.from.name,
        content: message.content,
      );
    }
  }

  /// Load message history for an agent.
  /// Uses the most recently active session instead of a deterministic channel
  /// to ensure messages from different sessions stay isolated.
  Future<List<Message>> loadMessageHistory({
    required String agentId,
    required String userId,
    int limit = 100,
  }) => _historyService.loadMessageHistory(agentId: agentId, userId: userId, limit: limit);

  /// Load messages from a channel
  Future<List<Message>> loadChannelMessages(String channelId, {int limit = 100}) =>
      _historyService.loadChannelMessages(channelId, limit: limit);

  /// Get channel ID for user-agent conversation
  String generateChannelId(String userId, String agentId) =>
      _sessionService.generateChannelId(userId, agentId);

  /// Notify channel update
  void _notifyChannelUpdate(String channelId) {
    _messageControllers[channelId]?.add([]);
  }

  /// Public alias for external callers (e.g. ACPServerService) that need to
  /// trigger a UI refresh after writing messages directly to the database.
  void notifyChannelUpdate(String channelId) => _notifyChannelUpdate(channelId);

  /// Show a local notification if conditions are met.
  void _maybeShowNotification({
    required String channelId,
    required String senderId,
    required String senderName,
    required String content,
  }) {
    final provider = _notificationProvider;
    if (provider == null) return;
    if (!provider.shouldNotify(senderId)) return;
    if (AppLifecycleService().shouldSuppressNotification(channelId)) return;

    final body = provider.showPreview ? content : 'New message';
    NotificationService().showNotification(
      id: channelId.hashCode,
      title: senderName,
      body: body,
      playSound: provider.soundEnabled,
    );
  }

  /// Delete chat history for an agent.
  /// Deletes the most recently active session, not just the deterministic channel.
  Future<void> deleteChatHistory({
    required String agentId,
    required String userId,
  }) => _historyService.deleteChatHistory(agentId: agentId, userId: userId);

  /// Rollback from a specific message: delete it and all subsequent messages,
  /// then notify the remote agent.
  Future<void> rollbackFromMessage({
    required String messageId,
    required String channelId,
    required RemoteAgent agent,
  }) async {
    final createdAt = await _databaseService.getMessageCreatedAt(messageId);
    if (createdAt == null) {
      throw Exception('Message not found: $messageId');
    }
    await _databaseService.deleteMessagesFromTimestamp(channelId, createdAt);

    final connection = _acpConnections[agent.id];
    if (connection != null && connection.isConnected) {
      connection.rollback(
        sessionId: channelId,
        messageId: messageId,
      ).catchError((_) => ACPResponse(jsonrpc: '2.0', id: 0));
    }
    _notifyChannelUpdate(channelId);
  }

  /// Delete a single message
  Future<void> deleteMessage(String messageId) =>
      _historyService.deleteMessage(messageId);

  /// Create a new session (channel) for user-agent conversation
  Future<String> createNewSession({
    required String userId,
    required String userName,
    required String agentId,
    required String agentName,
  }) => _sessionService.createNewSession(
    userId: userId,
    userName: userName,
    agentId: agentId,
    agentName: agentName,
  );

  /// Get the most recently active channel ID for a user-agent pair
  Future<String?> getLatestActiveChannelId(String userId, String agentId) =>
      _sessionService.getLatestActiveChannelId(userId, agentId);

  /// Get all sessions (channels) for a specific agent
  Future<List<Channel>> getAgentSessions({required String agentId}) =>
      _sessionService.getAgentSessions(agentId: agentId);

  /// Get a single message by ID, converted to Message object
  Future<Message?> getMessageById(String messageId) =>
      _historyService.getMessageById(messageId);

  /// Build a group-aware system prompt for a specific agent in a group chat.
  /// Load channel messages and truncate to fit within a character budget.
  ///
  /// Returns eligible (non-system) messages with oldest messages trimmed
  /// to stay under [maxChars] total characters. If [excludeMessageId] is
  /// provided, that message is removed from the result (useful when the
  /// message will be sent separately as the direct content parameter).
  Future<List<Message>> _loadAndTruncateHistory(String channelId, {int maxChars = 60000, int limit = 100, String? excludeMessageId}) =>
      _historyService.loadAndTruncateHistory(channelId, maxChars: maxChars, limit: limit, excludeMessageId: excludeMessageId);

  /// Notify group members about a membership change (join/leave).
  ///
  /// Persists a system message, refreshes the UI stream, and sends an ACP
  /// push notification to every connected remote agent still in the group.
  /// Returns the system [Message] so the caller can insert it into the UI.
  Future<Message> notifyGroupMembershipChange(
    String channelId,
    String memberId,
    String memberName, {
    required bool isJoin,
  }) => _groupInteractionHandler.notifyGroupMembershipChange(
    channelId, memberId, memberName, isJoin: isJoin,
  );

  /// Send a message to a group channel, orchestrating agent responses.
  ///
  /// When [adminAgentId] is set and the user hasn't @mentioned specific agents,
  /// only the admin responds first.  If the admin @mentions other members in its
  /// reply, those members are launched in a second round.  When no admin is set,
  /// all agents respond concurrently (backward-compatible behavior).
  Future<void> sendMessageToGroup({
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required List<String> agentIds,
    List<String> mentionedAgentIds = const [],
    bool mentionOnlyMode = false,
    String? adminAgentId,
    String? replyToId,
    bool planningMode = false,
    bool flowMode = false,
    Map<String, dynamic>? userMessageMetadata,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
    Future<Map<String, dynamic>?> Function(
      String agentId, String agentName, String interactionType, Map<String, dynamic> data,
    )? onInteractionRequest,
  }) => _groupOrchestrationService.sendMessageToGroup(
    channelId: channelId,
    content: content,
    userId: userId,
    userName: userName,
    agentIds: agentIds,
    mentionedAgentIds: mentionedAgentIds,
    mentionOnlyMode: mentionOnlyMode,
    adminAgentId: adminAgentId,
    replyToId: replyToId,
    planningMode: planningMode,
    flowMode: flowMode,
    userMessageMetadata: userMessageMetadata,
    acpCancellationToken: acpCancellationToken,
    onStreamChunk: onStreamChunk,
    onAgentStart: onAgentStart,
    onAgentDone: onAgentDone,
    onAllDone: onAllDone,
    onInteractionRequest: onInteractionRequest,
  );

  /// Resume the active FlowExecutor for the given channel after the user has
  /// submitted a form or file-upload interaction triggered by a flow step.
  void resumeFlowInteraction(String channelId, Map<String, dynamic>? result) {
    _activeFlowExecutors[channelId]?.resumeWithInteractionResult(result);
  }

  /// Create a new group session with the same members and name as the original group.
  Future<String> createNewGroupSession({
    required String channelId,
    required String userId,
  }) => _groupSessionService.createNewGroupSession(channelId: channelId, userId: userId);

  /// Get all sessions for a group (by parentGroupId).
  Future<List<Channel>> getGroupSessions({required String parentGroupId}) =>
      _groupSessionService.getGroupSessions(parentGroupId: parentGroupId);

  /// Clear current group session history: send /reset to all connected agents, delete messages.
  Future<void> clearGroupSessionHistory({
    required String channelId,
    required List<String> agentIds,
  }) => _groupSessionService.clearGroupSessionHistory(channelId: channelId, agentIds: agentIds);

  /// Clear all group sessions: send /reset to all connected agents, delete all session messages.
  Future<void> clearAllGroupSessions({
    required String parentGroupId,
    required String currentChannelId,
    required List<String> agentIds,
  }) => _groupSessionService.clearAllGroupSessions(
    parentGroupId: parentGroupId,
    currentChannelId: currentChannelId,
    agentIds: agentIds,
  );

  /// 页面退出时调用，仅关闭 UI 流，ACP 连接保持存活
  void detachUI() {
    for (final controller in _messageControllers.values) {
      controller.close();
    }
    _messageControllers.clear();

    // Detach UI callbacks from active tasks but keep them running
    for (final task in _activeTasks.values) {
      task.detachUI();
    }

    // Detach UI callbacks from active group tasks
    for (final agentMap in _activeGroupTasks.values) {
      for (final task in agentMap.values) {
        task.detachUI();
      }
    }
  }

  /// Check if an existing ACP connection for [agentId] is alive.
  ///
  /// Returns `true` if there is a connected, authenticated connection and
  /// a ping succeeds.  Returns `false` otherwise (no connection, not
  /// connected, ping failed).  Does NOT create a new connection.
  Future<bool> pingAgent(String agentId) async {
    final connection = _acpConnections[agentId];
    if (connection == null || !connection.isConnected) return false;

    try {
      final resp = await connection.ping().timeout(const Duration(seconds: 5));
      return resp.isSuccess;
    } catch (_) {
      return false;
    }
  }

  /// 完整清理（App 退出时调用）
  void dispose() {
    detachUI();

    // Clean up ACP connections
    for (final connection in _acpConnections.values) {
      connection.dispose();
    }
    _acpConnections.clear();
  }

}
