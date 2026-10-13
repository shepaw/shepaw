import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/attachment_data.dart';
import '../../models/inference_log_entry.dart';
import '../local_database_service.dart';
import '../acp_agent_connection.dart';
import '../task/task_models.dart';
import '../../clis/shepaw/os/os_executor.dart' as os_exec;
import '../inference_log_service.dart';
import '../trace_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../../peer/host_she_turn.dart';
import '../../peer/pouch_roster.dart';
import '../../peer/pouch_turn_relay.dart';
import '../peer_key_utils.dart';
import '../session/session_slash_commands.dart';
import '../remote_agent_service.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/services/peer_inflight_turn.dart';
import '../../service_locator.dart' show getIt;
import 'chat_history_content.dart';
import 'message_implicit_prompt.dart';
import 'stream_content_splitter.dart';
import 'streaming_flush_helper.dart';

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
  final Uuid _uuid;
  final Map<String, ActiveTask> _activeTasks;
  final Future<void> Function(Message message, String agentId, {String? channelId}) saveMessageToChannel;
  final void Function() updateTypingAgentIds;
  final void Function(String agentName) releaseForegroundTask;
  final Future<List<Message>> Function(String channelId, {int limit}) loadChannelMessages;
  final Future<Message?> Function(String id) getMessageById;

  AgentMessagingService({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, ActiveTask> activeTasks,
    required this.saveMessageToChannel,
    required this.updateTypingAgentIds,
    required this.releaseForegroundTask,
    required this.loadChannelMessages,
    required this.getMessageById,
  })  : _db = db,
        _uuid = uuid,
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
            final progress = progressMeta['progress_content'];
            if (progress is String) {
              // 同步进任务级进度缓冲，纯 thinking 阶段 flush 才能落库。
              activeTask.progressContent = progress;
            }
            activeTask.onMessageMetadata?.call(progressMeta);
            // thinking 帧也要启动 flush（理由同 ACP 路径）。
            flushHelper.schedule();
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
      onForm: (data) {
        final form = Map<String, dynamic>.from(data);
        final meta = Map<String, dynamic>.from(activeTask.metadata ?? {});
        meta['form'] = form;
        activeTask.metadata = meta;
        activeTask.onMessageMetadata?.call({'form': form});
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

  /// 登记在途 DM 回合。
  ///
  /// 新回合天然属于新的一代：登记时顺手丢掉该频道可能残留的「用户停止」标记
  /// （[_userStoppedChannels]）。上一回合被停止后若以异常收尾（例如
  /// cursor-agent 被取消后回 `task.error`），它走不到 [sendMessageToAgent]
  /// 里的消费点，标记就会残留；若不清理，下一回合会把新回复误判成「已被
  /// 停止」而丢弃——表现为「停止 → 重新编辑 → 重发」后回复不出来。
  void _registerActiveTask(String channelId, ActiveTask task) {
    if (channelId.isEmpty) return;
    _userStoppedChannels.remove(channelId);
    _activeTasks[channelId] = task;
    updateTypingAgentIds();
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

  /// Build user-message metadata: implicit-prompt (pouch://) hints merged
  /// with the instruction-set title marker (bubble shows only the title).
  static Map<String, dynamic>? _userMessageMetadata({
    required String content,
    List<AttachmentData>? attachments,
    String? instructionName,
    String? replyQuoteText,
  }) {
    Map<String, dynamic>? meta =
        MessageImplicitPrompt.metadataForTurn(text: content, attachments: attachments);
    if (instructionName != null && instructionName.isNotEmpty) {
      meta ??= <String, dynamic>{};
      meta['instruction'] = instructionName;
    }
    // 引用回复：选中部分文字随落库 metadata 持久化，气泡引用块优先展示。
    if (replyQuoteText != null && replyQuoteText.isNotEmpty) {
      meta ??= <String, dynamic>{};
      meta['reply_quote'] = replyQuoteText;
    }
    return meta;
  }

  Future<Message?> sendMessageToAgent({
    required String content,
    required RemoteAgent agent,
    required String userId,
    required String userName,
    String? channelId,
    String? replyToId,
    /// 引用回复时选中的部分文字（可选）；为空表示引用整条消息。
    String? replyQuoteText,
    String? dmSystemPrompt,
    /// 推理日志的 `executionMode` 标记（如事件感知回合 `event_perception`）；
    /// 为空时维持默认的 `local_multi_round`。
    String? executionMode,
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
    /// 指令集标题：写入用户消息 metadata，气泡只展示标题、内容隐式投递。
    String? instructionName,
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
      // 本机 LLM，或主机上的惜宝。后者不走 agent_chat：CLI 只在储物袋回合里认她。
      if (agent.isLocal || relaysHostSheTurn(agent)) {
        LoggerService().debug('Detected local LLM agent, using local LLM path', tag: 'AgentMessagingService');
        return await _sendViaLocalLLM(
          content: content,
          agent: agent,
          userId: userId,
          userName: userName,
          channelId: channelId,
          replyToId: replyToId,
          dmSystemPrompt: dmSystemPrompt,
          executionMode: executionMode,
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
          metadata: _userMessageMetadata(
            content: content,
            attachments: attachments,
            instructionName: instructionName,
            replyQuoteText: replyQuoteText,
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
          // 引用回复：优先用选中的部分文字，未选中时退回整条消息。
          final quoteText = userMessage.replyQuoteText ?? quotedMsg.content;
          messageToSend = Message(
            id: userMessage.id,
            content: '[引用 ${quotedMsg.from.name} 的消息: "$quoteText"]\n\n${userMessage.content}',
            timestampMs: userMessage.timestampMs,
            from: userMessage.from,
            to: userMessage.to,
            type: userMessage.type,
            replyTo: userMessage.replyTo,
            metadata: userMessage.metadata,
          );
        }
      }

      // Send message to agent based on protocol
      Message? agentResponse;
      LoggerService().debug('Preparing to send message via ${agent.protocol} protocol', tag: 'AgentMessagingService');

      if (agent.protocol == ProtocolType.peer) {
        LoggerService().debug('Using peer protocol', tag: 'AgentMessagingService');
        agentResponse = await _sendViaPeerProtocol(
          messageToSend, agent,
          onStreamChunk: onStreamChunk,
          onActionConfirmation: onActionConfirmation,
          onForm: onForm,
          onMessageMetadata: onMessageMetadata,
          sessionId: channelId,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
        );
      } else if (agent.protocol == ProtocolType.acp) {
        // ACP 是已废弃的直连协议：它唯一的服务方（agent-bridge）已下线，主机
        // 只认 /peer/ws —— 直连白名单和 Channel 隧道都不放行 /acp/ws。这类行
        // 的 endpoint 必然连不上，与其让它转圈到超时，不如直接告诉用户重新配对。
        LoggerService().warning(
          'ACP agent is unreachable (protocol retired): ${agent.id}',
          tag: 'AgentMessagingService',
        );
        agentResponse =
            _systemNotice('这个 Agent 已不可用，请改用 Hub 配对后添加');
      } else {
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

      // 本回合以失败收尾，走不到上面的「用户停止」消费点，必须自己把标记带走；
      // 否则它会残留到该频道下一回合，新回复被误判成「已被停止」而丢弃。
      if (channelId != null) {
        _userStoppedChannels.remove(channelId);
      }

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



  /// 掉线后重连成功：把还没结束的回合用 `agent.taskResume` 续回来。
  ///
  /// WS 断掉时主机上的回合照常在跑，SDK 会把 replay buffer 里落下的输出补回来
  /// —— [ActiveTask.rawStreamLength] 是已经显示过的前缀长度，正好是 resume 需要
  /// 的 `known_length`。续不回来时 resume 会回 `lost`，走正常的 onTaskError。
  ///
  /// 只续回调还挂在这条连接上的回合：回调是注册在连接对象上的，换了对象就无处
  /// 投递，这种情况交给那条旧连接自己的重连窗口去收尾。
  void _resumeTurnsAfterReconnect(String agentId, ACPAgentConnection connection) {
    final pending = _activeTasks.values
        .where((t) => t.agentId == agentId && !t.isComplete)
        .where((t) => connection.hasTask(t.taskId))
        .toList();
    if (pending.isEmpty) return;
    LoggerService().info(
      'ACP reconnected, resuming ${pending.length} in-flight turn(s) for $agentId',
      tag: 'AgentMessagingService',
    );
    for (final task in pending) {
      unawaited(
        connection.resumeTaskAndDispatch(task.taskId, task.rawStreamLength),
      );
    }
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
    void Function(Map<String, dynamic> formData)? onForm,
    void Function(Map<String, dynamic> metadata)? onMessageMetadata,
    String? sessionId,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
  }) async {
    final sourcePeerId = agent.sourcePeerId;
    final sourceRemoteAgentId = agent.remoteAgentId;
    if (sourcePeerId == null || sourceRemoteAgentId == null) {
      throw Exception('Peer agent missing source_peer_id/remote_agent_id');
    }
    final dial = await PouchRosterDial.decideLive(
      fallbackPeerId: sourcePeerId,
      remoteAgentId: sourceRemoteAgentId,
      hubFingerprint: agent.metadata['roster_hub_fingerprint'] as String?,
    );
    if (dial.blocked) {
      throw Exception(PouchRosterDial.blockedMessage);
    }
    final peerId = dial.peerId ?? sourcePeerId;
    final remoteAgentId = dial.remoteAgentId ?? sourceRemoteAgentId;

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
    _registerActiveTask(effectiveChannelId, activeTask);
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
                ChatHistoryContent.shouldReplay(m) && m.id != userMessage.id)
            .map((m) {
              final isAgent = m.from.isAgent;
              return <String, dynamic>{
                'role': isAgent ? 'assistant' : 'user',
                'content': ChatHistoryContent.replayContent(m),
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
      final progress = meta['progress_content'];
      if (progress is String) {
        // 同步进任务级进度缓冲，纯 thinking 阶段 flush 才能落库。
        activeTask.progressContent = progress;
      }
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
        message: ShepawSessionSlashCommands.expandForModel(
          MessageImplicitPrompt.forPeerWireMessage(
            message: userMessage.content,
            attachments: attachments,
            messageMetadata: userMessage.metadata,
          ),
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
            if (progressMeta != null) {
              publishMetadata(progressMeta);
              // thinking 帧也要启动 flush（理由同 ACP 路径）。
              flushHelper.schedule();
            }
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
        onForm: (data) {
          final form = Map<String, dynamic>.from(data);
          final meta = Map<String, dynamic>.from(activeTask.metadata ?? {});
          meta['form'] = form;
          activeTask.metadata = meta;
          final cb = onForm ?? activeTask.onMessageMetadata;
          if (onForm != null) {
            onForm(form);
          } else {
            cb?.call({'form': form});
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
      final liveForm = activeTask.metadata?['form'];
      if (liveForm is Map) {
        meta['form'] = Map<String, dynamic>.from(liveForm);
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
    String? executionMode,
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

    final route = await PouchTurnRelay.currentRoute();
    if (!route.runLocal) {
      final result = await PouchTurnRelay.instance.forwardDm(
        hostPeerId: route.hostPeerId!,
        agentId: relaysHostSheTurn(agent)
            ? hostSheTurnAgentId(agent)
            : agent.id,
        content: content,
        userId: userId,
        userName: userName,
        channelId: channelId,
        userMessageId: userMessage.id,
        attachments: attachments,
        onStreamChunk: onStreamChunk,
        onInteractionRequest: (agentId, agentName, interactionType, data) async {
          if (interactionType != 'os_tool' || onOsToolConfirmation == null) {
            return null;
          }
          final riskName = data['risk'] as String? ?? '';
          final risk = os_exec.RiskLevel.values.asNameMap()[riskName] ??
              os_exec.RiskLevel.highRisk;
          final args = data['args'];
          final approved = await onOsToolConfirmation(
            data['tool_name'] as String? ?? '',
            args is Map ? args.cast<String, dynamic>() : <String, dynamic>{},
            risk,
          );
          return {'approved': approved};
        },
      );
      final agentResponse = Message(
        id: result.agentMessageId ?? _uuid.v4(),
        content: result.text,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        type: MessageType.text,
      );
      try {
        await saveMessageToChannel(
          agentResponse,
          agent.id,
          channelId: channelId,
        );
      } catch (error) {
        final duplicate = result.agentMessageId != null &&
            error.toString().contains('UNIQUE');
        if (!duplicate) rethrow;
      }
      return agentResponse;
    }

    final notice = Message(
      id: _uuid.v4(),
      content: '模型已经搬到 Hub，这台设备不再调用。',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
    );
    await saveMessageToChannel(notice, agent.id, channelId: channelId);
    return notice;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------


  /// 主机不可达 / 正忙时落在会话里的系统消息。
  ///
  /// 以前这种情况会把消息加密投进 Channel 信箱，等主机上线来取。主机常开之后
  /// 不需要暂存了 —— 发不出去就直接告诉用户，别让他以为发出去了。
  Message _systemNotice(String content) => Message(
        id: _uuid.v4(),
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
      );
}

