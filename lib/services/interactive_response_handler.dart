import '../models/message.dart';
import '../services/chat_service.dart';
import '../services/local_database_service.dart';
import '../services/acp_agent_connection.dart';

/// Mixin / interface for the state that [InteractiveResponseHandler] needs
/// from the owning controller. Keeps the handler decoupled from the concrete
/// ChatController class while avoiding 13-parameter callback ceremony.
mixin InteractiveStreamingContext {
  // ---- state accessors ----
  String? get agentId;
  String? get currentChannelId;
  List<Message> get messages;
  Map<String, Message> get messageIdMap;
  String? get streamingMessageId;
  set streamingMessageId(String? v);
  String get streamingContent;
  set streamingContent(String v);
  bool get isProcessing;
  set isProcessing(bool v);
  ACPCancellationToken? get acpCancellationToken;
  set acpCancellationToken(ACPCancellationToken? v);

  // ---- dependencies ----
  ChatService get chatService;
  LocalDatabaseService get localDatabaseService;
  String Function() get getUserId;
  String Function() get getUserName;

  // ---- actions the handler may trigger ----
  void notifyUI();
  void emitScrollToBottom({bool force = false});
  void emitError(String message);
  Future<void> loadMessages();
  bool get isMounted;
}

/// Unified handler for interactive response submissions (action confirmation,
/// single-select, multi-select, file upload, form).
///
/// All 5 interaction types share the same pattern:
/// 1. Guard against concurrent processing
/// 2. Optimistic UI update on the original message
/// 3. Create a streaming placeholder for the agent follow-up
/// 4. Submit the response to the agent via ChatService
/// 5. Reload messages on completion
class InteractiveResponseHandler {
  final InteractiveStreamingContext ctx;

  InteractiveResponseHandler(this.ctx);

  // ---------------------------------------------------------------------------
  // Public API — the 5 thin methods the controller delegates to
  // ---------------------------------------------------------------------------

  /// Handle an action confirmation response.
  Future<void> handleActionConfirmation({
    required Message originalMessage,
    required String confirmationId,
    required String actionId,
    required String actionLabel,
    String? confirmationContext,
  }) async {
    _optimisticUpdate(
      originalMessage: originalMessage,
      metadataKey: 'action_confirmation',
      dataToMerge: {'selected_action_id': actionId},
    );

    final effectiveAgentId = ctx.agentId ?? originalMessage.from.id;
    final isMacTool = confirmationContext == 'mac_tool';
    final remoteAgent = await ctx.localDatabaseService.getRemoteAgentById(effectiveAgentId);
    if (remoteAgent == null) throw Exception('Agent not found');

    _beginProcessing();

    try {
      if (isMacTool) {
        // In-band: no streaming placeholder
        await ctx.chatService.submitActionConfirmationResponse(
          originalMessage: originalMessage,
          confirmationId: confirmationId,
          selectedActionId: actionId,
          selectedActionLabel: actionLabel,
          agent: remoteAgent,
          userId: ctx.getUserId(),
          userName: ctx.getUserName(),
          channelId: ctx.currentChannelId,
          confirmationContext: confirmationContext,
        );
      } else {
        _addStreamingPlaceholder(remoteAgent);
        await ctx.chatService.submitActionConfirmationResponse(
          originalMessage: originalMessage,
          confirmationId: confirmationId,
          selectedActionId: actionId,
          selectedActionLabel: actionLabel,
          agent: remoteAgent,
          userId: ctx.getUserId(),
          userName: ctx.getUserName(),
          channelId: ctx.currentChannelId,
          confirmationContext: confirmationContext,
          acpCancellationToken: ctx.acpCancellationToken,
          onStreamChunk: _onStreamChunk,
        );
      }
      await ctx.loadMessages();
    } catch (e) {
      await ctx.loadMessages();
      rethrow;
    } finally {
      _endProcessing();
    }
  }

