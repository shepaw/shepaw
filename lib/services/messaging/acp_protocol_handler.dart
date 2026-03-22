import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/attachment_data.dart';
import '../../models/acp_protocol.dart';
import '../../models/inference_log_entry.dart';
import '../acp_agent_connection.dart';
import '../local_database_service.dart';
import '../inference_log_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../task/task_models.dart';

/// Callbacks used to bridge the ACPProtocolHandler with ChatService state.
class ACPHandlerCallbacks {
  final Map<String, ActiveTask> activeTasks;
  final Map<String, ACPAgentConnection> acpConnections;
  final void Function() updateTypingAgentIds;
  final Future<List<Map<String, dynamic>>?> Function(String channelId) loadChannelHistoryForACP;

  const ACPHandlerCallbacks({
    required this.activeTasks,
    required this.acpConnections,
    required this.updateTypingAgentIds,
    required this.loadChannelHistoryForACP,
  });
}

/// Handles ACP (WebSocket) protocol communication.
class ACPProtocolHandler {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final ACPHandlerCallbacks _callbacks;

  ACPProtocolHandler({
    required LocalDatabaseService db,
    required Uuid uuid,
    required ACPHandlerCallbacks callbacks,
  })  : _db = db,
        _uuid = uuid,
        _callbacks = callbacks;

  /// Send a message via ACP WebSocket protocol.
  Future<Message?> sendViaACPProtocol(
    Message userMessage,
    RemoteAgent agent, {
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
  }) async {
    LoggerService().info('Starting ACP WebSocket protocol, endpoint: ${agent.endpoint}', tag: 'ACPProtocolHandler');

    ACPAgentConnection? connection;
    String? taskId;

    try {
      connection = await getOrCreateACPConnection(agent);
      taskId = _uuid.v4();
      acpCancellationToken?.bind(connection, taskId);

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

      activeTask.onStreamChunk = onStreamChunk;
      activeTask.onActionConfirmation = onActionConfirmation;
      activeTask.onSingleSelect = onSingleSelect;
      activeTask.onMultiSelect = onMultiSelect;
      activeTask.onFileUpload = onFileUpload;
      activeTask.onForm = onForm;
      activeTask.onFileMessage = onFileMessage;
      activeTask.onMessageMetadata = onMessageMetadata;
      activeTask.onRequestHistory = onRequestHistory;

      if (effectiveChannelId.isNotEmpty) {
        _callbacks.activeTasks[effectiveChannelId] = activeTask;
        _callbacks.updateTypingAgentIds();
      }
      ForegroundTaskService().acquireTask(agent.name);

      final infLogAcp = InferenceLogService.instance;
      infLogAcp.beginSession(
        sessionId: taskId,
        agentId: agent.id,
        agentName: agent.name,
        channelId: effectiveChannelId.isNotEmpty ? effectiveChannelId : null,
        executionMode: 'remote_acp',
        userMessage: userMessage.content,
      );
      infLogAcp.beginRound(taskId, requestSummary: 'ACP request');

      final taskCompleter = Completer<void>();
      Map<String, dynamic>? actionConfirmationData;
      Map<String, dynamic>? singleSelectData;
      Map<String, dynamic>? multiSelectData;
      Map<String, dynamic>? fileUploadData;
      Map<String, dynamic>? formDataCapture;
      Map<String, dynamic>? messageMetadataExtra;

      acpCancellationToken?.onCancelled = () {
        activeTask.isComplete = true;
        if (!taskCompleter.isCompleted) {
          taskCompleter.complete();
        }
      };

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
        onFileMessage: (data) {
          activeTask.onFileMessage?.call(data);
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

      // Load history
      List<Map<String, dynamic>>? chatHistory;
      int? totalMessageCount;
      if (sessionId != null) {
        chatHistory = await _callbacks.loadChannelHistoryForACP(sessionId);
        // Remove the current user message from history to avoid duplication
        chatHistory?.removeWhere((m) => m['id'] == userMessage.id);
        totalMessageCount = await _db.getChannelMessageCount(sessionId);
      }

      final serializedAttachments = attachments
          ?.where((a) => !a.exceedsSizeLimit)
          .map((a) => a.toJson())
          .toList();

      await connection.sendChatMessage(
        taskId: effectiveTaskId,
        sessionId: sessionId ?? '',
        message: userMessage.content,
        userId: userMessage.from.id,
        messageId: userMessage.id,
        history: chatHistory,
        totalMessageCount: totalMessageCount,
        systemPrompt: agent.metadata['system_prompt'] as String?,
        attachments: serializedAttachments,
      );

      await taskCompleter.future.timeout(
        const Duration(seconds: 300),
        onTimeout: () {
          throw TimeoutException('ACP task timed out');
        },
      );

      // Yield to the event loop so any ui.* notifications that arrived in the
      // same WebSocket batch as task.completed are processed before we remove
      // the task callbacks. Without this, UI component messages (form,
      // fileMessage, etc.) that were sent just before task.completed can be
      // silently dropped because unregisterTaskCallbacks runs first.
      await Future.delayed(Duration.zero);

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

      final meta = <String, dynamic>{};
      meta['trace_id'] = activeTask.taskId;
      if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra!);
      if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
      if (singleSelectData != null) meta['single_select'] = singleSelectData;
      if (multiSelectData != null) meta['multi_select'] = multiSelectData;
      if (fileUploadData != null) meta['file_upload'] = fileUploadData;
      if (formDataCapture != null) meta['form'] = formDataCapture;
      activeTask.metadata = meta;

      connection.unregisterTaskCallbacks(effectiveTaskId);

      final responseContent = activeTask.accumulatedContent;
      return Message(
        id: _uuid.v4(),
        content: responseContent.isNotEmpty ? responseContent : 'Task completed',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(id: userMessage.from.id, type: 'user', name: userMessage.from.name),
        type: MessageType.text,
        replyTo: userMessage.id,
        metadata: meta,
      );
    } catch (e, stackTrace) {
      LoggerService().error('ACP protocol error', tag: 'ACPProtocolHandler', error: e, stackTrace: stackTrace);
      if (connection != null && taskId != null) {
        connection.unregisterTaskCallbacks(taskId);
      }
      throw Exception('ACP protocol error: $e');
    }
  }

  /// Get or create an ACP connection for a given agent.
  Future<ACPAgentConnection> getOrCreateACPConnection(RemoteAgent agent) async {
    var connection = _callbacks.acpConnections[agent.id];

    if (connection != null && connection.isConnected) {
      return connection;
    }

    connection = ACPAgentConnection(agentId: agent.id);
    _callbacks.acpConnections[agent.id] = connection;

    connection.onConnectionStateChanged = (bool connected) {
      if (!connected) {
        _db.updateRemoteAgentStatus(agent.id, 'offline').catchError((_) {});
        _callbacks.acpConnections.remove(agent.id);
        LoggerService().info('ACP connection offline: ${agent.name}', tag: 'ACPProtocolHandler');
      }
    };

    String wsUrl;
    if (agent.endpoint.startsWith('ws://') || agent.endpoint.startsWith('wss://')) {
      wsUrl = agent.endpoint;
    } else {
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
}
