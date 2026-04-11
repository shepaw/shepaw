import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/inference_log_entry.dart';
import '../../models/tool_execution_result.dart';
import '../local_database_service.dart';
import '../tool_result_database_service.dart';
import '../acp_agent_connection.dart';
import '../agent_prompt_builder.dart';
import '../local_llm_agent_service.dart';
import '../task/task_models.dart';
import '../../clis/shepaw/os/os_executor.dart' as os_exec;
import '../skill_registry.dart';
import '../model_registry.dart';
import '../ui_component_registry.dart';
import '../inference_log_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../she_service.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../session/session_history_service.dart';
import 'local_llm_handler.dart';

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

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

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
  }) async {
    LoggerService().debug('sendMessageToAgent: agentId=${agent.id}, name=${agent.name}, protocol=${agent.protocol}, status=${agent.status}, endpoint=${agent.endpoint}', tag: 'AgentMessagingService');

    try {
      // Check if this is a local LLM agent — bypass status/endpoint checks
      if (LocalLLMAgentService.instance.isLocalAgent(agent)) {
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
          onOsToolConfirmation: onOsToolConfirmation,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
          existingUserMessage: existingUserMessage,
        );
      }

      // Check if agent is online
      if (agent.status != AgentStatus.online) {
        LoggerService().error('Agent ${agent.name} is not online (status: ${agent.status})', tag: 'AgentMessagingService');
        throw Exception('Agent ${agent.name} is not online');
      }
      LoggerService().info('Agent is online', tag: 'AgentMessagingService');

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

      if (agent.protocol == ProtocolType.acp) {
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
        );
      } else {
        // For other protocols, use generic HTTP POST
        LoggerService().debug('Using generic protocol', tag: 'AgentMessagingService');
        agentResponse = await _sendViaGenericProtocol(messageToSend, agent);
      }

      // Save agent response if received
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
      }
      return null;
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
  }) async {
    LoggerService().info('Starting ACP WebSocket protocol, endpoint: ${agent.endpoint}', tag: 'AgentMessagingService');

    ACPAgentConnection? connection;
    String? taskId;

    try {
      // Get or create connection for this agent
      connection = await _getOrCreateACPConnection(agent);

      // Create task ID
      taskId = _uuid.v4();

      // Bind cancellation token
      acpCancellationToken?.bind(connection, taskId);

      // Create ActiveTask for background tracking
      final effectiveChannelId = sessionId ?? '';
      final activeTask = ActiveTask(
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
                final entry = <String, dynamic>{
                  'role': isAgent ? 'assistant' : 'user',
                  'content': isAgent ? m.content : '[${_formatTimestamp(m.timestampMs)}] ${m.content}',
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

      // Hook cancellation token so the completer resolves immediately on cancel.
      acpCancellationToken?.onCancelled = () {
        activeTask.isComplete = true;
        if (!taskCompleter.isCompleted) {
          taskCompleter.complete();
        }
      };

      // Set up connection callbacks — accumulate in ActiveTask, then forward to UI
      final effectiveTaskId = taskId;
      connection.registerTaskCallbacks(effectiveTaskId, TaskCallbacks(
        onTextContent: (data) {
          final content = data['content'] as String? ?? '';
          activeTask.accumulatedContent += content;
          activeTask.onStreamChunk?.call(content);
          infLogAcp.onTextChunk(effectiveTaskId, content);
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
          messageMetadataExtra = Map<String, dynamic>.from(data);
          activeTask.onMessageMetadata?.call(data);
        },
        onRequestHistory: (data) {
          activeTask.onRequestHistory?.call(data);
        },
        onTaskCompleted: (data) {
          infLogAcp.endRound(effectiveTaskId, stopReason: 'stop');
          infLogAcp.endSession(effectiveTaskId, InferenceStatus.completed);
          activeTask.isComplete = true;
          activeTask.onTaskFinished?.call();
          if (!taskCompleter.isCompleted) {
            taskCompleter.complete();
          }
        },
        onTaskError: (data) {
          final errorMsg = data['message'] as String? ?? 'Task error';
          infLogAcp.endRound(effectiveTaskId, stopReason: 'error');
          infLogAcp.endSession(effectiveTaskId, InferenceStatus.error, error: errorMsg);
          activeTask.isComplete = true;
          activeTask.errorMessage = errorMsg;
          activeTask.onTaskFinished?.call();
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
      await connection.sendChatMessage(
        taskId: effectiveTaskId,
        sessionId: sessionId ?? '',
        message: userMessage.content,
        userId: userMessage.from.id,
        messageId: userMessage.id,
        history: chatHistory,
        totalMessageCount: totalMessageCount,
        systemPrompt: dmSystemPrompt ?? agent.metadata['system_prompt'] as String?,
        attachments: serializedAttachments,
      );

      // Wait for task.completed, task.error, or local cancellation
      final taskTimeoutSeconds = (agent.metadata?['task_timeout_seconds'] as num?)?.toInt() ?? 600;
      await taskCompleter.future.timeout(
        Duration(seconds: taskTimeoutSeconds),
        onTimeout: () {
          throw TimeoutException('ACP task timed out');
        },
      );

      // If cancelled, clean up callbacks and return partial content.
      if (acpCancellationToken?.isCancelled == true) {
        connection.unregisterTaskCallbacks(effectiveTaskId);
        final responseContent = activeTask.accumulatedContent;
        return Message(
          id: _uuid.v4(),
          content: responseContent.isNotEmpty
              ? '$responseContent\n\n[Stopped]'
              : '[Stopped]',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          to: MessageFrom(id: userMessage.from.id, type: 'user', name: userMessage.from.name),
          type: MessageType.text,
          replyTo: userMessage.id,
        );
      }

      // Build metadata
      final meta = <String, dynamic>{};
      meta['trace_id'] = activeTask.taskId;
      if (messageMetadataExtra != null) {
        meta.addAll(messageMetadataExtra!);
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
      final messageMetadata = meta;
      activeTask.metadata = messageMetadata;

      // Clear callbacks and remove from active tasks
      connection.unregisterTaskCallbacks(effectiveTaskId);
      // NOTE: Don't remove from _activeTasks here — sendMessageToAgent will
      // do it after persisting the response to DB so the UI can await the save.

      final responseContent = activeTask.accumulatedContent;
      return Message(
        id: _uuid.v4(),
        content: responseContent.isNotEmpty ? responseContent : 'Task completed',
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
        metadata: messageMetadata,
      );
    } catch (e, stackTrace) {
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
    _acpConnections[agent.id] = connection;

    // 监听连接状态变化，实时更新 Agent 在线/离线状态
    connection.onConnectionStateChanged = (bool connected) {
      if (!connected) {
        _db.updateRemoteAgentStatus(agent.id, 'offline').catchError((_) {});
        _acpConnections.remove(agent.id);
        LoggerService().info('ACP connection offline: ${agent.name}', tag: 'AgentMessagingService');
      }
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

    await connection.connect(wsUrl, agent.token,
        targetAgentId: agent.metadata['target_agent_id'] as String?);
    return connection;
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
    Future<bool> Function(String, Map<String, dynamic>, os_exec.RiskLevel)? onOsToolConfirmation,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
    Message? existingUserMessage,
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
    activeTask.onOsToolConfirmation = onOsToolConfirmation;

    if (effectiveChannelId.isNotEmpty) {
      _activeTasks[effectiveChannelId] = activeTask;
      updateTypingAgentIds();
    }
    ForegroundTaskService().acquireTask(agent.name);

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
      final promptConfig = agent.promptStackConfig;
      final includeShepawCli = promptConfig.tools.includeShepawCli;
      final List<Map<String, dynamic>> combinedTools;
      if (isClaude) {
        combinedTools = [
          ...UIComponentRegistry.instance.claudeTools(),
          // OS/web tools are now accessed through shepaw CLI (os/web namespaces)
          if (hasSkills && promptConfig.tools.includeSkills) ...skillRegistry.claudeTools(enabledSkills: enabledSkills),
          if (hasToolModels && promptConfig.tools.includeToolModels) ...toolModelRegistry.claudeTools(enabledToolModels: enabledToolModels, scenarioOverrides: toolModelScenarios),
          if (includeShepawCli) ShepawCLI.instance.claudeTool(),
        ];
      } else {
        combinedTools = [
          ...UIComponentRegistry.instance.openAITools(),
          // OS/web tools are now accessed through shepaw CLI (os/web namespaces)
          if (hasSkills && promptConfig.tools.includeSkills) ...skillRegistry.openAITools(enabledSkills: enabledSkills),
          if (hasToolModels && promptConfig.tools.includeToolModels) ...toolModelRegistry.openAITools(enabledToolModels: enabledToolModels, scenarioOverrides: toolModelScenarios),
          if (includeShepawCli) ShepawCLI.instance.openAITool(),
        ];
      }

      // Build system prompt via AgentPromptBuilder (handles She and all other
      // agents uniformly; dmSystemPrompt is passed as the DM-channel override).
      final systemPrompt = await AgentPromptBuilder(
        agent: agent,
        dmSystemPromptOverride: dmSystemPrompt,
      ).buildSystemPrompt();

      // Load history — include attachment messages for context
      const historyLimit = 20;
      final List<Map<String, dynamic>> chatHistory = [];
      if (channelId != null) {
        final messages = await loadChannelMessages(channelId, limit: historyLimit);
        if (messages.isNotEmpty) {
          for (final m in messages) {
            if (m.type != MessageType.system && m.type != MessageType.permissionAudit && m.id != userMessage.id) {
              final isAgent = m.from.isAgent;
              final entry = <String, dynamic>{
                'role': isAgent ? 'assistant' : 'user',
                'content': isAgent ? m.content : '[${_formatTimestamp(m.timestampMs)}] ${m.content}',
              };
              if (m.type != MessageType.text && m.type != MessageType.system) {
                entry['attachment_info'] = LocalLLMHelpers.buildAttachmentInfo(m);
              }
              chatHistory.add(entry);
            }
          }
        }
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
        effectiveContent, attachments, isClaude,
      ));

      // Hook cancellation token
      acpCancellationToken?.onCancelled = () {
        LocalLLMAgentService.instance.abort();
      };

      // If no tools at all (no CLI, no skills, no tool models),
      // fall back to the simpler single-round path
      if (!includeShepawCli && !hasSkills && !hasToolModels) {
        return await _sendViaLocalLLMSingleRound(
          agent: agent,
          content: effectiveContent,
          userId: userId,
          userName: userName,
          channelId: channelId,
          userMessage: userMessage,
          activeTask: activeTask,
          effectiveChannelId: effectiveChannelId,
          acpCancellationToken: acpCancellationToken,
          attachments: attachments,
        );
      }

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
      final historyService = HistoryService(_db, _toolResultDb);

      final responseBuffer = StringBuffer();
      Map<String, dynamic>? actionConfirmationData;
      Map<String, dynamic>? singleSelectData;
      Map<String, dynamic>? multiSelectData;
      Map<String, dynamic>? fileUploadData;
      Map<String, dynamic>? formDataCapture;
      Map<String, dynamic>? messageMetadataExtra;
      bool fileMessageHandled = false;

      final maxToolRounds = (agent.metadata?['max_tool_rounds'] as num?)?.toInt() ?? 100;

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

        await for (final event in LocalLLMAgentService.instance.chatRound(
          agent: agent,
          messages: roundMessages,
          tools: combinedTools,
          systemPrompt: isClaude ? systemPrompt : null,
          attachments: round == 0 ? attachments : null,
        )) {
          if (acpCancellationToken?.isCancelled == true) break;

          switch (event) {
            case LLMTextEvent():
              responseBuffer.write(event.text);
              activeTask.accumulatedContent += event.text;
              activeTask.onStreamChunk?.call(event.text);
              infLog.onTextChunk(activeTask.taskId, event.text);
              break;

            case LLMToolCallEvent():
              toolCallEvents.add(event);
              infLog.onToolCall(activeTask.taskId, id: event.id, name: event.name, arguments: event.arguments);
              break;

            case LLMDoneEvent():
              doneEvent = event;
              infLog.endRound(activeTask.taskId, stopReason: event.stopReason);
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
        for (final tc in toolCallEvents) {
          if (tc.name == LocalLLMHelpers.kGetToolResult) {
            getToolResultCalls.add(tc);
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
                bool? fmh,
              }) {
                if (ac != null) actionConfirmationData = ac;
                if (ss != null) singleSelectData = ss;
                if (ms != null) multiSelectData = ms;
                if (fu != null) fileUploadData = fu;
                if (fd != null) formDataCapture = fd;
                if (mm != null) messageMetadataExtra = mm;
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
        final executableToolCalls = [...skillToolCalls, ...toolModelCalls, ...pawToolCalls];
        if (executableToolCalls.isNotEmpty && doneEvent?.rawAssistantMessage != null) {
          final toolResults = <Map<String, dynamic>>[];

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
              if (enabledCliCommands.isNotEmpty) {
                // Agent 有明确的 CLI 命令限制 → 检查该命令是否被允许
                final namespace = tc.arguments['namespace'] as String? ?? '';
                final subcommand = tc.arguments['subcommand'] as String? ?? '';
                final commandId = subcommand.isNotEmpty ? '$namespace.$subcommand' : namespace;
                
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
              // 命令被允许 → 继续执行
              final result = await ShepawCLI.instance.execute(tc.arguments, agentId: agent.id);
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
      if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
      if (singleSelectData != null) meta['single_select'] = singleSelectData;
      if (multiSelectData != null) meta['multi_select'] = multiSelectData;
      if (fileUploadData != null) meta['file_upload'] = fileUploadData;
      if (formDataCapture != null) meta['form'] = formDataCapture;
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

      await saveMessageToChannel(agentResponse, agent.id, channelId: channelId);
      LoggerService().debug('Agent response saved', tag: 'AgentMessagingService');

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
      }

      return agentResponse;
    } catch (e, stackTrace) {
      LoggerService().error('Local LLM error', tag: 'AgentMessagingService', error: e, stackTrace: stackTrace);

      InferenceLogService.instance.endSession(activeTask.taskId, InferenceStatus.error, error: e.toString());

      activeTask.isComplete = true;
      activeTask.errorMessage = e.toString();
      activeTask.onTaskFinished?.call();

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
      }

      return null;
    }
  }

  /// Simple single-round path (no OS tools) — preserves original behavior.
  Future<Message?> _sendViaLocalLLMSingleRound({
    required RemoteAgent agent,
    required String content,
    required String userId,
    required String userName,
    String? channelId,
    required Message userMessage,
    required ActiveTask activeTask,
    required String effectiveChannelId,
    ACPCancellationToken? acpCancellationToken,
    List<AttachmentData>? attachments,
  }) async {
    const historyLimit = 20;
    List<Map<String, dynamic>>? chatHistory;
    if (channelId != null) {
      final messages = await loadChannelMessages(channelId, limit: historyLimit);
      if (messages.isNotEmpty) {
        chatHistory = messages
            .where((m) => m.type != MessageType.system && m.type != MessageType.permissionAudit && m.id != userMessage.id)
            .map((m) {
              final isAgent = m.from.isAgent;
              final entry = <String, dynamic>{
                'role': isAgent ? 'assistant' : 'user',
                'content': isAgent ? m.content : '[${_formatTimestamp(m.timestampMs)}] ${m.content}',
              };
              if (m.type != MessageType.text && m.type != MessageType.system) {
                entry['attachment_info'] = LocalLLMHelpers.buildAttachmentInfo(m);
              }
              return entry;
            })
            .toList();
      }
    }

    final responseBuffer = StringBuffer();
    final infLog = InferenceLogService.instance;
    infLog.beginSession(
      sessionId: activeTask.taskId,
      agentId: agent.id,
      agentName: agent.name,
      channelId: channelId ?? effectiveChannelId,
      provider: agent.metadata['llm_provider'] as String?,
      model: agent.metadata['llm_model'] as String?,
      executionMode: 'local_single_round',
      userMessage: content,
    );
    final singleRoundMessages = <Map<String, dynamic>>[
      ...?chatHistory,
      {'role': 'user', 'content': content},
    ];
    infLog.beginRound(
      activeTask.taskId,
      requestSummary: 'Single round',
      messages: singleRoundMessages,
    );

    Map<String, dynamic>? actionConfirmationData;
    Map<String, dynamic>? singleSelectData;
    Map<String, dynamic>? multiSelectData;
    Map<String, dynamic>? fileUploadData;
    Map<String, dynamic>? formDataCapture;
    Map<String, dynamic>? messageMetadataExtra;
    bool fileMessageHandled = false;

    await for (final event
        in LocalLLMAgentService.instance.chat(
          agent: agent,
          message: content,
          history: chatHistory,
          attachments: attachments,
        )) {
      if (acpCancellationToken?.isCancelled == true) break;

      switch (event) {
        case LLMTextEvent():
          responseBuffer.write(event.text);
          activeTask.accumulatedContent += event.text;
          activeTask.onStreamChunk?.call(event.text);
          infLog.onTextChunk(activeTask.taskId, event.text);
          break;

        case LLMToolCallEvent():
          infLog.onToolCall(activeTask.taskId, id: event.id, name: event.name, arguments: event.arguments);
          final args = event.arguments;
          switch (event.name) {
            case 'action_confirmation':
              actionConfirmationData = Map<String, dynamic>.from(args);
              activeTask.onActionConfirmation?.call(args);
              break;
            case 'single_select':
              singleSelectData = Map<String, dynamic>.from(args);
              activeTask.onSingleSelect?.call(args);
              break;
            case 'multi_select':
              multiSelectData = Map<String, dynamic>.from(args);
              activeTask.onMultiSelect?.call(args);
              break;
            case 'file_upload':
              fileUploadData = Map<String, dynamic>.from(args);
              activeTask.onFileUpload?.call(args);
              break;
            case 'form':
              formDataCapture = Map<String, dynamic>.from(args);
              activeTask.onForm?.call(args);
              break;
            case 'file_message':
              fileMessageHandled = true;
              await activeTask.onFileMessage?.call(args);
              break;
            case 'message_metadata':
              messageMetadataExtra = Map<String, dynamic>.from(args);
              activeTask.onMessageMetadata?.call(args);
              break;
          }
          break;

        case LLMDoneEvent():
          infLog.endRound(activeTask.taskId, stopReason: event.stopReason);
          break;
      }
    }

    final wasCancelledSR = acpCancellationToken?.isCancelled == true;
    infLog.endSession(activeTask.taskId, wasCancelledSR ? InferenceStatus.cancelled : InferenceStatus.completed);

    activeTask.isComplete = true;
    activeTask.onTaskFinished?.call();

    final wasCancelled = acpCancellationToken?.isCancelled == true;

    Map<String, dynamic>? messageMetadata;
    final meta = <String, dynamic>{};
    meta['trace_id'] = activeTask.taskId;
    if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra);
    if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
    if (singleSelectData != null) meta['single_select'] = singleSelectData;
    if (multiSelectData != null) meta['multi_select'] = multiSelectData;
    if (fileUploadData != null) meta['file_upload'] = fileUploadData;
    if (formDataCapture != null) meta['form'] = formDataCapture;
    messageMetadata = meta;
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
    } else {
      displayContent = visibleContent.isNotEmpty ? visibleContent : 'Task completed';
    }

    final agentResponse = Message(
      id: _uuid.v4(),
      content: displayContent,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: userMessage.id,
      metadata: messageMetadata,
    );

    await saveMessageToChannel(agentResponse, agent.id, channelId: channelId);
    LoggerService().debug('Agent response saved', tag: 'AgentMessagingService');

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
    }

    return agentResponse;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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
}