  /// Handle a single-select, multi-select, file-upload, or form response.
  Future<void> handleSelectResponse({
    required Message originalMessage,
    required String metadataKey,
    required Map<String, dynamic> selectedData,
    required String responseText,
  }) async {
    _optimisticUpdate(
      originalMessage: originalMessage,
      metadataKey: metadataKey,
      dataToMerge: selectedData,
    );

    final effectiveAgentId = ctx.agentId ?? originalMessage.from.id;
    final remoteAgent = await ctx.localDatabaseService.getRemoteAgentById(effectiveAgentId);
    if (remoteAgent == null) throw Exception('Agent not found');

    _beginProcessing();
    _addStreamingPlaceholder(remoteAgent);

    try {
      await ctx.chatService.submitSelectResponse(
        originalMessage: originalMessage,
        metadataKey: metadataKey,
        selectedData: selectedData,
        responseText: responseText,
        agent: remoteAgent,
        userId: ctx.getUserId(),
        userName: ctx.getUserName(),
        channelId: ctx.currentChannelId,
        acpCancellationToken: ctx.acpCancellationToken,
        onStreamChunk: _onStreamChunk,
      );
      await ctx.loadMessages();
    } catch (e) {
      await ctx.loadMessages();
      rethrow;
    } finally {
      _endProcessing();
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _optimisticUpdate({
    required Message originalMessage,
    required String metadataKey,
    required Map<String, dynamic> dataToMerge,
  }) {
    final idx = ctx.messages.indexWhere((m) => m.id == originalMessage.id);
    if (idx == -1) return;

    final updatedMetadata = Map<String, dynamic>.from(originalMessage.metadata ?? {});
    final section = Map<String, dynamic>.from(
      updatedMetadata[metadataKey] as Map<String, dynamic>? ?? {},
    );
    section.addAll(dataToMerge);
    section['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    updatedMetadata[metadataKey] = section;

    final updated = Message(
      id: originalMessage.id,
      content: originalMessage.content,
      timestampMs: originalMessage.timestampMs,
      from: originalMessage.from,
      to: originalMessage.to,
      type: originalMessage.type,
      replyTo: originalMessage.replyTo,
      metadata: updatedMetadata,
    );
    ctx.messages[idx] = updated;
    ctx.messageIdMap[updated.id] = updated;
    ctx.notifyUI();
  }

  void _beginProcessing() {
    ctx.isProcessing = true;
    ctx.acpCancellationToken = ACPCancellationToken();
    ctx.notifyUI();
  }

  void _endProcessing() {
    ctx.acpCancellationToken = null;
    ctx.streamingMessageId = null;
    ctx.streamingContent = '';
    ctx.isProcessing = false;
    ctx.notifyUI();
  }

  void _addStreamingPlaceholder(dynamic remoteAgent) {
    final streamingId = 'streaming_${DateTime.now().millisecondsSinceEpoch}';
    ctx.streamingMessageId = streamingId;
    ctx.streamingContent = '';

    final streamingMessage = Message(
      id: streamingId,
      content: '',
      timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
      to: MessageFrom(id: ctx.getUserId(), type: 'user', name: ctx.getUserName()),
      type: MessageType.text,
    );

    ctx.messages.add(streamingMessage);
    ctx.messageIdMap[streamingMessage.id] = streamingMessage;
    ctx.notifyUI();
    ctx.emitScrollToBottom(force: true);
  }

  void _onStreamChunk(String chunk) {
    if (!ctx.isMounted) return;
    final newContent = ctx.streamingContent + chunk;
    ctx.streamingContent = newContent;

    final currentStreamingId = ctx.streamingMessageId;
    if (currentStreamingId == null) return;

    final idx = ctx.messages.indexWhere((m) => m.id == currentStreamingId);
    if (idx != -1) {
      final msg = ctx.messages[idx];
      final updated = Message(
        id: currentStreamingId,
        content: newContent,
        timestampMs: msg.timestampMs,
        from: msg.from,
        to: msg.to,
        type: MessageType.text,
      );
      ctx.messages[idx] = updated;
      ctx.messageIdMap[updated.id] = updated;
    }
    ctx.notifyUI();
    ctx.emitScrollToBottom();
  }
}
