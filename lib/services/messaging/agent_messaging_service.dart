import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/llm_token_usage.dart';
import '../../models/inference_log_entry.dart';
import '../../models/tool_execution_result.dart';
import '../local_database_service.dart';
import '../tool_result_database_service.dart';
import '../acp_agent_connection.dart';
import '../agent_prompt_builder.dart';
import '../local_llm_agent_service.dart';
import '../task/task_models.dart';
import '../../clis/shepaw/os/os_executor.dart' as os_exec;
import '../../clis/shepaw/os/os_tool_registry.dart';
import '../skill_registry.dart';
import '../model_registry.dart';
import '../ui_component_registry.dart';
import '../inference_log_service.dart';
import '../trace_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../peer_key_utils.dart';
import '../she_service.dart';
import '../agent_soul_service.dart';
import '../noise_identity.dart';
import '../mailbox/mailbox_seal.dart';
import '../mailbox/channel_mailbox_service.dart';
import '../mailbox/mailbox_inbox_poller.dart';
import '../mailbox/mailbox_turn_claims.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../group/group_orchestration_tools.dart';
import '../session/session_history_service.dart';
import '../session/history_compactor.dart';
import '../session/history_compaction_cache_service.dart';
import '../remote_agent_service.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/services/peer_inflight_turn.dart';
import '../../peer/services/peer_agent_host_service.dart' show isPeerAgentChannel;
import '../../models/peer_boundary_config.dart';
import '../../service_locator.dart' show getIt;
import 'local_llm_handler.dart';
import 'message_implicit_prompt.dart';
import 'stream_content_splitter.dart';
import 'streaming_flush_helper.dart';
import 'connection_retry_policy.dart';

export 'streaming_flush_helper.dart'
    show kDefaultFlushIntervalMs, kDefaultContentThreshold;

/// Internal sentinel returned by [AgentMessagingService._sendViaACPProtocol]
/// when the agent advertised the `async_confirmation` capability.
///
/// In async mode, `_sendViaACPProtocol` does NOT await `task.completed` — it
/// returns as soon as `sendChatMessage` completes, and relies on callback-
/// driven persistence (the `onTaskCompleted` / `onTaskError` callbacks
/// registered with the connection handle DB save + cleanup themselves).
///
/// `sendMessageToAgent` checks this sentinel and skips the outer DB save +
/// `_activeTasks` cleanup (both already owned by the callbacks).
const _asyncPendingSentinelMetadataKey = '__shepaw_async_pending__';

bool _isAsyncPendingSentinel(Message? m) =>
    m != null && m.metadata?[_asyncPendingSentinelMetadataKey] == true;

/// 单个 1:1 agent 回合的终态。
enum AgentTaskOutcome { completed, error, stopped }

/// 1:1 agent 回合到达终态（最终消息已持久化）后的广播载荷。
///
/// 供 [DispatchService] 之类的编排方闭环使用；UI 仍走
/// ActiveTask / dbSaveCompleter，不应消费此流。
class AgentTaskCompletion {
  final String channelId;
  final String agentId;
  final String agentName;

  /// 最终消息；纯发送失败（未产生回复）时为 null。
  /// 其 `replyTo` 指向触发本回合的用户消息 id，可用于精确归因。
  final Message? finalMessage;
  final AgentTaskOutcome outcome;
  final String? errorMessage;

  const AgentTaskCompletion({
    required this.channelId,
    required this.agentId,
    required this.agentName,
    required this.outcome,
    this.finalMessage,
    this.errorMessage,
  });
}


/// Handles sending messages to individual (non-group) agents.
///
/// Extracted from [ChatService] to isolate the 1:1 agent messaging paths:
/// ACP WebSocket, generic HTTP, and local LLM (single-round and multi-round).
class AgentMessagingService {
  final LocalDatabaseService _db;
  final ToolResultDatabaseService _toolResultDb;
  final Uuid _uuid;
  final Map<String, ACPAgentConnection> _acpConnections;
  final Map<String, ActiveTask> _activeTasks;
  final Future<void> Function(Message message, String agentId, {String? channelId}) saveMessageToChannel;
  final void Function() updateTypingAgentIds;
  final void Function(String agentName) releaseForegroundTask;
  final Future<List<Message>> Function(String channelId, {int limit}) loadChannelMessages;
  final Future<Message?> Function(String id) getMessageById;

  AgentMessagingService({
    required LocalDatabaseService db,
    required ToolResultDatabaseService toolResultDb,
    required Uuid uuid,
    required Map<String, ACPAgentConnection> acpConnections,
    required Map<String, ActiveTask> activeTasks,
    required this.saveMessageToChannel,
    required this.updateTypingAgentIds,
    required this.releaseForegroundTask,
    required this.loadChannelMessages,
    required this.getMessageById,
  })  : _db = db,
        _toolResultDb = toolResultDb,
        _uuid = uuid,
        _acpConnections = acpConnections,
        _activeTasks = activeTasks;

  final Map<String, ({
    PeerInflightTurnRecord rec,
    RemoteAgent agent,
    StreamContentSplitter splitter,
    StreamingFlushHelper flushHelper,
  })> _restoredPeerCtx = {};

  /// Channels whose DM task was finalized early by an explicit user stop.
  /// Guards background send / async-finalize paths against duplicate DB saves.
  final Set<String> _userStoppedChannels = {};

  // ---------------------------------------------------------------------------
  // Task-completion broadcast
  // ---------------------------------------------------------------------------

  final StreamController<AgentTaskCompletion> _completionController =
      StreamController<AgentTaskCompletion>.broadcast();

  /// 每个 1:1 agent 回合到达终态（成功/失败/停止，最终消息已落库）后广播。
  /// 编排方（DispatchService）订阅此流闭环；无监听时零开销。
  Stream<AgentTaskCompletion> get completionStream => _completionController.stream;

  void _emitCompletion({
    required String channelId,
    required RemoteAgent agent,
    required AgentTaskOutcome outcome,
    Message? finalMessage,
    String? errorMessage,
  }) {
    if (channelId.isEmpty || !_completionController.hasListener) return;
    _completionController.add(AgentTaskCompletion(
      channelId: channelId,
      agentId: agent.id,
      agentName: agent.name,
      outcome: outcome,
      finalMessage: finalMessage,
      errorMessage: errorMessage,
    ));
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Recreate [ActiveTask]s for peer turns hydrated after a process kill so
  /// the chat UI can reattach and the resume path can persist the final
  /// message. Safe to call more than once.
  Future<void> restorePeerInflightTurns() async {
    final client = PeerAgentClientService.instance;
    final turns = client.snapshotInflightTurns();
    try {
      for (final rec in turns) {
        if (rec.channelId.isEmpty || rec.localAgentId.isEmpty) continue;
        if (_activeTasks.containsKey(rec.channelId)) continue;
        await _prepareRestoredPeerTurn(rec);
      }
    } finally {
      // Handlers must be attached before resume: a finished turn answers `done`
      // immediately and would otherwise complete with nobody listening.
      client.resumeHydratedTurns();
    }
    for (final rec in turns) {
      if (_activeTasks[rec.channelId]?.taskId != rec.requestId) continue;
      unawaited(_awaitRestoredPeerTurn(rec));
    }
  }

  Future<void> _prepareRestoredPeerTurn(PeerInflightTurnRecord rec) async {
    final agent = await _db.getRemoteAgentById(rec.localAgentId);
    if (agent == null || !agent.isPeerAgent) {
      LoggerService().warning(
        'Cannot restore peer turn ${rec.requestId}: agent ${rec.localAgentId} missing',
        tag: 'AgentMessagingService',
      );
      return;
    }
    final channel = await _db.getChannelById(rec.channelId);
    if (channel != null && channel.isGroup) {
      return;
    }

    final activeTask = ActiveTask(
      taskId: rec.requestId,
      agentId: agent.id,
      agentName: rec.agentName.isNotEmpty ? rec.agentName : agent.name,
      channelId: rec.channelId,
      userMessageId: rec.userMessageId,
      userId: rec.userId,
      userName: rec.userName,
    );
    activeTask.accumulatedContent = rec.accumulatedContent;
    var partialMessageId = rec.partialMessageId;
    if (partialMessageId == null || partialMessageId.isEmpty) {
      // 记录里没带 partial id（老版本写入的 inflight 行、或 flush 恰好还没
      // 跑过）：收养同会话同 agent 最近的 streaming 半成品行。DM 会话同一
      // channel 只可能存在一个在途 turn（PeerTurnInFlightException 保证），
      // 收养是安全的；完成时 deletePartial 才能删掉杀进程前那行，避免
      // 「半成品 + 完整消息」两条并存。
      partialMessageId = await _db.findLatestStreamingPartialMessageId(
        channelId: rec.channelId,
        senderId: agent.id,
      );
    }
    activeTask.partialMessageId = partialMessageId;
    activeTask.metadata = {
      'request_id': rec.requestId,
      'peer_id': rec.peerId,
      'remote_agent_id': rec.remoteAgentId,
      'peer_session_id': rec.sessionId,
      'user_message_id': rec.userMessageId,
      'restored_inflight': true,
    };
    _activeTasks[rec.channelId] = activeTask;
    updateTypingAgentIds();
    ForegroundTaskService().acquireTask(activeTask.agentName);

    final splitter = StreamContentSplitter();
    splitter.answerContent = rec.accumulatedContent;
    final flushHelper = StreamingFlushHelper.fromAgent(
      db: _db,
      activeTask: activeTask,
      agent: agent,
      channelId: rec.channelId,
      replyToId: rec.userMessageId,
      traceId: rec.requestId,
      onFlushed: (messageId) {
        PeerAgentClientService.instance
            .noteInflightPartialMessageId(rec.requestId, messageId);
      },
    );
    _restoredPeerCtx[rec.requestId] = (
      rec: rec,
      agent: agent,
      splitter: splitter,
      flushHelper: flushHelper,
    );

    PeerAgentClientService.instance.attachPendingHandlers(
      rec.requestId,
      onChunk: (chunk) {
        final answerDelta = splitter.onChunk(chunk);
        if (answerDelta.isNotEmpty) {
          activeTask.accumulatedContent += answerDelta;
          PeerAgentClientService.instance.noteInflightAnswer(
            rec.requestId,
            activeTask.accumulatedContent,
          );
          activeTask.onStreamChunk?.call(answerDelta);
          flushHelper.schedule();
        } else {
          final progressMeta = splitter.progressMetadataDelta();
          if (progressMeta != null) {
            final merged = Map<String, dynamic>.from(activeTask.metadata ?? {});
            merged.addAll(progressMeta);
            activeTask.metadata = merged;
            activeTask.onMessageMetadata?.call(progressMeta);
          }
        }
      },
      onMetadata: (data) {
        final merged = Map<String, dynamic>.from(activeTask.metadata ?? {});
        merged.addAll(splitter.onMetadata(data));
        activeTask.metadata = merged;
        activeTask.onMessageMetadata?.call(data);
      },
      onActionConfirmation: (data) {
        final meta = Map<String, dynamic>.from(activeTask.metadata ?? {});
        meta['action_confirmation'] = Map<String, dynamic>.from(data);
        activeTask.metadata = meta;
        activeTask.onActionConfirmation?.call(data);
      },
    );
  }

  Future<void> _awaitRestoredPeerTurn(PeerInflightTurnRecord rec) async {
    final ctx = _restoredPeerCtx.remove(rec.requestId);
    final activeTask = _activeTasks[rec.channelId];
    if (ctx == null || activeTask == null) return;
    final splitter = ctx.splitter;
    final flushHelper = ctx.flushHelper;
    final agent = ctx.agent;

    try {
      final result = await PeerAgentClientService.instance
          .awaitPendingTurn(rec.requestId);
      if (activeTask.isComplete) return;

      activeTask.isComplete = true;
      activeTask.onTaskFinished?.call();

      final content = buildPeerFinalContent(
        answerContent: splitter.answerContent,
        progressContent: splitter.progressContent,
        accumulatedContent: activeTask.accumulatedContent,
        resultContent: result.content,
        wasCancelled: result.content.contains('[Stopped]'),
      );
      final meta = Map<String, dynamic>.from(activeTask.metadata ?? {});
      meta['request_id'] = rec.requestId;
      if (result.metadata != null) meta.addAll(result.metadata!);
      meta.addAll(splitter.finalProgressMetadata());
      meta.remove('restored_inflight');

      await flushHelper.deletePartial();
      final msg = Message(
        id: _uuid.v4(),
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(id: rec.userId, type: 'user', name: rec.userName),
        type: MessageType.text,
        replyTo: rec.userMessageId.isEmpty ? null : rec.userMessageId,
        metadata: meta,
      );
      final toSave = await _dedupeAgainstSyncedTranscript(msg, rec.channelId);
      if (toSave != null) {
        await saveMessageToChannel(toSave, agent.id, channelId: rec.channelId);
      }
      _emitCompletion(
        channelId: rec.channelId,
        agent: agent,
        outcome: AgentTaskOutcome.completed,
        finalMessage: toSave,
      );
    } catch (e, st) {
      LoggerService().error(
        'Restored peer turn ${rec.requestId} failed: $e',
        tag: 'AgentMessagingService',
        error: e,
        stackTrace: st,
      );
      await flushHelper.deletePartial();
      activeTask.isComplete = true;
      activeTask.onTaskFinished?.call();
    } finally {
      flushHelper.cancel();
      final removed = _activeTasks.remove(rec.channelId);
      if (removed != null) {
        updateTypingAgentIds();
        releaseForegroundTask(removed.agentName);
        if (!removed.dbSaveCompleter.isCompleted) {
          removed.dbSaveCompleter.complete();
        }
      }
    }
  }

  /// Force-stop the in-flight 1:1 task for [channelId]: mark complete
  /// synchronously (prevents reattach), persist `[Stopped]` to DB, and
  /// release foreground/typing state.
  Future<void> finalizeActiveDmTaskAsStopped({
    required String channelId,
    String? contentOverride,
  }) async {
    // 中断 peer 侧仍在运行的 turn 并解除 inflight 发送拦截。必须放在
    // ActiveTask 检查之前：controller 的 cancel token 在页面 reattach /
    // 进程重启后与该 turn 失联（reattachToActiveTask 会新建空 token），
    // 且 restored turn 可能没有对应 ActiveTask —— 仅取消 token 不足以
    // 触达 PeerAgentClientService._pending。
    unawaited(
      PeerAgentClientService.instance.cancelInflightTurnsForChannel(channelId),
    );

    final task = _activeTasks[channelId];
    if (task == null || task.isComplete) return;

    // Sync — must run before the first await so `unawaited(...)` from the UI
    // blocks reattach/typing immediately.
    task.isComplete = true;
    task.recordInterruption('user_cancelled');
    task.detachUI();
    _userStoppedChannels.add(channelId);
    updateTypingAgentIds();

    final content = buildPeerFinalContent(
      answerContent: contentOverride ?? '',
      progressContent: '',
      accumulatedContent: task.accumulatedContent,
      resultContent: '[Stopped]',
      wasCancelled: true,
    );

    final partialId = task.partialMessageId;
    if (partialId != null) {
      try {
        await _db.deleteMessage(partialId);
      } catch (e) {
        LoggerService().warning(
          'Failed to delete partial message on user stop ($partialId)',
          tag: 'AgentMessagingService',
          error: e,
        );
      }
      task.partialMessageId = null;
    }

    final meta = Map<String, dynamic>.from(task.metadata ?? {});
    meta['status'] = 'stopped';
    meta['interruption_reason'] = 'user_cancelled';
    if (meta['trace_id'] == null) meta['trace_id'] = task.taskId;

    final msg = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: task.agentId, type: 'agent', name: task.agentName),
      to: MessageFrom(id: task.userId, type: 'user', name: task.userName),
      type: MessageType.text,
      replyTo: task.userMessageId,
      metadata: meta,
    );

    try {
      await saveMessageToChannel(msg, task.agentId, channelId: channelId);
      final agent = await _db.getRemoteAgentById(task.agentId);
      if (agent != null) {
        _emitCompletion(
          channelId: channelId,
          agent: agent,
          outcome: AgentTaskOutcome.stopped,
          finalMessage: msg,
        );
      }
    } catch (e, st) {
      LoggerService().error(
        'Failed to persist user-stopped DM task for $channelId',
        tag: 'AgentMessagingService',
        error: e,
        stackTrace: st,
      );
    } finally {
      _activeTasks.remove(channelId);
      releaseForegroundTask(task.agentName);
      if (!task.dbSaveCompleter.isCompleted) {
        task.dbSaveCompleter.complete();
      }
    }
  }

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
    /// 工作流计划创建回调（She 在 DM 中调用 `shepaw workflow create` 成功后触发）。
    void Function(String workflowId, Map<String, dynamic> planData)? onWorkflowPlanCreated,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
    Message? existingUserMessage,
    /// 主动重连进度回调：`(attempt, total)`。
    /// - `attempt > 0`：正在进行第 `attempt` 次（共 `total` 次）重连尝试。
    /// - `attempt == 0`：重连流程结束（连上或彻底失败），UI 可隐藏进度提示。
    /// 仅在 ACP 协议下、首次建连/复用失败进入重试循环时触发。
    void Function(int attempt, int total)? onReconnecting,
    /// When true (default), thinking/tool text is folded into
    /// `metadata.progress_content` and only the answer is streamed as content.
    /// Peer host relay must set false so the phone client can split once.
    bool foldProgressContent = true,
    /// Extra OpenAI/Claude tool defs (e.g. group_dispatch for peer-hosted admin).
    List<Map<String, dynamic>>? extraTools,
  }) async {
    LoggerService().debug('sendMessageToAgent: agentId=${agent.id}, name=${agent.name}, protocol=${agent.protocol}, status=${agent.status}, endpoint=${agent.endpoint}', tag: 'AgentMessagingService');

    try {
      // Check if this is a local LLM agent — bypass status/endpoint checks
      if (agent.isLocal) {
        LoggerService().debug('Detected local LLM agent, using local LLM path', tag: 'AgentMessagingService');
        return await _sendViaLocalLLM(
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
          onWorkflowPlanCreated: onWorkflowPlanCreated,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
          existingUserMessage: existingUserMessage,
          extraTools: extraTools,
        );
      }

      // Check if agent is online (soft gate).
      // 本地缓存状态可能过期（Agent 刚上线但本地未更新），因此这里只记日志、
      // 不抛异常；真正的可达性由 _getOrCreateACPConnectionWithRetry 在建连时
      // 决定（并带 3 次指数退避 + checkAgentHealth 兜底）。
      if (agent.status != AgentStatus.online) {
        LoggerService().warning(
          'Agent ${agent.name} cached status=${agent.status}; will attempt reconnect on send',
          tag: 'AgentMessagingService',
        );
      } else {
        LoggerService().info('Agent is online', tag: 'AgentMessagingService');
      }

      // Check if agent has valid endpoint
      if (agent.endpoint.isEmpty) {
        LoggerService().error('Agent ${agent.name} has no valid endpoint', tag: 'AgentMessagingService');
        throw Exception('Agent ${agent.name} has no valid endpoint');
      }
      LoggerService().info('Endpoint is valid', tag: 'AgentMessagingService');

      // Create user message (skip if pre-existing attachment message provided)
      Message userMessage;
      if (existingUserMessage != null) {
        userMessage = existingUserMessage;
        LoggerService().debug('Using existing user message: ${userMessage.id}', tag: 'AgentMessagingService');
      } else {
        userMessage = Message(
          id: _uuid.v4(),
          content: content,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(
            id: userId,
            type: 'user',
            name: userName,
          ),
          to: MessageFrom(
            id: agent.id,
            type: 'agent',
            name: agent.name,
          ),
          type: MessageType.text,
          replyTo: replyToId,
          metadata: MessageImplicitPrompt.metadataForTurn(
            text: content,
            attachments: attachments,
          ),
        );

        LoggerService().debug('Created user message: ${userMessage.id}', tag: 'AgentMessagingService');

        // Save user message to database
        await saveMessageToChannel(userMessage, agent.id, channelId: channelId);
        LoggerService().debug('User message saved to database', tag: 'AgentMessagingService');
      }

      // Resolve quoted message content so agent understands reply context
      Message messageToSend = userMessage;
      if (replyToId != null) {
        final quotedMsg = await getMessageById(replyToId);
        if (quotedMsg != null) {
          messageToSend = Message(
            id: userMessage.id,
            content: '[引用 ${quotedMsg.from.name} 的消息: "${quotedMsg.content}"]\n\n${userMessage.content}',
            timestampMs: userMessage.timestampMs,
            from: userMessage.from,
            to: userMessage.to,
            type: userMessage.type,
            replyTo: userMessage.replyTo,
          );
        }
      }

      // Send message to agent based on protocol
      Message? agentResponse;
      LoggerService().debug('Preparing to send message via ${agent.protocol} protocol', tag: 'AgentMessagingService');

      // Channel 接入后：离线或繁忙不把全文塞进设备级 tunnel，只投收件箱；
      // 元信息由 channel 经 tunnel `mail_waiting` 推给接收端，回复同样走 inbox。
      if (ChannelMailboxService.agentHasChannelInbox(agent)) {
        agentResponse = await _tryChannelInboxRoute(
          agent: agent,
          userMessage: messageToSend,
          sessionId: channelId,
          onStreamChunk: onStreamChunk,
        );
      }

      if (agentResponse == null && agent.protocol == ProtocolType.peer) {
        LoggerService().debug('Using peer protocol', tag: 'AgentMessagingService');
        agentResponse = await _sendViaPeerProtocol(
          messageToSend, agent,
          onStreamChunk: onStreamChunk,
          onActionConfirmation: onActionConfirmation,
          onMessageMetadata: onMessageMetadata,
          sessionId: channelId,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
        );
      } else if (agentResponse == null && agent.protocol == ProtocolType.acp) {
        LoggerService().debug('Using ACP protocol', tag: 'AgentMessagingService');
        agentResponse = await _sendViaACPProtocol(
          messageToSend, agent,
          onStreamChunk: onStreamChunk,
          onActionConfirmation: onActionConfirmation,
          onSingleSelect: onSingleSelect,
          onMultiSelect: onMultiSelect,
          onFileUpload: onFileUpload,
          onForm: onForm,
          onFileMessage: onFileMessage,
          onMessageMetadata: onMessageMetadata,
          onRequestHistory: onRequestHistory,
          sessionId: channelId,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
          dmSystemPrompt: dmSystemPrompt,
          onReconnecting: onReconnecting,
          foldProgressContent: foldProgressContent,
        );
      } else if (agentResponse == null) {
        // For other protocols, use generic HTTP POST
        LoggerService().debug('Using generic protocol', tag: 'AgentMessagingService');
        agentResponse = await _sendViaGenericProtocol(messageToSend, agent);
      }

      // Save agent response if received
      if (_isAsyncPendingSentinel(agentResponse)) {
        // Async-confirmation path: _sendViaACPProtocol handed off DB save +
        // cleanup to the TaskCallbacks registered on the connection. The
        // outer flow returns immediately — the UI continues receiving
        // ui.* notifications until task.completed fires, at which point the
        // callback saves the final message and completes dbSaveCompleter.
        LoggerService().debug(
          'Async-confirmation path: returning without awaiting task.completed '
          '(DB save + cleanup deferred to TaskCallbacks)',
          tag: 'AgentMessagingService',
        );
        return null;
      }

      if (channelId != null && _userStoppedChannels.remove(channelId)) {
        LoggerService().debug(
          'Skipping agent response save — channel finalized by user stop',
          tag: 'AgentMessagingService',
        );
        final task = _activeTasks.remove(channelId);
        updateTypingAgentIds();
        if (task != null) {
          releaseForegroundTask(task.agentName);
          if (!task.dbSaveCompleter.isCompleted) {
            task.dbSaveCompleter.complete();
          }
        }
        return agentResponse;
      }

      if (agentResponse != null) {
        LoggerService().info('Received agent response: ${agentResponse.id}', tag: 'AgentMessagingService');
        LoggerService().debug('Response content: ${agentResponse.content}', tag: 'AgentMessagingService');
        await saveMessageToChannel(agentResponse, agent.id, channelId: channelId);
        LoggerService().debug('Agent response saved to database', tag: 'AgentMessagingService');
      } else {
        LoggerService().warning('No agent response received', tag: 'AgentMessagingService');
      }

      // Signal the active task that DB save is done, then clean up
      if (channelId != null) {
        final task = _activeTasks.remove(channelId);
        updateTypingAgentIds();
        if (task != null) {
          releaseForegroundTask(task.agentName);
          if (!task.dbSaveCompleter.isCompleted) {
            task.dbSaveCompleter.complete();
          }
        }
        _emitCompletion(
          channelId: channelId,
          agent: agent,
          outcome: AgentTaskOutcome.completed,
          finalMessage: agentResponse,
        );
      }

      return agentResponse;
    } catch (e, stackTrace) {
      LoggerService().error('Failed to send message', tag: 'AgentMessagingService', error: e, stackTrace: stackTrace);

      // Create error message
      final errorMessage = Message(
        id: _uuid.v4(),
        content: 'Error: Failed to send message to ${agent.name}. Details: $e',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(
          id: 'system',
          type: 'system',
          name: 'System',
        ),
        type: MessageType.system,
      );
      await saveMessageToChannel(errorMessage, agent.id, channelId: channelId);

      // Signal the active task that DB save is done (even on error), then clean up
      if (channelId != null) {
        final task = _activeTasks.remove(channelId);
        updateTypingAgentIds();
        if (task != null) {
          releaseForegroundTask(task.agentName);
          if (!task.dbSaveCompleter.isCompleted) {
            task.dbSaveCompleter.complete();
          }
        }
        _emitCompletion(
          channelId: channelId,
          agent: agent,
          outcome: AgentTaskOutcome.error,
          errorMessage: e.toString(),
        );
      }
      // Rethrow so ChatController can show a toast; the system message above
      // remains for in-thread history.
      rethrow;
    }
  }

  /// Get the active ACP connection for a given agent ID, or null.
  ACPAgentConnection? getACPConnection(String agentId) {
    final conn = _acpConnections[agentId];
    return (conn != null && conn.isConnected) ? conn : null;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Race guard for peer DM turns finalizing concurrently with a history sync.
  ///
  /// The sync's per-channel inflight guard lapses the moment the turn leaves
  /// `PeerAgentClientService._pending`, which is before this side persists the
  /// final message. A sync landing in that window upserts remote-owned
  /// `peerhist_*` rows and deletes the local user message (content match) —
  /// then saving [msg] would duplicate the reply and leave its replyTo
  /// dangling ("原消息不可用" quote header).
  ///
  /// Resolution: when the anchor user message no longer exists, the turn was
  /// superseded by a sync. If an equivalent remote-owned agent row already
  /// exists in the channel, suppress the save (return null). Otherwise keep
  /// the local message but strip the dangling replyTo.
  Future<Message?> _dedupeAgainstSyncedTranscript(
    Message msg,
    String channelId,
  ) async {
    final anchorId = msg.replyTo;
    if (channelId.isEmpty || anchorId == null || anchorId.isEmpty) return msg;
    try {
      final anchor = await getMessageById(anchorId);
      if (anchor != null) return msg; // no sync interference
      final recent = await loadChannelMessages(channelId, limit: 50);
      for (final m in recent) {
        if (!m.from.isAgent || !m.id.startsWith('peerhist_')) continue;
        if (peerSyncedRowCoversFinalContent(m.content, msg.content)) {
          LoggerService().info(
            'Suppressed local final save in $channelId — turn already mirrored '
            'by synced row ${m.id}',
            tag: 'AgentMessagingService',
          );
          return null;
        }
      }
      // Keep the local reply (remote transcript lacks it) but drop the
      // dangling quote reference.
      return Message(
        id: msg.id,
        content: msg.content,
        timestampMs: msg.timestampMs,
        from: msg.from,
        to: msg.to,
        type: msg.type,
        channelId: msg.channelId,
        metadata: msg.metadata,
      );
    } catch (e) {
      LoggerService().warning(
        'Synced-transcript dedupe failed for $channelId: $e',
        tag: 'AgentMessagingService',
        error: e,
      );
      return msg;
    }
  }

  /// Send message via ACP WebSocket protocol
  Future<Message?> _sendViaACPProtocol(Message userMessage, RemoteAgent agent, {
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic> actionData)? onActionConfirmation,
    void Function(Map<String, dynamic> selectData)? onSingleSelect,
    void Function(Map<String, dynamic> selectData)? onMultiSelect,
    void Function(Map<String, dynamic> uploadData)? onFileUpload,
    void Function(Map<String, dynamic> formData)? onForm,
    Future<void> Function(Map<String, dynamic> fileData)? onFileMessage,
    void Function(Map<String, dynamic> metadata)? onMessageMetadata,
    void Function(Map<String, dynamic> historyRequestData)? onRequestHistory,
    String? sessionId,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
    String? dmSystemPrompt,
    void Function(int attempt, int total)? onReconnecting,
    bool foldProgressContent = true,
  }) async {
    LoggerService().info('Starting ACP WebSocket protocol, endpoint: ${agent.endpoint}', tag: 'AgentMessagingService');

    ACPAgentConnection? connection;
    String? taskId;
    late ActiveTask activeTask;
    StreamingFlushHelper? flushHelper;

    try {
      // Get or create connection for this agent (with retry + backoff + health fallback)
      try {
        connection = await _getOrCreateACPConnectionWithRetry(
          agent,
          onReconnecting: onReconnecting,
        );
      } catch (e) {
        if (ChannelMailboxService.agentHasChannelInbox(agent) &&
            isRetriableConnectionError(e)) {
          LoggerService().info(
            'ACP unreachable after retries; leaving mailbox: $e',
            tag: 'AgentMessagingService',
          );
          return leaveMailboxAndCollect(
            agent: agent,
            userMessage: userMessage,
            sessionId: sessionId ?? '',
            requestId: _uuid.v4(),
            chatHistory: await _mailboxHistoryForSession(
              sessionId,
              excludeMessageId: userMessage.id,
            ),
            onStreamChunk: onStreamChunk,
          );
        }
        rethrow;
      }

      // Create task ID
      taskId = _uuid.v4();

      // Bind cancellation token
      acpCancellationToken?.bind(connection, taskId);

      // Create ActiveTask for background tracking
      final effectiveChannelId = sessionId ?? '';
      activeTask = ActiveTask(
        taskId: taskId,
        agentId: agent.id,
        agentName: agent.name,
        channelId: effectiveChannelId,
        userMessageId: userMessage.id,
        userId: userMessage.from.id,
        userName: userMessage.from.name,
      );

      // Attach initial UI callbacks
      activeTask.onStreamChunk = onStreamChunk;
      activeTask.onActionConfirmation = onActionConfirmation;
      activeTask.onSingleSelect = onSingleSelect;
      activeTask.onMultiSelect = onMultiSelect;
      activeTask.onFileUpload = onFileUpload;
      activeTask.onForm = onForm;
      activeTask.onFileMessage = onFileMessage;
      activeTask.onMessageMetadata = onMessageMetadata;
      activeTask.onRequestHistory = onRequestHistory;

      // Register active task
      if (effectiveChannelId.isNotEmpty) {
        _activeTasks[effectiveChannelId] = activeTask;
        updateTypingAgentIds();
      }
      ForegroundTaskService().acquireTask(agent.name);

      // Declare effectiveTaskId early so flush functions can reference it
      final effectiveTaskId = taskId;

      flushHelper = StreamingFlushHelper.fromAgent(
        db: _db,
        activeTask: activeTask,
        agent: agent,
        channelId: effectiveChannelId,
        replyToId: userMessage.id,
        traceId: effectiveTaskId,
      );

      // Begin trace for remote ACP agent
      final infLogAcp = InferenceLogService.instance;
      infLogAcp.beginSession(
        sessionId: taskId,
        agentId: agent.id,
        agentName: agent.name,
        channelId: effectiveChannelId.isNotEmpty ? effectiveChannelId : null,
        executionMode: 'remote_acp',
        userMessage: userMessage.content,
      );
      // Load history before beginning round so it can be recorded in the trace.
      // Exclude the current user message to avoid duplication
      // (the agent receives it separately via the `message` parameter).
      // Include attachment messages (image/audio/file) so agent has context.
      List<Map<String, dynamic>>? chatHistory;
      int? totalMessageCount;
      if (sessionId != null) {
        final messages = await loadChannelMessages(sessionId, limit: 40);
        if (messages.isNotEmpty) {
          chatHistory = messages
              .where((m) => m.type != MessageType.system && m.type != MessageType.permissionAudit && m.id != userMessage.id)
              .map((m) {
                final isAgent = m.from.isAgent;
                final rawContent = isAgent
                    ? m.content
                    : '[${_formatTimestamp(m.timestampMs)}] ${m.content}';
                final entry = <String, dynamic>{
                  'role': isAgent ? 'assistant' : 'user',
                  'content': LocalLLMHelpers.enrichHistoryContent(m, rawContent),
                };
                if (m.type != MessageType.text && m.type != MessageType.system) {
                  entry['attachment_info'] = LocalLLMHelpers.buildAttachmentInfo(m);
                }
                return entry;
              })
              .toList();
        }
        totalMessageCount = await _db.getChannelMessageCount(sessionId);
      }

      // Build the full message list for trace: history + current user message
      final traceMessages = [
        ...?chatHistory,
        {'role': 'user', 'content': userMessage.content},
      ];

      infLogAcp.beginRound(taskId, requestSummary: 'ACP request', messages: traceMessages);

      // Task completion tracking
      final taskCompleter = Completer<void>();
      Map<String, dynamic>? actionConfirmationData;
      Map<String, dynamic>? singleSelectData;
      Map<String, dynamic>? multiSelectData;
      Map<String, dynamic>? fileUploadData;
      Map<String, dynamic>? formDataCapture;
      Map<String, dynamic>? messageMetadataExtra;
      // Self-reported usage from the remote agent's `task.completed` params.
      LlmTokenUsage? remoteTokenUsage;
      final splitter = StreamContentSplitter();

      void publishSplitMetadata(Map<String, dynamic> meta) {
        messageMetadataExtra = Map<String, dynamic>.from(messageMetadataExtra ?? {})
          ..addAll(meta);
        activeTask.onMessageMetadata?.call(meta);
      }

      // Decide early whether this agent supports the async-confirmation
      // capability. The flag is populated by [ACPAgentConnection._refreshCapabilities]
      // right after the Noise handshake; we snapshot it here so the callback
      // registration and the post-send branch both see the same value (the
      // connection could technically reconnect mid-turn, but the task stays
      // tied to the original handle via `effectiveTaskId`).
      final asyncConfirmation = connection.supportsAsyncConfirmation;
      final effectiveChannelIdForAsync = effectiveChannelId;

      // Hook cancellation token so the completer resolves immediately on cancel.
      // The assignment is performed after `asyncFinalize` is declared below,
      // since the cancel handler must call it on the async-confirmation path.


      // Shared builder for the "final agent message" produced after the
      // SDK turn finishes — used by both the legacy blocking path and the
      // async-path callbacks.
      Message buildFinalMessage({
        String? fallbackContent,
        bool markStopped = false,
      }) {
        final meta = <String, dynamic>{};
        meta['trace_id'] = activeTask.taskId;
        if (messageMetadataExtra != null) {
          meta.addAll(messageMetadataExtra!);
        }
        final usage = remoteTokenUsage;
        if (usage != null && usage.hasAny) {
          meta[LlmTokenUsage.metadataKey] = usage.toJson();
        }
        if (foldProgressContent) {
          meta.addAll(splitter.finalProgressMetadata());
        }
        if (actionConfirmationData != null) {
          meta['action_confirmation'] = actionConfirmationData;
        }
        if (singleSelectData != null) {
          meta['single_select'] = singleSelectData;
        }
        if (multiSelectData != null) {
          meta['multi_select'] = multiSelectData;
        }
        if (fileUploadData != null) {
          meta['file_upload'] = fileUploadData;
        }
        if (formDataCapture != null) {
          meta['form'] = formDataCapture;
        }

        final responseContent = activeTask.accumulatedContent;
        String content;
        if (markStopped) {
          content = responseContent.isNotEmpty ? '$responseContent\n\n[Stopped]' : '[Stopped]';
        } else if (responseContent.isNotEmpty) {
          content = responseContent;
        } else if (foldProgressContent && splitter.progressContent.isNotEmpty) {
          content = '';
        } else {
          content = fallbackContent ?? 'Task completed';
        }

        return Message(
          id: _uuid.v4(),
          content: content,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          to: MessageFrom(
            id: userMessage.from.id,
            type: 'user',
            name: userMessage.from.name,
          ),
          type: MessageType.text,
          replyTo: userMessage.id,
          metadata: meta,
        );
      }

      // Async-path finaliser: invoked from `onTaskCompleted` / `onTaskError`
      // when [asyncConfirmation] is true. Handles DB save + task cleanup that
      // the blocking path does inline after `await taskCompleter.future`.
      //
      // Protected against re-entry via `activeTask.dbSaveCompleter` — only
      // the first completion path wins; later errors/cancellations are
      // swallowed to avoid double-saves.
      bool asyncFinalizeStarted = false;
      Future<void> asyncFinalize({
        bool isError = false,
        String? errorMessage,
        bool markStopped = false,
      }) async {
        if (asyncFinalizeStarted) return;
        asyncFinalizeStarted = true;
        final skipSave = effectiveChannelIdForAsync.isNotEmpty &&
            _userStoppedChannels.remove(effectiveChannelIdForAsync);
        try {
          if (skipSave) {
            LoggerService().debug(
              'Skipping async finalize save — channel finalized by user stop',
              tag: 'AgentMessagingService',
            );
            return;
          }
          final Message msg;
          if (isError) {
            msg = Message(
              id: _uuid.v4(),
              content: 'Error: ${errorMessage ?? 'Task error'}',
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              from: MessageFrom(id: 'system', type: 'system', name: 'System'),
              type: MessageType.system,
            );
          } else {
            msg = buildFinalMessage(markStopped: markStopped);
            activeTask.metadata = msg.metadata;
          }

          // Delete partial message before saving the final one to avoid duplicates
          await flushHelper?.deletePartial();

          final channelForSave = effectiveChannelIdForAsync.isNotEmpty
              ? effectiveChannelIdForAsync
              : null;
          await saveMessageToChannel(msg, agent.id, channelId: channelForSave);
          if (channelForSave != null) {
            _emitCompletion(
              channelId: channelForSave,
              agent: agent,
              outcome: isError
                  ? AgentTaskOutcome.error
                  : (markStopped
                      ? AgentTaskOutcome.stopped
                      : AgentTaskOutcome.completed),
              finalMessage: msg,
              errorMessage: isError ? (errorMessage ?? 'Task error') : null,
            );
          }
        } catch (e, st) {
          LoggerService().error(
            'Async-path finalize failed for task $effectiveTaskId',
            tag: 'AgentMessagingService',
            error: e,
            stackTrace: st,
          );
        } finally {
          try {
            connection!.unregisterTaskCallbacks(effectiveTaskId);
          } catch (_) {}
          if (effectiveChannelIdForAsync.isNotEmpty) {
            final removed = _activeTasks.remove(effectiveChannelIdForAsync);
            updateTypingAgentIds();
            if (removed != null) {
              releaseForegroundTask(removed.agentName);
              if (!removed.dbSaveCompleter.isCompleted) {
                removed.dbSaveCompleter.complete();
              }
            }
          }
        }
      }

      // Now that `asyncFinalize` is in scope, wire the cancel handler.
      acpCancellationToken?.addOnCancelled(() {
        // Delete partial message — the cancel flow will save the final
        // "[Stopped]" message via buildFinalMessage(markStopped: true).
        flushHelper?.deletePartialUnawaited();
        activeTask.recordInterruption('user_cancelled');

        activeTask.isComplete = true;

        // Async-confirmation path: sendMessageToAgent already returned a
        // sentinel, so nothing is awaiting `taskCompleter` and the regular
        // `finally` cleanup in ChatController is skipped. Mirror
        // onTaskCompleted/onTaskError here: trigger the UI teardown via
        // onTaskFinished (it awaits dbSaveCompleter), then run asyncFinalize
        // to persist the "[Stopped]" message, unregister callbacks, release
        // the foreground task and complete dbSaveCompleter. Without this the
        // UI stays stuck on isProcessing=true after tapping stop.
        if (asyncConfirmation) {
          activeTask.onTaskFinished?.call();
          unawaited(asyncFinalize(markStopped: true));
        }

        if (!taskCompleter.isCompleted) {
          taskCompleter.complete();
        }
      });

      // Set up connection callbacks — accumulate in ActiveTask, then forward to UI
      connection.registerTaskCallbacks(effectiveTaskId, TaskCallbacks(
        onTextContent: (data) {
          final content = data['content'] as String? ?? '';
          if (!foldProgressContent) {
            activeTask.accumulatedContent += content;
            activeTask.onStreamChunk?.call(content);
            infLogAcp.onTextChunk(effectiveTaskId, content);
            flushHelper?.schedule();
            return;
          }
          final answerDelta = splitter.onChunk(content);
          if (answerDelta.isNotEmpty) {
            activeTask.accumulatedContent += answerDelta;
            activeTask.onStreamChunk?.call(answerDelta);
            infLogAcp.onTextChunk(effectiveTaskId, answerDelta);
            flushHelper?.schedule();
          } else {
            final progressMeta = splitter.progressMetadataDelta();
            if (progressMeta != null) publishSplitMetadata(progressMeta);
            // Still log full stream for inference debugging.
            infLogAcp.onTextChunk(effectiveTaskId, content);
          }
        },
        onActionConfirmation: (data) {
          actionConfirmationData = Map<String, dynamic>.from(data);
          activeTask.onActionConfirmation?.call(data);
        },
        onSingleSelect: (data) {
          singleSelectData = Map<String, dynamic>.from(data);
          activeTask.onSingleSelect?.call(data);
        },
        onMultiSelect: (data) {
          multiSelectData = Map<String, dynamic>.from(data);
          activeTask.onMultiSelect?.call(data);
        },
        onFileUpload: (data) {
          fileUploadData = Map<String, dynamic>.from(data);
          activeTask.onFileUpload?.call(data);
        },
        onForm: (data) {
          formDataCapture = Map<String, dynamic>.from(data);
          activeTask.onForm?.call(data);
        },
        onFileMessage: (data) async {
          await activeTask.onFileMessage?.call(data);
        },
        onMessageMetadata: (data) {
          if (!foldProgressContent) {
            messageMetadataExtra = Map<String, dynamic>.from(data);
            activeTask.onMessageMetadata?.call(data);
            return;
          }
          publishSplitMetadata(splitter.onMetadata(data));
        },
        onRequestHistory: (data) {
          activeTask.onRequestHistory?.call(data);
        },
        onTaskCompleted: (data) {
          flushHelper?.cancel();

          remoteTokenUsage = LlmTokenUsage.fromJson(data['usage']);
          infLogAcp.endRound(effectiveTaskId, stopReason: 'stop');
          infLogAcp.endSession(effectiveTaskId, InferenceStatus.completed);
          activeTask.isComplete = true;
          activeTask.onTaskFinished?.call();

          // Delete the partial message — the final message will be saved
          // by the outer flow (sendMessageToAgent or asyncFinalize).
          flushHelper?.deletePartialUnawaited();

          if (asyncConfirmation) {
            unawaited(asyncFinalize());
          }
          if (!taskCompleter.isCompleted) {
            taskCompleter.complete();
          }
        },
        onTaskError: (data) {
          flushHelper?.cancel();

          // Delete partial message — the error flow will save its own message
          flushHelper?.deletePartialUnawaited();

          final errorMsg = data['message'] as String? ?? 'Task error';
          infLogAcp.endRound(effectiveTaskId, stopReason: 'error');
          infLogAcp.endSession(effectiveTaskId, InferenceStatus.error, error: errorMsg);
          activeTask.isComplete = true;
          activeTask.errorMessage = errorMsg;
          activeTask.onTaskFinished?.call();
          if (asyncConfirmation) {
            unawaited(asyncFinalize(isError: true, errorMessage: errorMsg));
          }
          if (!taskCompleter.isCompleted) {
            taskCompleter.completeError(
              Exception(data['message'] ?? 'Task error'),
            );
          }
        },
      ));

      // Serialize attachments for ACP protocol
      final serializedAttachments = attachments
          ?.where((a) => !a.exceedsSizeLimit)
          .map((a) => a.toJson())
          .toList();

      // Send chat message
      final chatResp = await connection.sendChatMessage(
        taskId: effectiveTaskId,
        sessionId: sessionId ?? '',
        message: userMessage.content,
        userId: userMessage.from.id,
        messageId: userMessage.id,
        history: chatHistory,
        totalMessageCount: totalMessageCount,
        systemPrompt: dmSystemPrompt ??
            await AgentSoulService.instance.getSoul(agent),
        attachments: serializedAttachments,
      );

      // 超并发：agent 回 busy → 结束本会话，密文留言到 channel 信箱
      final busyStatus = chatResp.result is Map
          ? (chatResp.result as Map)['status']?.toString()
          : null;
      if (busyStatus == 'busy') {
        connection.unregisterTaskCallbacks(effectiveTaskId);
        if (!taskCompleter.isCompleted) {
          taskCompleter.complete();
        }

        final left = await leaveMailboxAndCollect(
          agent: agent,
          userMessage: userMessage,
          sessionId: sessionId ?? '',
          requestId: effectiveTaskId,
          chatHistory: chatHistory,
          onStreamChunk: (chunk) {
            activeTask.accumulatedContent += chunk;
            activeTask.onStreamChunk?.call(chunk);
            flushHelper?.schedule();
          },
        );

        flushHelper.cancel();
        flushHelper.deletePartialUnawaited();
        activeTask.isComplete = true;
        return left;
      }

      // Async-confirmation path: don't block on `task.completed`. The
      // registered TaskCallbacks above will handle DB save + cleanup when
      // the SDK turn actually finishes (or errors). Return a sentinel
      // Message so the outer `sendMessageToAgent` knows to skip its own
      // post-return save path.
      if (asyncConfirmation) {
        LoggerService().debug(
          'Async-confirmation path: returning from _sendViaACPProtocol without '
          'awaiting task.completed (agentId=${agent.id}, taskId=$effectiveTaskId)',
          tag: 'AgentMessagingService',
        );
        return Message(
          id: 'async_pending_$effectiveTaskId',
          content: '',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          to: MessageFrom(
            id: userMessage.from.id,
            type: 'user',
            name: userMessage.from.name,
          ),
          type: MessageType.text,
          replyTo: userMessage.id,
          metadata: {_asyncPendingSentinelMetadataKey: true},
        );
      }

      // Wait for task.completed, task.error, or local cancellation
      final taskTimeoutSeconds = (agent.metadata['task_timeout_seconds'] as num?)?.toInt() ?? 10800;
      await taskCompleter.future.timeout(
        Duration(seconds: taskTimeoutSeconds),
        onTimeout: () {
          throw TimeoutException('ACP task timed out');
        },
      );

      // If cancelled, clean up callbacks and return partial content.
      if (acpCancellationToken?.isCancelled == true) {
        connection.unregisterTaskCallbacks(effectiveTaskId);
        return buildFinalMessage(markStopped: true);
      }

      // Clear callbacks and remove from active tasks
      connection.unregisterTaskCallbacks(effectiveTaskId);
      // NOTE: Don't remove from _activeTasks here — sendMessageToAgent will
      // do it after persisting the response to DB so the UI can await the save.

      final finalMessage = buildFinalMessage();
      activeTask.metadata = finalMessage.metadata;
      
      // Delete partial message — the outer sendMessageToAgent will save finalMessage
      flushHelper.deletePartialUnawaited();

      return finalMessage;
    } catch (e, stackTrace) {
      flushHelper?.deletePartialUnawaited();

      LoggerService().error('ACP protocol error', tag: 'AgentMessagingService', error: e, stackTrace: stackTrace);
      if (connection != null && taskId != null) {
        connection.unregisterTaskCallbacks(taskId);
      }
      // Don't remove from _activeTasks here — sendMessageToAgent's catch
      // will handle DB save and cleanup via dbSaveCompleter.
      throw Exception('ACP protocol error: $e');
    }
  }

  /// Public accessor for group executor: get or create an ACP connection.
  Future<ACPAgentConnection> getOrCreateACPConnection(RemoteAgent agent) =>
      _getOrCreateACPConnection(agent);

  /// Get or create an ACP connection for a given agent.
  Future<ACPAgentConnection> _getOrCreateACPConnection(RemoteAgent agent) async {
    var connection = _acpConnections[agent.id];

    if (connection != null && connection.isConnected) {
      return connection;
    }

    // Create new connection
    connection = ACPAgentConnection(agentId: agent.id);
    final newConnection = connection;
    _acpConnections[agent.id] = connection;

    // 监听连接状态变化，实时更新 Agent 在线/离线状态。
    // 使用 identical(...) 保护：只有当 map 仍然指向自己（而不是之后被"主动
    // 重试"替换进来的新连接）时才从 map 删除。避免旧连接延迟的 disconnect
    // 回调把刚建立的新连接误删。
    connection.onConnectionStateChanged = (bool connected) {
      if (!connected) {
        _db.updateRemoteAgentStatus(agent.id, 'offline').catchError((_) {});
        if (identical(_acpConnections[agent.id], newConnection)) {
          _acpConnections.remove(agent.id);
        }
        LoggerService().info('ACP connection offline: ${agent.name}', tag: 'AgentMessagingService');
      }
    };

    // 每次建连/重连成功拿到 AgentCard 后，自动把网关自述简历同步到本地
    //（仅当本地简历为空，不覆盖用户手动填写）。best-effort。
    connection.onAgentCardFetched = (card) {
      getIt<RemoteAgentService>()
          .syncResumeFromCardData(agent.id, card)
          .catchError((Object e) {
        LoggerService().debug(
          'Sync resume from card skipped for ${agent.id}: $e',
          tag: 'AgentMessagingService',
        );
      });
    };

    // Build the WebSocket URL
    String wsUrl;
    if (agent.endpoint.startsWith('ws://') || agent.endpoint.startsWith('wss://')) {
      wsUrl = agent.endpoint;
    } else {
      // Convert http(s) to ws(s)
      wsUrl = agent.endpoint
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
      if (!wsUrl.contains('/acp/ws')) {
        wsUrl = wsUrl.endsWith('/') ? '${wsUrl}acp/ws' : '$wsUrl/acp/ws';
      }
    }

    await connection.connect(
      wsUrl,
      agent.token,
      targetAgentId: agent.metadata['target_agent_id'] as String?,
      pinnedFingerprint: (agent.metadata['noise_peer_fp'] as String?) ?? '',
      cachedPeerStaticPublicKey: decodeCachedPeerPublicKey(
        agent.metadata['cached_peer_static_public_key'],
      ),
    );
    return connection;
  }

  /// 带 3 次指数退避重试 + `checkAgentHealth` 兜底的 ACP 建连。
  ///
  /// 使用场景：用户主动发送消息时，若本地缓存的 agent 状态为 offline、或
  /// 建连瞬时失败，首次失败后再试一次通常即可成功（网络抖动/Agent 刚上线
  /// 但本地状态未刷新）。避免用户遇到"一次失败就报错"的体验。
  ///
  /// 规则：
  /// - 若已有 `isConnected == true` 的连接，直接复用，**不**触发任何
  ///   `onReconnecting` 回调（用户无感知）。
  /// - 否则进入重试循环，间隔 500ms → 1s → 2s。
  /// - 不可重试错误（身份指纹不匹配/未授权/鉴权失败等）立即 rethrow。
  /// - 3 次全部失败 → 调一次 `RemoteAgentService.checkAgentHealth` 兜底
  ///   （它对 502/503 隧道未就绪有特判）；若兜底成功，再尝试一次真正建连。
  /// - 回调约定：`attempt > 0` 正在进行第几次；`attempt == 0` 结束（成功或失败）。
  Future<ACPAgentConnection> _getOrCreateACPConnectionWithRetry(
    RemoteAgent agent, {
    void Function(int attempt, int total)? onReconnecting,
  }) async {
    // 快速路径：已有活连接直接返回
    final cached = _acpConnections[agent.id];
    if (cached != null && cached.isConnected) {
      return cached;
    }

    const total = kReconnectMaxAttempts;
    Object? lastError;

    for (int attempt = 1; attempt <= total; attempt++) {
      onReconnecting?.call(attempt, total);

      // 先把可能还挂在 map 里的 stale 连接踢掉并释放，避免
      // _getOrCreateACPConnection 把它当作"活连接"复用，或者它的被动自动
      // 重连与主动路径抢活。dispose() 会设 _disposed 阻止进一步重连。
      final stale = _acpConnections.remove(agent.id);
      if (stale != null) {
        try {
          stale.dispose();
        } catch (_) {}
      }

      try {
        final conn = await _getOrCreateACPConnection(agent);
        onReconnecting?.call(0, total);
        return conn;
      } catch (e, st) {
        lastError = e;
        LoggerService().warning(
          'ACP reconnect attempt $attempt/$total failed: $e',
          tag: 'AgentMessagingService',
        );
        if (!isRetriableConnectionError(e)) {
          LoggerService().error(
            'Non-retriable connection error; aborting retry loop',
            tag: 'AgentMessagingService',
            error: e,
            stackTrace: st,
          );
          onReconnecting?.call(0, total);
          rethrow;
        }
        if (attempt < total) {
          await Future.delayed(kReconnectBackoffs[attempt - 1]);
        }
      }
    }

    // 兜底：调一次完整的 checkAgentHealth（内部有 502/503 隧道未就绪特判），
    // 若返回 healthy 则再做一次建连（checkAgentHealth 使用的是临时连接且
    // 已 dispose，不能直接复用）。
    LoggerService().warning(
      'All $total reconnect attempts failed, falling back to checkAgentHealth',
      tag: 'AgentMessagingService',
    );
    try {
      final svc = getIt<RemoteAgentService>();
      final healthy = await svc.checkAgentHealth(agent.id);
      if (healthy) {
        try {
          final conn = await _getOrCreateACPConnection(agent);
          onReconnecting?.call(0, total);
          return conn;
        } catch (e) {
          lastError = e;
          LoggerService().warning(
            'Post-health connect still failed: $e',
            tag: 'AgentMessagingService',
          );
        }
      }
    } catch (e) {
      LoggerService().warning(
        'Fallback checkAgentHealth threw: $e',
        tag: 'AgentMessagingService',
      );
    }

    onReconnecting?.call(0, total);
    throw Exception(
      'Agent ${agent.name} is not reachable after $total retries. '
      'Last error: $lastError',
    );
  }

  /// Send message via the P2P peer channel to a paired device's local agent.
  ///
  /// 消费方路径：把用户消息通过 [PeerAgentClientService] 经已配对设备的加密
  /// 通道转发给对端，对端用自己的本地 agent 执行并流式回传文本。多轮上下文由
  /// 对端按「来源设备 + 来源会话」隔离维护（本端会话 id 通过 sessionId 透传），
  /// 因此这里只发送当前这条消息；本端新开会话会在对端得到对应的干净新会话。
  Future<Message?> _sendViaPeerProtocol(
    Message userMessage,
    RemoteAgent agent, {
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic> actionData)? onActionConfirmation,
    void Function(Map<String, dynamic> metadata)? onMessageMetadata,
    String? sessionId,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
  }) async {
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (peerId == null || remoteAgentId == null) {
      throw Exception('Peer agent missing source_peer_id/remote_agent_id');
    }

    final effectiveChannelId = sessionId ?? '';
    final activeTask = ActiveTask(
      taskId: _uuid.v4(),
      agentId: agent.id,
      agentName: agent.name,
      channelId: effectiveChannelId,
      userMessageId: userMessage.id,
      userId: userMessage.from.id,
      userName: userMessage.from.name,
    );
    activeTask.onStreamChunk = onStreamChunk;
    activeTask.onMessageMetadata = onMessageMetadata;
    // Surface tool-call approvals (agent_approval_req relayed by the hub) to
    // the chat UI via the same card mechanism as the direct ACP flow.
    activeTask.onActionConfirmation = onActionConfirmation;
    if (effectiveChannelId.isNotEmpty) {
      _activeTasks[effectiveChannelId] = activeTask;
      updateTypingAgentIds();
    }
    ForegroundTaskService().acquireTask(agent.name);

    // Declared before the flush helper so its onFlushed closure can bridge the
    // partial row id into the persisted inflight record. Flush only fires after
    // the first chunk, which always follows onRequestStarted — peerRequestId is
    // non-null by then.
    String? peerRequestId;
    final flushHelper = StreamingFlushHelper.fromAgent(
      db: _db,
      activeTask: activeTask,
      agent: agent,
      channelId: effectiveChannelId,
      replyToId: userMessage.id,
      traceId: activeTask.taskId,
      onFlushed: (messageId) {
        final rid = peerRequestId;
        if (rid == null) return;
        PeerAgentClientService.instance
            .noteInflightPartialMessageId(rid, messageId);
      },
    );

    // For a synced remote session the local channelId is `psess_<remoteSessionId>`.
    // Strip the prefix so the bare remote sessionId is what reaches the peer,
    // hitting acp-proxy's pre-seeded mapping and resuming the exact upstream
    // session (no crossing). Regular channels pass their channelId as-is.
    final boundRemoteSessionId = remoteSessionIdFromChannelId(effectiveChannelId);
    final peerSessionId = boundRemoteSessionId ??
        (effectiveChannelId.isNotEmpty ? effectiveChannelId : null);

    List<Map<String, dynamic>>? chatHistory;
    if (effectiveChannelId.isNotEmpty) {
      final messages = await loadChannelMessages(effectiveChannelId, limit: 40);
      if (messages.isNotEmpty) {
        chatHistory = messages
            .where((m) =>
                m.type != MessageType.system &&
                m.type != MessageType.permissionAudit &&
                m.id != userMessage.id)
            .map((m) {
              final isAgent = m.from.isAgent;
              return <String, dynamic>{
                'role': isAgent ? 'assistant' : 'user',
                'content': m.content,
              };
            })
            .where((e) => (e['content'] as String).trim().isNotEmpty)
            .toList();
        if (chatHistory.isEmpty) chatHistory = null;
      }
    }

    // Capture the latest approval so the final persisted message still carries
    // the card after sendChat completes and ChatController reloads from DB.
    Map<String, dynamic>? actionConfirmationData;
    final splitter = StreamContentSplitter();
    final infLogPeer = InferenceLogService.instance;
    final traceId = activeTask.taskId;
    infLogPeer.beginSession(
      sessionId: traceId,
      agentId: agent.id,
      agentName: agent.name,
      channelId: effectiveChannelId.isNotEmpty ? effectiveChannelId : null,
      executionMode: 'peer_dm',
      userMessage: userMessage.content,
      systemPrompt: json.encode({
        'peer_id': peerId,
        'remote_agent_id': remoteAgentId,
        'peer_session_id': peerSessionId,
        'user_message_id': userMessage.id,
      }),
    );
    infLogPeer.beginRound(traceId, requestSummary: 'Peer DM request');

    void publishMetadata(Map<String, dynamic> meta) {
      final merged = Map<String, dynamic>.from(activeTask.metadata ?? {});
      merged.addAll(meta);
      activeTask.metadata = merged;
      activeTask.onMessageMetadata?.call(meta);
    }

    try {
      if (attachments != null) {
        for (final a in attachments) {
          if (a.exceedsSizeLimit) {
            throw Exception(
              '附件过大（上限 ${AttachmentData.maxSizeBytes ~/ (1024 * 1024)}MB）: '
              '${a.fileName}',
            );
          }
        }
      }

      final result = await PeerAgentClientService.instance.sendChat(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        // Wire-only enrichment: local DB/bubble keeps userMessage.content;
        // prefer persisted metadata.implicit_prompt when present.
        message: MessageImplicitPrompt.forPeerWireMessage(
          message: userMessage.content,
          attachments: attachments,
          messageMetadata: userMessage.metadata,
        ),
        sessionId: peerSessionId,
        history: chatHistory,
        attachments: attachments,
        cancelToken: acpCancellationToken,
        localAgentId: agent.id,
        channelId: effectiveChannelId,
        userMessageId: userMessage.id,
        userId: userMessage.from.id,
        userName: userMessage.from.name,
        agentName: agent.name,
        onRequestStarted: (requestId) {
          peerRequestId = requestId;
          final spanId = TraceService.instance.addSpan(
            traceId: traceId,
            spanType: 'peer_request',
            name: 'agent_chat',
            metadata: {
              'request_id': requestId,
              'peer_id': peerId,
              'remote_agent_id': remoteAgentId,
              'peer_session_id': peerSessionId,
              'user_message_id': userMessage.id,
            },
          );
          TraceService.instance.endSpan(
            spanId,
            outputData: {'status': 'sent'},
          );
          publishMetadata({
            'request_id': requestId,
            'peer_id': peerId,
            'remote_agent_id': remoteAgentId,
          });
        },
        onChunk: (chunk) {
          final answerDelta = splitter.onChunk(chunk);
          if (answerDelta.isNotEmpty) {
            activeTask.accumulatedContent += answerDelta;
            if (peerRequestId != null) {
              PeerAgentClientService.instance.noteInflightAnswer(
                peerRequestId!,
                activeTask.accumulatedContent,
              );
            }
            activeTask.onStreamChunk?.call(answerDelta);
            flushHelper.schedule();
            infLogPeer.onTextChunk(traceId, answerDelta);
          } else {
            final progressMeta = splitter.progressMetadataDelta();
            if (progressMeta != null) publishMetadata(progressMeta);
            infLogPeer.onTextChunk(traceId, chunk);
          }
        },
        onMetadata: (data) {
          publishMetadata(splitter.onMetadata(data));
        },
        onActionConfirmation: (data) {
          actionConfirmationData = Map<String, dynamic>.from(data);
          final meta = Map<String, dynamic>.from(activeTask.metadata ?? {});
          meta['action_confirmation'] = actionConfirmationData;
          activeTask.metadata = meta;
          // Prefer the live UI callback; if it was detached mid-turn, the
          // metadata above still lets loadMessages / reattach show the card.
          final cb = activeTask.onActionConfirmation;
          if (cb != null) {
            cb(data);
          } else {
            LoggerService().warning(
              'Peer approval arrived but UI callback was detached '
              '(confirmationId=${data['confirmation_id']}) — kept on ActiveTask.metadata',
              tag: 'PeerApproval',
            );
          }
        },
      );

      activeTask.isComplete = true;
      activeTask.onTaskFinished?.call();

      final wasCancelled = acpCancellationToken?.isCancelled == true;
      if (wasCancelled) {
        activeTask.recordInterruption('user_cancelled');
      }

      infLogPeer.endRound(traceId, stopReason: wasCancelled ? 'cancelled' : 'stop');
      infLogPeer.endSession(
        traceId,
        wasCancelled ? InferenceStatus.cancelled : InferenceStatus.completed,
      );

      // Prefer splitter answer (progress stripped). On cancel, always leave a
      // visible "[Stopped]" marker — including progress-only turns — so a
      // subsequent loadMessages cannot look like "no reply".
      final content = buildPeerFinalContent(
        answerContent: splitter.answerContent,
        progressContent: splitter.progressContent,
        accumulatedContent: activeTask.accumulatedContent,
        resultContent: result.content,
        wasCancelled: wasCancelled,
      );

      final meta = <String, dynamic>{
        'trace_id': traceId,
        'peer_id': peerId,
        'remote_agent_id': remoteAgentId,
        if (peerRequestId != null || result.requestId != null)
          'request_id': peerRequestId ?? result.requestId,
        if (peerSessionId != null) 'peer_session_id': peerSessionId,
        'user_message_id': userMessage.id,
      };
      if (result.metadata != null) meta.addAll(result.metadata!);
      meta.addAll(splitter.finalProgressMetadata());
      meta['trace_id'] = traceId;
      if (peerRequestId != null || result.requestId != null) {
        meta['request_id'] = peerRequestId ?? result.requestId;
      }
      if (wasCancelled) {
        meta['status'] = 'stopped';
        meta['interruption_reason'] = 'user_cancelled';
      }
      // Prefer the live task metadata — the approval tap merged the user's
      // verdict into it — over the snapshot captured when the card arrived,
      // so the persisted message keeps the selected state across reloads.
      final liveAc =
          activeTask.metadata?['action_confirmation'] as Map<String, dynamic>?;
      final relayedAc =
          meta['action_confirmation'] as Map<String, dynamic>?;
      if (liveAc != null) {
        meta['action_confirmation'] = liveAc;
      } else if (actionConfirmationData != null) {
        meta['action_confirmation'] = actionConfirmationData;
      } else if (relayedAc != null) {
        relayedAc['confirmation_context'] ??= 'peer';
        meta['action_confirmation'] = relayedAc;
      }
      activeTask.metadata = meta;

      await flushHelper.deletePartial();

      final finalMsg = Message(
        id: _uuid.v4(),
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(
          id: userMessage.from.id,
          type: 'user',
          name: userMessage.from.name,
        ),
        type: MessageType.text,
        replyTo: userMessage.id,
        metadata: meta.isEmpty ? null : meta,
      );
      // A history sync may have mirrored this turn while it finalized —
      // suppress (or de-quote) the local copy instead of duplicating it.
      return _dedupeAgainstSyncedTranscript(finalMsg, effectiveChannelId);
    } catch (e) {
      await flushHelper.deletePartial();
      infLogPeer.endRound(traceId, stopReason: 'error');
      infLogPeer.endSession(traceId, InferenceStatus.error, error: '$e');
      rethrow;
    }
  }

  /// Send message via generic HTTP protocol
  Future<Message?> _sendViaGenericProtocol(Message userMessage, RemoteAgent agent) async {
    try {
      // This is a placeholder for custom protocol implementations
      // For now, return a simple response
      return Message(
        id: _uuid.v4(),
        content: 'Received your message: ${userMessage.content}',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(
          id: agent.id,
          type: 'agent',
          name: agent.name,
        ),
        to: MessageFrom(
          id: userMessage.from.id,
          type: 'user',
          name: userMessage.from.name,
        ),
        type: MessageType.text,
        replyTo: userMessage.id,
      );
    } catch (e) {
      throw Exception('Generic protocol error: $e');
    }
  }

  /// Send message via local LLM API (no WebSocket, no endpoint required).
  ///
  /// Supports multi-round tool calling: when the LLM invokes OS tools, we
  /// execute them (with confirmation for high-risk ops), feed results back,
  /// and let the LLM continue reasoning until it produces a final text reply
  /// or invokes a UI tool (which is fire-and-forget, ending the loop).
  Future<Message?> _sendViaLocalLLM({
    required String content,
    required RemoteAgent agent,
    required String userId,
    required String userName,
    String? channelId,
    String? replyToId,
    String? dmSystemPrompt,
    void Function(String chunk)? onStreamChunk,
    void Function(Map<String, dynamic>)? onActionConfirmation,
    void Function(Map<String, dynamic>)? onSingleSelect,
    void Function(Map<String, dynamic>)? onMultiSelect,
    void Function(Map<String, dynamic>)? onFileUpload,
    void Function(Map<String, dynamic>)? onForm,
    Future<void> Function(Map<String, dynamic>)? onFileMessage,
    void Function(Map<String, dynamic>)? onMessageMetadata,
    void Function(Map<String, dynamic>)? onRequestHistory,
    Future<bool> Function(String, Map<String, dynamic>, os_exec.RiskLevel)? onOsToolConfirmation,
    /// 工作流计划创建回调（She 在 DM 中调用 `shepaw workflow create` 成功后触发）。
    /// 参数：workflowId、可直接挂到消息 metadata 的 plan_approval 数据。
    void Function(String workflowId, Map<String, dynamic> planData)? onWorkflowPlanCreated,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
    Message? existingUserMessage,
    List<Map<String, dynamic>>? extraTools,
  }) async {
    LoggerService().info('Starting local LLM chat', tag: 'AgentMessagingService');

    // Create and save user message (skip if pre-existing attachment message provided)
    Message userMessage;
    if (existingUserMessage != null) {
      userMessage = existingUserMessage;
      LoggerService().debug('Using existing user message: ${userMessage.id}', tag: 'AgentMessagingService');
    } else {
      userMessage = Message(
        id: _uuid.v4(),
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: userId, type: 'user', name: userName),
        to: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        type: MessageType.text,
        replyTo: replyToId,
        metadata: MessageImplicitPrompt.metadataForTurn(
          text: content,
          attachments: attachments,
        ),
      );
      await saveMessageToChannel(userMessage, agent.id, channelId: channelId);
      LoggerService().debug('User message saved', tag: 'AgentMessagingService');
    }

    // Create ActiveTask for background tracking
    final effectiveChannelId = channelId ?? '';
    final activeTask = ActiveTask(
      taskId: _uuid.v4(),
      agentId: agent.id,
      agentName: agent.name,
      channelId: effectiveChannelId,
      userMessageId: userMessage.id,
      userId: userId,
      userName: userName,
    );
    activeTask.onStreamChunk = onStreamChunk;
    activeTask.onActionConfirmation = onActionConfirmation;
    activeTask.onSingleSelect = onSingleSelect;
    activeTask.onMultiSelect = onMultiSelect;
    activeTask.onFileUpload = onFileUpload;
    activeTask.onForm = onForm;
    activeTask.onFileMessage = onFileMessage;
    activeTask.onMessageMetadata = onMessageMetadata;
    activeTask.onRequestHistory = onRequestHistory;
    activeTask.onOsToolConfirmation = onOsToolConfirmation;

    if (effectiveChannelId.isNotEmpty) {
      _activeTasks[effectiveChannelId] = activeTask;
      updateTypingAgentIds();
    }
    ForegroundTaskService().acquireTask(agent.name);

    final flushHelper = StreamingFlushHelper.fromAgent(
      db: _db,
      activeTask: activeTask,
      agent: agent,
      channelId: effectiveChannelId,
      replyToId: userMessage.id,
      traceId: activeTask.taskId,
    );

    try {
      // Determine provider type for message format
      final providerType = agent.metadata['llm_provider'] as String? ?? 'openai';
      final isClaude = providerType == 'claude';

      // Determine enabled skills
      final enabledSkills = agent.enabledSkills;
      final hasSkills = enabledSkills.isNotEmpty;
      final skillRegistry = SkillRegistry.instance;

      // Determine enabled tool models
      final enabledToolModels = agent.enabledToolModels;
      final hasToolModels = enabledToolModels.isNotEmpty;
      final toolModelRegistry = ModelRegistry.instance;
      final toolModelScenarios = agent.toolModelScenarios;

      // Build combined tool list (UI + OS + Skills + Tool Models + Paw for She)
      final isPeerInbound = isPeerAgentChannel(channelId);
      final peerBoundary =
          isPeerInbound ? agent.peerBoundaryConfig : PeerBoundaryConfig.open;
      final promptConfig = isPeerInbound
          ? agent.promptStackConfigForPeerInbound()
          : agent.promptStackConfig;
      final includeShepawCli = promptConfig.tools.includeShepawCli;
      final List<Map<String, dynamic>> combinedTools;
      if (isClaude) {
        combinedTools = [
          ...UIComponentRegistry.instance.claudeTools(),
          // OS/web tools are now accessed through shepaw CLI (os/web namespaces)
          if (hasSkills && promptConfig.tools.includeSkills) ...skillRegistry.claudeTools(enabledSkills: enabledSkills),
          if (hasToolModels && promptConfig.tools.includeToolModels) ...toolModelRegistry.claudeTools(enabledToolModels: enabledToolModels, scenarioOverrides: toolModelScenarios),
          // includeShepawCli gates the function tool for She and non-She;
          // She-only data-access prompt copy is gated separately in AgentPromptBuilder.
          if (includeShepawCli) ShepawCLI.instance.claudeTool(),
          LocalLLMHelpers.getToolResultClaude(),
          if (extraTools != null) ...extraTools,
        ];
      } else {
        combinedTools = [
          ...UIComponentRegistry.instance.openAITools(),
          // OS/web tools are now accessed through shepaw CLI (os/web namespaces)
          if (hasSkills && promptConfig.tools.includeSkills) ...skillRegistry.openAITools(enabledSkills: enabledSkills),
          if (hasToolModels && promptConfig.tools.includeToolModels) ...toolModelRegistry.openAITools(enabledToolModels: enabledToolModels, scenarioOverrides: toolModelScenarios),
          if (includeShepawCli) ShepawCLI.instance.openAITool(),
          LocalLLMHelpers.getToolResultOpenAI(),
          if (extraTools != null) ...extraTools,
        ];
      }

      // Build system prompt via AgentPromptBuilder (handles She and all other
      // agents uniformly; dmSystemPrompt is passed as the DM-channel override).
      // Peer-inbound: strip host private context + inject external preamble.
      final peerPreamble = isPeerInbound && peerBoundary.injectExternalPreamble
          ? PeerBoundaryPrompt.buildPreamble(peerDisplayName: userName)
          : null;
      final builtPrompt = await AgentPromptBuilder(
        agent: agent,
        dmSystemPromptOverride: dmSystemPrompt,
        ephemeralContext: peerPreamble,
        configOverride: isPeerInbound ? promptConfig : null,
      ).build();
      final systemPrompt = builtPrompt.full;

      // Hook cancellation early so compaction LLM calls can also be aborted.
      final cancelKey = activeTask.taskId;
      acpCancellationToken?.addOnCancelled(() {
        activeTask.recordInterruption('user_cancelled');
        LocalLLMAgentService.instance.abort(cancelKey);
      });

      // Load history with a character budget. When over budget, summarize older
      // turns instead of silently dropping them (FIFO), then keep a recent raw tail.
      const historyMaxChars = HistoryCompactor.defaultMaxChars;
      const historyLoadLimit = 100;
      final historyService = HistoryService(_db, _toolResultDb);
      final List<Map<String, dynamic>> chatHistory = [];
      List<Message> storeFoldMessages = const [];
      if (channelId != null) {
        // Load a wider window than the budget so compaction has material to summarize.
        final loaded = await historyService.loadChannelMessages(
          channelId,
          limit: historyLoadLimit,
        );
        final candidates = loaded
            .where((m) =>
                m.type != MessageType.system &&
                m.type != MessageType.permissionAudit &&
                m.id != userMessage.id)
            .toList();

        final plan = HistoryCompactor.plan(
          messages: candidates,
          maxChars: historyMaxChars,
        );

        List<Message> recentMessages = plan.recent;
        if (plan.needsCompaction &&
            acpCancellationToken?.isCancelled != true) {
          try {
            final summary = await HistoryCompactionCacheService.obtainSummary(
              channelId: channelId,
              older: plan.older,
              summarize: (transcript) => _summarizeHistoryForCompaction(
                agent: agent,
                transcript: transcript,
                cancelKey: cancelKey,
              ),
            );
            if (summary.isNotEmpty) {
              chatHistory.add(HistoryCompactor.summaryMessage(summary));
              // Keep recent tail within remaining budget after the summary block.
              final summaryCost = (chatHistory.last['content'] as String).length;
              var budgetLeft = historyMaxChars - summaryCost;
              while (recentMessages.isNotEmpty &&
                  recentMessages.fold<int>(
                          0, (s, m) => s + m.content.length) >
                      budgetLeft &&
                  recentMessages.length > 4) {
                recentMessages = recentMessages.sublist(1);
              }
              LoggerService().info(
                'History compacted: ${plan.older.length} older msgs → '
                '${summary.length} char summary; keeping ${recentMessages.length} recent',
                tag: 'AgentMessagingService',
              );
            } else {
              // Empty summary — fall back to FIFO truncate of the full set.
              recentMessages = await historyService.loadAndTruncateHistory(
                channelId,
                maxChars: historyMaxChars,
                limit: historyLoadLimit,
                excludeMessageId: userMessage.id,
              );
            }
          } catch (e) {
            LoggerService().warning(
              'History compaction failed, falling back to truncate: $e',
              tag: 'AgentMessagingService',
            );
            recentMessages = await historyService.loadAndTruncateHistory(
              channelId,
              maxChars: historyMaxChars,
              limit: historyLoadLimit,
              excludeMessageId: userMessage.id,
            );
          }
        }

        for (final m in recentMessages) {
          final isAgent = m.from.isAgent;
          final rawContent = isAgent
              ? m.content
              : '[${_formatTimestamp(m.timestampMs)}] ${m.content}';
          final entry = <String, dynamic>{
            'role': isAgent ? 'assistant' : 'user',
            'content': LocalLLMHelpers.enrichHistoryContent(m, rawContent),
          };
          if (m.type != MessageType.text && m.type != MessageType.system) {
            entry['attachment_info'] = LocalLLMHelpers.buildAttachmentInfo(m);
          }
          chatHistory.add(entry);
        }
        storeFoldMessages = recentMessages;
      }

      // Build initial message list
      final List<Map<String, dynamic>> roundMessages = [];
      if (!isClaude && systemPrompt.isNotEmpty) {
        roundMessages.add({'role': 'system', 'content': systemPrompt});
      }
      roundMessages.addAll(chatHistory);
      // Resolve quoted message content for trace
      String effectiveContent = content;
      if (replyToId != null) {
        final quotedMsg = await getMessageById(replyToId);
        if (quotedMsg != null) {
          effectiveContent = '[引用 ${quotedMsg.from.name} 的消息: "${quotedMsg.content}"]\n\n$content';
        }
      }

      roundMessages.add(LocalLLMHelpers.buildUserMessageContent(
        effectiveContent,
        attachments,
        isClaude,
        historyMessages: storeFoldMessages,
      ));

      // ======= Multi-round tool calling loop =======
      final infLog = InferenceLogService.instance;
      infLog.beginSession(
        sessionId: activeTask.taskId,
        agentId: agent.id,
        agentName: agent.name,
        channelId: channelId ?? effectiveChannelId,
        provider: agent.metadata['llm_provider'] as String?,
        model: agent.metadata['llm_model'] as String?,
        executionMode: 'local_multi_round',
        userMessage: effectiveContent,
        systemPrompt: systemPrompt,
      );

      // 预分配 agentMessageId：工具执行时需要关联到该消息，
      // 循环结束后创建 agentResponse 复用同一 ID，保证 tool_executions 外键有效。
      final agentMessageId = _uuid.v4();

      final responseBuffer = StringBuffer();
      Map<String, dynamic>? actionConfirmationData;
      Map<String, dynamic>? singleSelectData;
      Map<String, dynamic>? multiSelectData;
      Map<String, dynamic>? fileUploadData;
      Map<String, dynamic>? formDataCapture;
      Map<String, dynamic>? messageMetadataExtra;
      Map<String, dynamic>? planApprovalData;
      Map<String, dynamic>? historyRequestData;
      bool fileMessageHandled = false;

      // Summed across tool-calling rounds; written to the saved message
      // metadata so the bubble can show per-message token cost.
      var turnTokenUsage = const LlmTokenUsage();

      final maxToolRounds = (agent.metadata['max_tool_rounds'] as num?)?.toInt() ?? 100;

      for (int round = 0; round < maxToolRounds; round++) {
        if (acpCancellationToken?.isCancelled == true) break;

        infLog.beginRound(
          activeTask.taskId,
          requestSummary: 'Round ${round + 1}',
          messages: List<Map<String, dynamic>>.from(roundMessages),
        );

        // Collect events from this round
        final toolCallEvents = <LLMToolCallEvent>[];
        LLMDoneEvent? doneEvent;

        await for (final event in LocalLLMAgentService.instance.runWithCancelKey(
          cancelKey,
          () => LocalLLMAgentService.instance.chatRound(
            agent: agent,
            messages: roundMessages,
            tools: combinedTools,
            systemPrompt: isClaude ? systemPrompt : null,
            layeredSystemPrompt: isClaude ? builtPrompt : null,
            attachments: round == 0 ? attachments : null,
          ),
        )) {
          if (acpCancellationToken?.isCancelled == true) break;

          switch (event) {
            case LLMTextEvent():
              responseBuffer.write(event.text);
              activeTask.accumulatedContent += event.text;
              activeTask.onStreamChunk?.call(event.text);
              infLog.onTextChunk(activeTask.taskId, event.text);
              flushHelper.schedule();
              break;

            case LLMToolCallEvent():
              toolCallEvents.add(event);
              infLog.onToolCall(activeTask.taskId, id: event.id, name: event.name, arguments: event.arguments);
              break;

            case LLMDoneEvent():
              doneEvent = event;
              turnTokenUsage = turnTokenUsage.plus(LlmTokenUsage(
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
              ));
              infLog.endRound(
                activeTask.taskId,
                stopReason: event.stopReason,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
              );
              break;
          }
        }

        // If cancelled or no tool calls, we're done
        if (acpCancellationToken?.isCancelled == true) break;
        if (toolCallEvents.isEmpty) break;

        // Separate UI tool calls from skill, tool model, and paw (CLI) tool calls
        // OS/web tools are no longer dispatched directly — they go through ShepawCLI
        final uiToolCalls = <LLMToolCallEvent>[];
        final skillToolCalls = <LLMToolCallEvent>[];
        final toolModelCalls = <LLMToolCallEvent>[];
        final pawToolCalls = <LLMToolCallEvent>[];
        final getToolResultCalls = <LLMToolCallEvent>[];
        final orchToolCalls = <LLMToolCallEvent>[];
        for (final tc in toolCallEvents) {
          if (tc.name == LocalLLMHelpers.kGetToolResult) {
            getToolResultCalls.add(tc);
          } else if (GroupOrchestrationTools.names.contains(tc.name)) {
            orchToolCalls.add(tc);
          } else if (LocalLLMHelpers.isUiTool(tc.name)) {
            uiToolCalls.add(tc);
          } else if (skillRegistry.isSkillTool(tc.name)) {
            skillToolCalls.add(tc);
          } else if (toolModelRegistry.isToolModelTool(tc.name)) {
            toolModelCalls.add(tc);
          } else if (ShepawCLI.instance.isPawTool(tc.name)) {
            pawToolCalls.add(tc);
          }
        }

        // Peer-hosted group admin: serialize orchestration tools as the
        // legacy ```json``` block so the client parser can dispatch.
        // Run before UI-tool break so a mixed round still carries the plan.
        final orchResults = <Map<String, dynamic>>[];
        if (orchToolCalls.isNotEmpty) {
          for (final tc in orchToolCalls) {
            final encoded = GroupOrchestrationTools.legacyJsonBlock(
              tc.name,
              tc.arguments,
            );
            final block = '\n\n```json\n$encoded\n```\n';
            responseBuffer.write(block);
            activeTask.accumulatedContent += block;
            activeTask.onStreamChunk?.call(block);
            final ok = jsonEncode({'ok': true, 'tool': tc.name});
            orchResults.add({
              'tool_call_id': tc.id,
              'name': tc.name,
              'result': ok,
            });
            infLog.onToolResult(
              activeTask.taskId,
              toolCallId: tc.id,
              name: tc.name,
              result: ok,
            );
          }
        }

        // Handle UI tool calls (fire-and-forget, ends the loop)
        if (uiToolCalls.isNotEmpty) {
          for (final tc in uiToolCalls) {
            LocalLLMHelpers.dispatchUiToolCall(
              tc, activeTask,
              onCaptured: ({
                Map<String, dynamic>? ac,
                Map<String, dynamic>? ss,
                Map<String, dynamic>? ms,
                Map<String, dynamic>? fu,
                Map<String, dynamic>? fd,
                Map<String, dynamic>? mm,
                Map<String, dynamic>? rh,
                bool? fmh,
              }) {
                if (ac != null) actionConfirmationData = ac;
                if (ss != null) singleSelectData = ss;
                if (ms != null) multiSelectData = ms;
                if (fu != null) fileUploadData = fu;
                if (fd != null) formDataCapture = fd;
                if (mm != null) messageMetadataExtra = mm;
                if (rh != null) historyRequestData = rh;
                if (fmh == true) fileMessageHandled = true;
              },
            );
          }
          break; // UI tools end the loop
        }

        // Handle get_tool_result calls: look up DB and feed full result back,
        // then continue the loop so the model can use the retrieved content.
        if (getToolResultCalls.isNotEmpty && doneEvent?.rawAssistantMessage != null) {
          final fetchResults = <Map<String, dynamic>>[];

          for (final tc in getToolResultCalls) {
            final targetCallId = tc.arguments['tool_call_id'] as String? ?? '';
            infLog.onToolCall(activeTask.taskId, id: tc.id, name: tc.name, arguments: tc.arguments);

            String fetchedContent;
            if (targetCallId.isEmpty) {
              fetchedContent = jsonEncode({
                'error': 'get_tool_result requires a non-empty tool_call_id argument.',
              });
            } else {
              final execResult = await historyService.getToolExecutionResult(targetCallId);
              if (execResult == null) {
                fetchedContent = jsonEncode({
                  'error': 'No tool execution found for tool_call_id: $targetCallId',
                });
              } else {
                // 返回完整结果：Claude 用多模态 content，OpenAI 用纯文本
                if (isClaude) {
                  final content = await execResult.toClaudeContentAsync();
                  fetchedContent = content is String
                      ? content
                      : jsonEncode(content);
                } else {
                  fetchedContent = execResult.toOpenAIContent();
                }
              }
            }

            fetchResults.add({
              'tool_call_id': tc.id,
              'name': tc.name,
              'result': fetchedContent,
            });
            infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: fetchedContent);
          }

          // Append the get_tool_result round to message history and continue
          if (isClaude) {
            LocalLLMHelpers.appendToolRoundClaude(
              roundMessages, doneEvent!.rawAssistantMessage!, getToolResultCalls, fetchResults,
            );
          } else {
            LocalLLMHelpers.appendToolRoundOpenAI(
              roundMessages, doneEvent!.rawAssistantMessage!, getToolResultCalls, fetchResults,
            );
          }
          continue;
        }

        // Handle skill tool calls, tool model calls, and paw tool calls (execute and feed results back)
        final executableToolCalls = [
          ...orchToolCalls,
          ...skillToolCalls,
          ...toolModelCalls,
          ...pawToolCalls,
        ];
        if (executableToolCalls.isNotEmpty && doneEvent?.rawAssistantMessage != null) {
          final toolResults = <Map<String, dynamic>>[...orchResults];

          for (final tc in executableToolCalls) {
            // Check if this is a tool model call
            if (toolModelRegistry.isToolModelTool(tc.name)) {
              final def = toolModelRegistry.getDefinition(tc.name);
              final modelName = def?.displayName ?? tc.name;
              activeTask.accumulatedContent += '\n[Calling tool model: $modelName]\n';
              activeTask.onStreamChunk?.call('\n[Calling tool model: $modelName]\n');
              responseBuffer.write('\n[Calling tool model: $modelName]\n');

              final result = await toolModelRegistry.executeToolModel(tc.name, tc.arguments);
              toolResults.add({
                'tool_call_id': tc.id,
                'name': tc.name,
                'result': result,
              });
              infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: result);

              // 持久化工具执行结果
              await historyService.saveToolExecution(
                messageId: agentMessageId,
                channelId: effectiveChannelId,
                toolCallId: tc.id,
                toolName: tc.name,
                arguments: tc.arguments,
                result: ToolExecutionResult.text(result),
              );
              continue;
            }

            // Check if this is a skill tool call
            if (skillRegistry.isSkillTool(tc.name)) {
              final def = skillRegistry.getDefinition(tc.name);
              final skillName = def?.displayName ?? tc.name;
              activeTask.accumulatedContent += '\n[Loading skill: $skillName]\n';
              activeTask.onStreamChunk?.call('\n[Loading skill: $skillName]\n');
              responseBuffer.write('\n[Loading skill: $skillName]\n');

              final content = await skillRegistry.readSkillContent(tc.name);
              toolResults.add({
                'tool_call_id': tc.id,
                'name': tc.name,
                'result': content,
              });
              infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: content);

              // 持久化工具执行结果
              await historyService.saveToolExecution(
                messageId: agentMessageId,
                channelId: effectiveChannelId,
                toolCallId: tc.id,
                toolName: tc.name,
                arguments: tc.arguments,
                result: ToolExecutionResult.text(content),
              );
              continue;
            }

            // Check if this is a paw tool call (shepaw CLI)
            if (ShepawCLI.instance.isPawTool(tc.name)) {
              // 检查该 agent 是否有权限执行此 CLI 命令
              final enabledCliCommands = agent.enabledCliCommands;
              final namespace = tc.arguments['namespace'] as String? ?? '';
              final subcommand = tc.arguments['subcommand'] as String? ?? '';
              final commandId =
                  subcommand.isNotEmpty ? '$namespace.$subcommand' : namespace;

              if (enabledCliCommands.isNotEmpty) {
                // Agent 有明确的 CLI 命令限制 → 检查该命令是否被允许
                if (!enabledCliCommands.contains(commandId)) {
                  // 命令被禁止 → 返回拒绝错误
                  final denyResult = {
                    'error': 'CLI command "$commandId" is not allowed for this agent. Enabled commands: ${enabledCliCommands.join(", ")}',
                    'command': commandId,
                  };
                  toolResults.add({
                    'tool_call_id': tc.id,
                    'name': tc.name,
                    'result': jsonEncode(denyResult),
                  });
                  infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: jsonEncode(denyResult));
                  
                  // 持久化拒绝结果
                  await historyService.saveToolExecution(
                    messageId: agentMessageId,
                    channelId: effectiveChannelId,
                    toolCallId: tc.id,
                    toolName: tc.name,
                    arguments: tc.arguments,
                    result: ToolExecutionResult.text(jsonEncode(denyResult)),
                  );
                  continue;
                }
              }

              // Peer-inbound boundary: deny OS / memory writes by default.
              if (isPeerInbound &&
                  peerBoundary.blocksCli(
                    namespace: namespace,
                    subcommand: subcommand,
                  )) {
                final denyResult = {
                  'error':
                      'CLI command "$commandId" is blocked in peer external-serving mode.',
                  'command': commandId,
                  'peer_boundary': true,
                };
                toolResults.add({
                  'tool_call_id': tc.id,
                  'name': tc.name,
                  'result': jsonEncode(denyResult),
                });
                infLog.onToolResult(
                  activeTask.taskId,
                  toolCallId: tc.id,
                  name: tc.name,
                  result: jsonEncode(denyResult),
                );
                await historyService.saveToolExecution(
                  messageId: agentMessageId,
                  channelId: effectiveChannelId,
                  toolCallId: tc.id,
                  toolName: tc.name,
                  arguments: tc.arguments,
                  result: ToolExecutionResult.text(jsonEncode(denyResult)),
                );
                continue;
              }

              // OS 工具风险确认：非 safe 必须经用户批准
              final osConfirmDenied = await _confirmOsToolIfNeeded(
                activeTask: activeTask,
                args: tc.arguments,
                agentMessageId: agentMessageId,
                effectiveChannelId: effectiveChannelId,
                toolCall: tc,
                toolResults: toolResults,
                infLog: infLog,
                historyService: historyService,
              );
              if (osConfirmDenied) continue;

              // 命令被允许 → 继续执行。
              // 注入当前频道 id（与群聊执行器一致），agents.dispatch /
              // agents.chat 依赖它定位结果回传的目标频道。
              final cliArgs = Map<String, dynamic>.from(tc.arguments);
              if (effectiveChannelId.isNotEmpty) {
                final flags = cliArgs['flags'] is Map
                    ? Map<String, dynamic>.from(cliArgs['flags'] as Map)
                    : <String, dynamic>{};
                flags['channel_id'] = effectiveChannelId;
                cliArgs['flags'] = flags;
              }
              final result = await ShepawCLI.instance.execute(cliArgs, agentId: agent.id);
              toolResults.add({
                'tool_call_id': tc.id,
                'name': tc.name,
                'result': result,
              });
              infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: result);

              // 工作流计划创建（She 在 DM 中调用 shepaw workflow create）：
              // 与群聊执行器一致，检出 pending_approval 结果后通知控制器
              // 激活进度面板并把审批卡片挂到流式气泡；回合末再合并进持久化
              // 消息 metadata，保证频道重载后卡片仍可渲染。
              try {
                final cliJson = jsonDecode(result) as Map<String, dynamic>?;
                if (cliJson != null && cliJson['status'] == 'pending_approval') {
                  final workflowId = cliJson['workflow_id'] as String?;
                  final planDataRaw = cliJson['_plan_data'] as Map<String, dynamic>?;
                  if (workflowId != null && planDataRaw != null) {
                    final planData = {
                      ...planDataRaw,
                      '_workflowId': workflowId,
                      '_non_blocking': true,
                    };
                    planApprovalData = planData;
                    onWorkflowPlanCreated?.call(workflowId, planData);
                  }                }
              } catch (e) {
                LoggerService().warning('Workflow approval flow error: $e', tag: 'AgentMessagingService');
              }

              // 持久化工具执行结果
              await historyService.saveToolExecution(
                messageId: agentMessageId,
                channelId: effectiveChannelId,
                toolCallId: tc.id,
                toolName: tc.name,
                arguments: tc.arguments,
                result: ToolExecutionResult.text(result),
              );
              continue;
            }

            // Unknown tool — should not happen since we only expose known tools,
            // but handle gracefully.
            final unknownResult = jsonEncode({
              'error': 'Unknown tool: ${tc.name}. Use shepaw CLI to call OS/web tools.',
            });
            toolResults.add({
              'tool_call_id': tc.id,
              'name': tc.name,
              'result': unknownResult,
            });
            infLog.onToolResult(activeTask.taskId, toolCallId: tc.id, name: tc.name, result: unknownResult);

            // 持久化错误结果
            await historyService.saveToolExecution(
              messageId: agentMessageId,
              channelId: effectiveChannelId,
              toolCallId: tc.id,
              toolName: tc.name,
              arguments: tc.arguments,
              result: ToolExecutionResult.text(unknownResult),
            );
          }

          // Cap large tool results before appending — full results are
          // persisted via saveToolExecution and can be pulled on demand
          // through get_tool_result, so truncation loses no information.
          for (final tr in toolResults) {
            final r = tr['result'];
            final id = tr['tool_call_id'];
            if (r is String && id is String) {
              tr['result'] = LocalLLMHelpers.truncateToolResult(r, id);
            }
          }

          // Append assistant message + tool results to message history
          if (isClaude) {
            LocalLLMHelpers.appendToolRoundClaude(roundMessages, doneEvent!.rawAssistantMessage!, executableToolCalls, toolResults);
          } else {
            LocalLLMHelpers.appendToolRoundOpenAI(roundMessages, doneEvent!.rawAssistantMessage!, executableToolCalls, toolResults);
          }

          // Continue to next round
          continue;
        }

        // No actionable tool calls — done
        break;
      }

      activeTask.isComplete = true;
      activeTask.onTaskFinished?.call();

      final wasCancelled = acpCancellationToken?.isCancelled == true;
      infLog.endSession(activeTask.taskId, wasCancelled ? InferenceStatus.cancelled : InferenceStatus.completed);

      // Build metadata
      final meta = <String, dynamic>{};
      meta['trace_id'] = activeTask.taskId;
      if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra!);
      // Measured usage wins over any agent-injected `token_usage` key.
      if (turnTokenUsage.hasAny) {
        meta[LlmTokenUsage.metadataKey] = turnTokenUsage.toJson();
      }
      if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
      if (singleSelectData != null) meta['single_select'] = singleSelectData;
      if (multiSelectData != null) meta['multi_select'] = multiSelectData;
      if (fileUploadData != null) meta['file_upload'] = fileUploadData;
      if (formDataCapture != null) meta['form'] = formDataCapture;
      if (planApprovalData != null) meta['plan_approval'] = planApprovalData;
      final messageMetadata = meta;
      activeTask.metadata = messageMetadata;

      final responseContent = responseBuffer.toString();
      final visibleContent = responseContent;
      final String displayContent;
      if (wasCancelled) {
        displayContent = visibleContent.isNotEmpty
            ? '$visibleContent\n\n[Stopped]'
            : '[Stopped]';
      } else if (fileMessageHandled && visibleContent.trim().isEmpty) {
        displayContent = '[Used file_message tool]';
      } else if (historyRequestData != null && visibleContent.trim().isEmpty) {
        // Directive-style: no placeholder bubble — controller deletes & supplements.
        displayContent = '';
      } else {
        displayContent = visibleContent.isNotEmpty ? visibleContent : 'Task completed';
      }

      final agentResponse = Message(
        id: agentMessageId,
        content: displayContent,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        type: MessageType.text,
        replyTo: userMessage.id,
        metadata: messageMetadata,
      );

      await flushHelper.deletePartial();
      // request_history-only turns leave empty content; controller deletes the
      // bubble and runs the supplement flow — skip persisting a blank row.
      final skipSave = effectiveChannelId.isNotEmpty &&
          _userStoppedChannels.contains(effectiveChannelId);
      if (!skipSave &&
          (displayContent.isNotEmpty || historyRequestData == null)) {
        await saveMessageToChannel(agentResponse, agent.id, channelId: channelId);
        LoggerService().debug('Agent response saved', tag: 'AgentMessagingService');
      } else if (skipSave) {
        _userStoppedChannels.remove(effectiveChannelId);
        LoggerService().debug(
          'Skipping local LLM save — channel finalized by user stop',
          tag: 'AgentMessagingService',
        );
      } else {
        LoggerService().debug(
          'Skipped saving empty request_history response',
          tag: 'AgentMessagingService',
        );
      }

      // She 对话计数（记忆整理触发用）
      if (agent.metadata['is_she'] == true) {
        try {
          await SheService.instance.incrementConversationCount();
        } catch (e) {
          LoggerService().warning('She conversation count update failed: $e', tag: 'She');
        }
      }

      if (effectiveChannelId.isNotEmpty) {
        final task = _activeTasks.remove(effectiveChannelId);
        updateTypingAgentIds();
        if (task != null) {
          releaseForegroundTask(task.agentName);
          if (!task.dbSaveCompleter.isCompleted) {
            task.dbSaveCompleter.complete();
          }
        }
        _emitCompletion(
          channelId: effectiveChannelId,
          agent: agent,
          outcome: wasCancelled
              ? AgentTaskOutcome.stopped
              : AgentTaskOutcome.completed,
          finalMessage: agentResponse,
        );
      }

      return agentResponse;
    } catch (e, stackTrace) {
      LoggerService().error('Local LLM error', tag: 'AgentMessagingService', error: e, stackTrace: stackTrace);

      InferenceLogService.instance.endSession(activeTask.taskId, InferenceStatus.error, error: e.toString());

      activeTask.isComplete = true;
      activeTask.errorMessage = e.toString();
      activeTask.onTaskFinished?.call();

      await flushHelper.deletePartial();

      final errorMsg = Message(
        id: _uuid.v4(),
        content: 'Error: Failed to get response from LLM. Details: $e',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
      );
      await saveMessageToChannel(errorMsg, agent.id, channelId: channelId);

      if (effectiveChannelId.isNotEmpty) {
        final task = _activeTasks.remove(effectiveChannelId);
        updateTypingAgentIds();
        if (task != null) {
          releaseForegroundTask(task.agentName);
          if (!task.dbSaveCompleter.isCompleted) {
            task.dbSaveCompleter.complete();
          }
        }
        _emitCompletion(
          channelId: effectiveChannelId,
          agent: agent,
          outcome: AgentTaskOutcome.error,
          errorMessage: e.toString(),
        );
      }

      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// One-shot LLM summary of older chat turns for in-context compaction.
  Future<String> _summarizeHistoryForCompaction({
    required RemoteAgent agent,
    required String transcript,
    required Object cancelKey,
  }) async {
    if (transcript.trim().isEmpty) return '';

    final buf = StringBuffer();
    await for (final event in LocalLLMAgentService.instance.runWithCancelKey(
      cancelKey,
      () => LocalLLMAgentService.instance.chat(
        agent: agent,
        message: transcript,
        enableUITools: false,
        includeShepawCli: false,
        skipSheMemoryStack: true,
        systemPromptOverride: HistoryCompactor.summarizerSystemPrompt,
      ),
    )) {
      switch (event) {
        case LLMTextEvent():
          buf.write(event.text);
        case LLMToolCallEvent():
          // Compaction must not invoke tools.
          break;
        case LLMDoneEvent():
          break;
      }
    }
    return buf.toString().trim();
  }

  /// Returns `true` when the OS tool call was denied (caller should `continue`).
  Future<bool> _confirmOsToolIfNeeded({
    required ActiveTask activeTask,
    required Map<String, dynamic> args,
    required String agentMessageId,
    required String effectiveChannelId,
    required LLMToolCallEvent toolCall,
    required List<Map<String, dynamic>> toolResults,
    required InferenceLogService infLog,
    required HistoryService historyService,
  }) async {
    final namespace = args['namespace'] as String? ?? '';
    if (namespace != 'os') return false;

    final subcommand = args['subcommand'] as String? ?? '';
    if (subcommand.isEmpty) return false;

    final flagsRaw = args['flags'];
    final flags = <String, dynamic>{};
    if (flagsRaw is Map) {
      flags.addAll(Map<String, dynamic>.from(flagsRaw));
    }

    final cliPath = 'os.$subcommand';
    final toolName = OsToolRegistry.instance.resolveToolName(cliPath);
    final risk = os_exec.classifyRisk(toolName, flags);
    if (risk == os_exec.RiskLevel.safe) return false;

    final confirm = activeTask.onOsToolConfirmation;
    final approved = confirm == null
        ? false // No UI confirmation handler → deny non-safe OS tools
        : await confirm(toolName, flags, risk);

    if (approved) return false;

    final denyResult = {
      'error': 'OS tool "$cliPath" was denied by the user (risk: ${risk.name}).',
      'tool': toolName,
      'risk': risk.name,
    };
    final encoded = jsonEncode(denyResult);
    toolResults.add({
      'tool_call_id': toolCall.id,
      'name': toolCall.name,
      'result': encoded,
    });
    infLog.onToolResult(
      activeTask.taskId,
      toolCallId: toolCall.id,
      name: toolCall.name,
      result: encoded,
    );
    await historyService.saveToolExecution(
      messageId: agentMessageId,
      channelId: effectiveChannelId,
      toolCallId: toolCall.id,
      toolName: toolCall.name,
      arguments: args,
      result: ToolExecutionResult.text(encoded),
    );
    return true;
  }

  /// Formats a millisecond timestamp as "YYYY-MM-DD HH:MM:SS" (local time).
  String _formatTimestamp(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final y = dt.year.toString();
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi:$s';
  }

  Future<List<Map<String, dynamic>>?> _mailboxHistoryForSession(
    String? sessionId, {
    String? excludeMessageId,
  }) async {
    if (sessionId == null || sessionId.isEmpty) return null;
    final messages = await loadChannelMessages(sessionId, limit: 40);
    if (messages.isEmpty) return null;
    return messages
        .where((m) =>
            m.type != MessageType.system &&
            m.type != MessageType.permissionAudit &&
            m.id != excludeMessageId)
        .map((m) {
      final isAgent = m.from.isAgent;
      final rawContent = isAgent
          ? m.content
          : '[${_formatTimestamp(m.timestampMs)}] ${m.content}';
      return <String, dynamic>{
        'role': isAgent ? 'assistant' : 'user',
        'content': LocalLLMHelpers.enrichHistoryContent(m, rawContent),
      };
    }).toList();
  }

  /// Probe channel presence. Offline / busy → inbox only (no full body on tunnel).
  Future<Message?> _tryChannelInboxRoute({
    required RemoteAgent agent,
    required Message userMessage,
    String? sessionId,
    void Function(String chunk)? onStreamChunk,
  }) async {
    try {
      final channelBase =
          ChannelMailboxService.channelBaseFromEndpoint(agent.endpoint);
      final acpAgentId = (agent.metadata['target_agent_id'] as String?) ??
          ChannelMailboxService.resolveAgentId(
            agent.endpoint,
            fallback: agent.id,
          );
      if (channelBase == null || acpAgentId.isEmpty) return null;

      final identity = await NoiseIdentity.loadOrCreate();
      final presence = await ChannelMailboxService().probePresence(
        channelBase: channelBase,
        agentId: acpAgentId,
        callerFp: identity.fingerprintHex,
      );
      if (presence == null || !presence.useInbox) return null;

      LoggerService().info(
        'Channel inbox route: online=${presence.online} busy=${presence.busy} '
        'active=${presence.activeCount}/${presence.capacity}',
        tag: 'AgentMessagingService',
      );
      return leaveMailboxAndCollect(
        agent: agent,
        userMessage: userMessage,
        sessionId: sessionId ?? '',
        requestId: _uuid.v4(),
        chatHistory: await _mailboxHistoryForSession(
          sessionId,
          excludeMessageId: userMessage.id,
        ),
        onStreamChunk: onStreamChunk,
      );
    } catch (e) {
      LoggerService().debug(
        'Channel inbox route skipped: $e',
        tag: 'AgentMessagingService',
      );
      return null;
    }
  }

  /// Agent busy / unreachable → seal message into channel inbox, poll for reply.
  ///
  /// [groupId] is recorded on the inbound so the agent can attribute a group
  /// turn. [groupContext] (group name / member roster / workspace URI) is
  /// sealed into the ciphertext payload so the agent's mailbox path can
  /// reconstruct a full `group_context` (group tools + shared workspace stay
  /// usable while the app is offline). History is omitted or truncated so
  /// ciphertext stays under quota.
  Future<Message> leaveMailboxAndCollect({
    required RemoteAgent agent,
    required Message userMessage,
    required String sessionId,
    required String requestId,
    List<Map<String, dynamic>>? chatHistory,
    void Function(String chunk)? onStreamChunk,
    String? groupId,
    Map<String, dynamic>? groupContext,
    bool persistLeaveMetadata = true,
  }) async {
    Message notice({required String content}) => Message(
          id: const Uuid().v4(),
          content: content,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          to: MessageFrom(
            id: userMessage.from.id,
            type: 'user',
            name: userMessage.from.name,
          ),
          type: MessageType.system,
          replyTo: userMessage.id,
          metadata: {'status': 'left_message'},
        );

    try {
      final channelBase =
          ChannelMailboxService.channelBaseFromEndpoint(agent.endpoint);
      final agentPub = decodeCachedPeerPublicKey(
        agent.metadata['cached_peer_static_public_key'],
      );
      final acpAgentId = ChannelMailboxService.acpAgentIdFor(agent);

      if (channelBase == null || agentPub == null || acpAgentId.isEmpty) {
        LoggerService().warning(
          'Cannot leave mailbox message: missing channelBase/pubkey/agentId '
          '(LAN/local agents have no channel mailbox — this is expected)',
          tag: 'AgentMessagingService',
        );
        return notice(content: '对方正忙，请稍后再试。');
      }

      final identity = await NoiseIdentity.loadOrCreate();
      final trimmedHistory = _trimMailboxHistory(chatHistory);
      final ciphertext = await mailboxSealJson(
        {
          'message': userMessage.content,
          'message_id': userMessage.id,
          'request_id': requestId,
          'session_id': sessionId,
          if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
          if (groupContext != null && groupContext.isNotEmpty)
            'group_context': groupContext,
          if (trimmedHistory != null) 'history': trimmedHistory,
          'caller_pubkey': base64Encode(identity.publicKey),
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
        agentPub,
      );

      // Claim the turn BEFORE depositing: a fast reply push would otherwise
      // let the controller's inbox listener fetch+ack the reply before the
      // poller below starts, and the poller would wait out its full timeout.
      MailboxTurnClaims.instance.claim(acpAgentId, requestId, userMessage.id);
      try {
        final mailbox = ChannelMailboxService();
        final pending = await mailbox.depositMessage(
          channelBase: channelBase,
          agentId: acpAgentId,
          callerFp: identity.fingerprintHex,
          messageId: userMessage.id,
          requestId: requestId,
          sessionId: sessionId,
          ciphertext: ciphertext,
          groupId: groupId,
        );

        if (persistLeaveMetadata) {
          try {
            await _db.updateMessageMetadata(userMessage.id, {
              ...?userMessage.metadata,
              'status': 'left_message',
              'request_id': requestId,
              'mailbox_pending': pending,
            });
          } catch (e) {
            LoggerService().warning(
              'Mailbox leave metadata update skipped: $e',
              tag: 'AgentMessagingService',
            );
          }
        }

        try {
          final result = await MailboxInboxPoller(mailbox: mailbox)
              .pollUntilComplete(
            channelBase: channelBase,
            agentId: acpAgentId,
            callerFp: identity.fingerprintHex,
            userMessageId: userMessage.id,
            requestId: requestId,
            sessionId: sessionId,
            onStreamChunk: onStreamChunk,
          );

          return Message(
            id: 'inbox_${userMessage.id}',
            content: result.content,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
            to: MessageFrom(
              id: userMessage.from.id,
              type: 'user',
              name: userMessage.from.name,
            ),
            type: MessageType.text,
            replyTo: userMessage.id,
            metadata: {
              'status': 'completed',
              'from_mailbox': true,
              'mailbox_entry_id': result.entryId,
              'request_id': result.requestId,
              'session_id': result.sessionId,
              if (result.groupId != null && result.groupId!.isNotEmpty)
                'group_id': result.groupId,
            },
          );
        } on TimeoutException {
          return notice(
            content: pending > 0
                ? '对方正忙，消息已留言（前面还有 ${pending - 1} 条）。稍后会继续收取回复。'
                : '对方正忙，消息已留言。稍后会继续收取回复。',
          );
        }
      } finally {
        MailboxTurnClaims.instance.release(acpAgentId, requestId, userMessage.id);
      }
    } catch (e, st) {
      LoggerService().error(
        'Leave mailbox failed: $e',
        tag: 'AgentMessagingService',
        error: e,
        stackTrace: st,
      );
      return notice(content: '对方正忙，留言失败：$e');
    }
  }

  /// Keep mailbox ciphertext well under [MailboxMaxCipherBytes] (32KB).
  /// Session resume is the primary history source; this is a first-contact hint.
  static const _mailboxHistoryBudgetBytes = 8 * 1024;

  static List<Map<String, dynamic>>? _trimMailboxHistory(
    List<Map<String, dynamic>>? history,
  ) {
    if (history == null || history.isEmpty) return null;
    var trimmed = List<Map<String, dynamic>>.from(history);
    while (trimmed.isNotEmpty) {
      final bytes = utf8.encode(jsonEncode(trimmed)).length;
      if (bytes <= _mailboxHistoryBudgetBytes) return trimmed;
      trimmed.removeAt(0);
    }
    return null;
  }
}
