import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart';
import '../models/mention_entry.dart';
import '../models/message.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../models/attachment_data.dart';
import '../models/pending_attachment.dart';
import '../services/chat_service.dart';
import '../services/local_database_service.dart';
import '../services/attachment_service.dart';
import '../services/message_search_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/local_llm_agent_service.dart';
import '../services/app_lifecycle_service.dart';
import '../services/notification_service.dart';
import '../services/interactive_response_handler.dart';
import '../services/logger_service.dart';

// ---------------------------------------------------------------------------
// Events — sealed hierarchy for UI-bound side effects
// ---------------------------------------------------------------------------

sealed class ChatEvent {}

class ShowSnackBarEvent extends ChatEvent {
  final String message;
  ShowSnackBarEvent(this.message);
}

class ShowErrorSnackBarEvent extends ChatEvent {
  final String message;
  ShowErrorSnackBarEvent(this.message);
}

class ShowRetrySnackBarEvent extends ChatEvent {
  final String message;
  final String retryLabel;
  final Map<String, String> interruptedInfo;
  ShowRetrySnackBarEvent(this.message, this.retryLabel, this.interruptedInfo);
}

/// 主动重连进度提示：发送消息时发现 Agent 不可达，进入指数退避重试循环，
/// 每次尝试前发此事件。UI 显示形如 "正在重连… (1/3)" 的顶部提示。
class ShowReconnectingSnackBarEvent extends ChatEvent {
  final int attempt;
  final int total;
  ShowReconnectingSnackBarEvent(this.attempt, this.total);
}

/// 主动重连结束（连上 or 最终失败）：UI 应隐藏 [ShowReconnectingSnackBarEvent]
/// 之前展示的持久提示。
class HideReconnectingSnackBarEvent extends ChatEvent {}

class NavigateToSessionEvent extends ChatEvent {
  final String channelId;
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final bool embedded;
  NavigateToSessionEvent({
    required this.channelId,
    this.agentId,
    this.agentName,
    this.agentAvatar,
    this.embedded = false,
  });
}

class ShowLoadingOverlayEvent extends ChatEvent {
  final String message;
  ShowLoadingOverlayEvent(this.message);
}

class DismissOverlayEvent extends ChatEvent {}

class RequestScrollToBottomEvent extends ChatEvent {
  final bool force;
  RequestScrollToBottomEvent({this.force = false});
}

class ShowHistoryRequestDialogEvent extends ChatEvent {
  final String reason;
  final Completer<bool> result;
  ShowHistoryRequestDialogEvent(this.reason) : result = Completer<bool>();
}

class ShowOsToolConfirmationEvent extends ChatEvent {
  final String toolName;
  final Map<String, dynamic> args;
  final dynamic risk;
  final Completer<bool> result;
  ShowOsToolConfirmationEvent(this.toolName, this.args, this.risk) : result = Completer<bool>();
}

class GroupInteractionRequestEvent extends ChatEvent {
  final String agentId;
  final String agentName;
  final String interactionType; // 'action_confirmation', 'single_select', 'multi_select', 'form', 'file_upload'
  final Map<String, dynamic> data;
  final String groupStreamingMessageId;
  final Completer<Map<String, dynamic>?> result;
  GroupInteractionRequestEvent({
    required this.agentId,
    required this.agentName,
    required this.interactionType,
    required this.data,
    required this.groupStreamingMessageId,
  }) : result = Completer<Map<String, dynamic>?>();
}

class CloseScreenEvent extends ChatEvent {}

class AgentInfoUpdatedEvent extends ChatEvent {
  final String? name;
  final String? avatar;
  AgentInfoUpdatedEvent(this.name, this.avatar);
}

// ---------------------------------------------------------------------------
// ChatController
// ---------------------------------------------------------------------------

class ChatController extends ChangeNotifier with InteractiveStreamingContext {
  // ---- Constructor parameters ----
  final String? agentId;
  final String? initialAgentName;
  final String? initialAgentAvatar;
  final String? initialChannelId;
  final bool embedded;
  final VoidCallback? onClose;
  final ValueChanged<String>? onSwitchChannel;
  final String Function() getUserId;
  final String Function() getUserName;

  // ---- Services ----
  late final ChatService chatService;
  late final AttachmentService attachmentService;
  late final MessageSearchService searchService;
  late final LocalDatabaseService localDatabaseService;
  late final InteractiveResponseHandler interactiveResponseHandler;

  // ---- Event stream ----
  final _eventController = StreamController<ChatEvent>.broadcast();
  Stream<ChatEvent> get events => _eventController.stream;

  // ---- Core message state ----
  List<Message> messages = [];
  Map<String, Message> messageIdMap = {};
  bool isLoading = false;
  bool isSearching = false;
  String searchQuery = '';

  // ---- Streaming state ----
  String? streamingMessageId;
  String streamingContent = '';

  // ---- Processing / queue ----
  bool isProcessing = false;
  ACPCancellationToken? acpCancellationToken;
  List<String> messageQueue = [];

  // ---- Agent health state ----
  bool isAgentOnline = false;
  bool isCheckingHealth = true;
  Timer? _healthCheckTimer;

  // ---- Reply state ----
  Message? replyingToMessage;
  String? highlightedMessageId;

  // ---- Channel / lifecycle ----
  String? currentChannelId;
  bool isAppActive = true;
  int? backgroundedAtMs;

  // ---- History request tracking ----
  int historySentCount = 40;
  String? lastUserQuestion;
  Map<String, dynamic>? pendingHistoryRequest;

  // ---- Mutable agent info ----
  String? agentName;
  String? agentAvatar;

  // ---- Group mode state ----
  bool isGroupMode = false;
  Channel? groupChannel;
  List<RemoteAgent> groupAgents = [];
  Set<String> respondingAgentNames = {};
  bool mentionOnlyMode = false;
  String? groupAdminAgentId;
  Set<String> groupStreamingMessageIds = {};
  Map<String, GroupInteractionRequestEvent> pendingGroupInteractions = {};

  // ---- DM channel system prompt override ----
  /// Custom system prompt set by the user for the current DM channel.
  /// When non-null, overrides the agent's default system prompt.
  String? dmSystemPrompt;

  // ---- Frame coalescing ----
  bool _pendingStreamingRebuild = false;

  /// The ID of the currently active workflow (set during flow execution).
  String? _activeWorkflowId;
  String? get activeWorkflowId => _activeWorkflowId;

  /// Set the active workflow ID (called by orchestration when flow starts).
  void setActiveWorkflowId(String? id) {
    _activeWorkflowId = id;
    notifyListeners();
  }

  /// User dismisses the workflow progress panel.
  void dismissWorkflowPanel() {
    _activeWorkflowId = null;
    notifyListeners();
  }

  ChatController({
    required this.agentId,
    this.initialAgentName,
    this.initialAgentAvatar,
    this.initialChannelId,
    this.embedded = false,
    this.onClose,
    this.onSwitchChannel,
    required this.getUserId,
    required this.getUserName,
  }) {
    agentName = initialAgentName;
    agentAvatar = initialAgentAvatar;

    final databaseService = LocalDatabaseService();
    localDatabaseService = databaseService;
    chatService = ChatService();
    attachmentService = AttachmentService(
      LocalFileStorageService(),
      databaseService,
    );
    searchService = MessageSearchService(databaseService);
    interactiveResponseHandler = InteractiveResponseHandler(this);
  }

  /// Initialize the controller. Call this after constructing.
  Future<void> init() async {
    await loadMessages();
    refreshAgentStatus();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      refreshAgentStatus();
    });
  }

  @override
  void dispose() {
    AppLifecycleService().setActiveChannel(null);
    if (currentChannelId != null) {
      chatService.detachTaskUI(currentChannelId!);
      chatService.detachGroupTaskUI(currentChannelId!);
    }
    messageQueue.clear();
    _healthCheckTimer?.cancel();
    if (currentChannelId != null) {
      chatService.closeChannelStream(currentChannelId!);
    }
    _eventController.close();
    super.dispose();
  }

  void _emit(ChatEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _notify() {
    if (_eventController.isClosed) return;
    notifyListeners();
  }

  // ---- InteractiveStreamingContext implementation ----
  @override
  void notifyUI() => _notify();

  @override
  void emitScrollToBottom({bool force = false}) =>
      _emit(RequestScrollToBottomEvent(force: force));

  @override
  void emitError(String message) => _emit(ShowErrorSnackBarEvent(message));

  @override
  bool get isMounted => !_eventController.isClosed;

  /// Add a message to the local list and notify listeners. Used by the UI shell
  /// for voice messages and other locally-generated messages.
  void addLocalMessage(Message message) {
    messages.add(message);
    messageIdMap[message.id] = message;
    _notify();
  }

  /// Update the group channel and notify listeners.
  void updateGroupChannelInfo(Channel updated) {
    groupChannel = updated;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // App lifecycle
  // ---------------------------------------------------------------------------

  void onAppLifecycleChanged(bool resumed) {
    final wasActive = isAppActive;
    isAppActive = resumed;

    if (!resumed) {
      backgroundedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    }

    if (resumed && !wasActive) {
      // Delay DB writes slightly — on iOS the SQLite file handle may still be
      // readonly for a brief moment after the app returns from background.
      Future.delayed(const Duration(milliseconds: 500), () {
        markMessagesAsReadIfAtBottom();
        handleResumeFromBackground();
      });
    }
  }

  Future<void> handleResumeFromBackground() async {
    final bgMs = backgroundedAtMs;
    backgroundedAtMs = null;
    if (bgMs == null || currentChannelId == null) return;

    final duration = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - bgMs,
    );

    try {
      await chatService.handleAppResumed(duration);
    } catch (e) {
      // Database may still be recovering from background on iOS.
      LoggerService().error('handleAppResumed failed', tag: 'ChatController', error: e);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 200));

    final interruptedInfo = chatService.getInterruptedTaskInfo(currentChannelId!);
    if (interruptedInfo != null) {
      chatService.clearInterruptedTaskInfo(currentChannelId!);

      streamingMessageId = null;
      streamingContent = '';
      isProcessing = false;
      _notify();

      await reloadMessagesFromDB();

      _emit(ShowRetrySnackBarEvent(
        'chat_connectionInterrupted',
        'chat_connectionInterruptedRetry',
        interruptedInfo,
      ));
    }
  }

  Future<void> retryLastUserMessage(Map<String, String> interruptedInfo) async {
    if (currentChannelId == null) return;

    final userMsgId = interruptedInfo['userMessageId'];
    if (userMsgId == null) return;

    String? messageContent;
    for (final msg in messages.reversed) {
      if (msg.id == userMsgId) {
        messageContent = msg.content;
        break;
      }
    }

    if (messageContent == null) {
      final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
      for (final msg in dbMessages.reversed) {
        if (msg.id == userMsgId) {
          messageContent = msg.content;
          break;
        }
      }
    }

    if (messageContent != null && messageContent.isNotEmpty) {
      if (isGroupMode) {
        await processGroupMessage(messageContent);
      } else {
        await processMessage(messageContent);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Message loading
  // ---------------------------------------------------------------------------

  Future<void> loadMessages() async {
    isLoading = true;
    _notify();

    try {
      final userId = getUserId();

      if (initialChannelId != null && currentChannelId == null) {
        currentChannelId = initialChannelId;
      } else if (agentId != null && currentChannelId == null) {
        final latestChannelId = await chatService.getLatestActiveChannelId(userId, agentId!);
        currentChannelId = latestChannelId ?? chatService.generateChannelId(userId, agentId!);
      } else if (agentId == null && currentChannelId == null) {
        isLoading = false;
        _notify();
        return;
      }

      AppLifecycleService().setActiveChannel(currentChannelId);
      NotificationService().cancelNotification(currentChannelId.hashCode);

      // Detect group mode & resolve agent info from channel metadata
      final channel = await localDatabaseService.getChannelById(currentChannelId!);
      if (channel != null && channel.isGroup) {
        isGroupMode = true;
        groupChannel = channel;
        mentionOnlyMode = channel.isAllMembersMentionMode;
        final agentIds = channel.memberIds.where((id) => id != userId && id != 'user').toList();
        final agents = <RemoteAgent>[];
        for (final aid in agentIds) {
          final agent = await localDatabaseService.getRemoteAgentById(aid);
          if (agent != null) agents.add(agent);
        }
        groupAgents = agents;
        groupAdminAgentId = channel.adminAgentId;
      } else if (channel != null && channel.isDM) {
        // Load DM channel's custom system prompt
        dmSystemPrompt = channel.systemPrompt;
        if (agentName == null) {
          // Resolve agent name/avatar from channel when not provided
          // (e.g. navigating from search results by channelId only)
          final agentMember = channel.members.where((m) => m.isAgent).toList();
          if (agentMember.isNotEmpty) {
            final agent = await localDatabaseService.getRemoteAgentById(agentMember.first.id);
            if (agent != null) {
              agentName = agent.name;
              agentAvatar = agent.avatar;
            }
          }
        }
      } else if (channel != null && !channel.isGroup && agentName == null) {
        // Non-group, non-DM typed channel — resolve agent name from channel
        final agentMember = channel.members.where((m) => m.isAgent).toList();
        if (agentMember.isNotEmpty) {
          final agent = await localDatabaseService.getRemoteAgentById(agentMember.first.id);
          if (agent != null) {
            agentName = agent.name;
            agentAvatar = agent.avatar;
          }
        }
      }

      final loadedMessages = await chatService.loadChannelMessages(currentChannelId!);

      messages = loadedMessages;
      rebuildMessageIdMap();
      isLoading = false;
      _notify();

      markMessagesAsReadIfAtBottom();

      _emit(RequestScrollToBottomEvent(force: true));

      if (!isGroupMode) {
        reattachToActiveTask();
      }
      if (isGroupMode) {
        reattachToGroupActiveTasks();
        _reattachPendingPlanApproval();
      }
    } catch (e) {
      isLoading = false;
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_loadFailed:$e'));
    }
  }

  Future<void> reloadMessagesFromDB() async {
    if (currentChannelId == null) return;
    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
    messages.clear();
    messageIdMap.clear();
    for (final m in dbMessages) {
      messages.add(m);
      messageIdMap[m.id] = m;
    }
    _notify();
  }

  void rebuildMessageIdMap() {
    messageIdMap = {for (final m in messages) m.id: m};
  }

  // ---------------------------------------------------------------------------
  // Agent health
  // ---------------------------------------------------------------------------

  Future<void> refreshAgentStatus() async {
    if (agentId == null) return;
    try {
      final agent = await localDatabaseService.getAgentById(agentId!);
      if (agent != null) {
        isAgentOnline = agent.status.isOnline;
        isCheckingHealth = false;
        _notify();
      }
    } catch (_) {
      isCheckingHealth = false;
      _notify();
    }
  }

  // ---------------------------------------------------------------------------
  // DM system prompt
  // ---------------------------------------------------------------------------

  /// Save a custom system prompt for the current DM channel.
  /// Persists to the database and updates the in-memory value.
  Future<void> updateDmSystemPrompt(String? prompt) async {
    if (currentChannelId == null) return;
    final channel = await localDatabaseService.getChannelById(currentChannelId!);
    if (channel == null) return;
    final updated = channel.copyWith(systemPrompt: prompt?.isNotEmpty == true ? prompt : null);
    await localDatabaseService.updateChannel(updated);
    dmSystemPrompt = updated.systemPrompt;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Read status
  // ---------------------------------------------------------------------------

  bool isUserScrolledUp = false;
  int unreadMessageCount = 0;

  Future<void> markMessagesAsReadIfAtBottom() async {
    if (currentChannelId == null) return;
    if (!isAppActive) return;
    if (isUserScrolledUp) return;
    try {
      await localDatabaseService.markChannelMessagesAsRead(currentChannelId!);
    } catch (e) {
      // On iOS, SQLite can be temporarily readonly after returning from
      // background. Swallow the error — messages will be marked read on the
      // next successful attempt.
      LoggerService().error('markMessagesAsRead failed (db may be recovering)', tag: 'ChatController', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // Reattach to background tasks
  // ---------------------------------------------------------------------------

  void reattachToActiveTask() {
    if (currentChannelId == null) return;

    final activeTask = chatService.getActiveTask(currentChannelId!);
    if (activeTask == null) return;

    streamingContent = activeTask.accumulatedContent;
    streamingMessageId = 'streaming_reattach_${DateTime.now().millisecondsSinceEpoch}';

    final streamingMessage = Message(
      id: streamingMessageId!,
      content: streamingContent,
      timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
      from: MessageFrom(id: activeTask.agentId, type: 'agent', name: activeTask.agentName),
      to: MessageFrom(id: activeTask.userId, type: 'user', name: activeTask.userName),
      type: MessageType.text,
    );

    isProcessing = true;
    messages.add(streamingMessage);
    messageIdMap[streamingMessage.id] = streamingMessage;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    acpCancellationToken = ACPCancellationToken();

    chatService.attachTaskUI(
      currentChannelId!,
      onStreamChunk: (chunk) {
        streamingContent += chunk;
        final idx = messages.indexWhere((m) => m.id == streamingMessageId);
        if (idx != -1) {
          final updated = Message(
            id: streamingMessageId!,
            content: streamingContent,
            timestampMs: messages[idx].timestampMs,
            from: messages[idx].from,
            to: messages[idx].to,
            type: messages[idx].type,
          );
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
        scheduleStreamingRebuild();
        if (!isUserScrolledUp) {
          _emit(RequestScrollToBottomEvent());
        }
      },
      onMessageMetadata: (metadata) {
        final idx = messages.indexWhere((m) => m.id == streamingMessageId);
        if (idx != -1) {
          final existingMetadata = Map<String, dynamic>.from(messages[idx].metadata ?? {});
          existingMetadata.addAll(metadata);
          final updated = Message(
            id: streamingMessageId!,
            content: messages[idx].content,
            timestampMs: messages[idx].timestampMs,
            from: messages[idx].from,
            to: messages[idx].to,
            type: messages[idx].type,
            metadata: existingMetadata,
          );
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
        _notify();
      },
      onTaskFinished: () async {
        await activeTask.dbSaveCompleter.future;
        acpCancellationToken = null;
        streamingMessageId = null;
        streamingContent = '';
        await loadMessages();
        isProcessing = false;
        _notify();
        processNextInQueue();
      },
    );
  }

  void reattachToGroupActiveTasks() {
    if (currentChannelId == null) return;

    final activeTasks = chatService.getActiveGroupTasks(currentChannelId!);
    if (activeTasks.isEmpty) return;

    final streamingIds = <String, String>{};
    final streamingContents = <String, String>{};

    for (final entry in activeTasks.entries) {
      final aid = entry.key;
      final task = entry.value;
      final sid = 'group_streaming_${aid}_${DateTime.now().millisecondsSinceEpoch}';
      streamingIds[aid] = sid;
      streamingContents[aid] = task.accumulatedContent;

      final streamingMessage = Message(
        id: sid,
        content: task.accumulatedContent,
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
        from: MessageFrom(id: aid, type: 'agent', name: task.agentName),
        type: MessageType.text,
      );

      isProcessing = true;
      respondingAgentNames.add(task.agentName);
      groupStreamingMessageIds.add(sid);
      messages.add(streamingMessage);
      messageIdMap[streamingMessage.id] = streamingMessage;
    }
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    chatService.attachGroupTaskUI(
      currentChannelId!,
      onStreamChunk: (aid, agentNameVal, chunk) {
        final sid = streamingIds[aid];
        if (sid == null) return;
        streamingContents[aid] = (streamingContents[aid] ?? '') + chunk;
        final updatedContent = streamingContents[aid]!;
        final existing = messageIdMap[sid];
        if (existing != null) {
          final idx = messages.indexOf(existing);
          if (idx != -1) {
            final updated = Message(
              id: sid,
              content: updatedContent,
              timestampMs: messages[idx].timestampMs,
              from: messages[idx].from,
              to: messages[idx].to,
              type: MessageType.text,
            );
            messages[idx] = updated;
            messageIdMap[updated.id] = updated;
          }
        }
        scheduleStreamingRebuild();
        if (!isUserScrolledUp) {
          _emit(RequestScrollToBottomEvent());
        }
      },
      onTaskFinished: (aid, agentNameVal) {
        final sid = streamingIds[aid];
        if (sid != null) {
          groupStreamingMessageIds.remove(sid);
        }
        streamingIds.remove(aid);
        streamingContents.remove(aid);
        respondingAgentNames.remove(agentNameVal);
        _notify();

        if (streamingIds.isEmpty) {
          reconcileGroupMessages().then((_) {
            isProcessing = false;
            respondingAgentNames.clear();
            groupStreamingMessageIds.clear();
            _notify();
            processNextInQueue();
          });
        }
      },
    );
  }

  /// Re-emit a GroupInteractionRequestEvent for any pending plan_approval
  /// that survived a channel switch. Called from loadMessages() so the UI
  /// can re-render the approve/reject card after navigating back.
  void _reattachPendingPlanApproval() {
    if (currentChannelId == null) return;
    final pendingApproval = chatService.getPendingPlanApproval(currentChannelId!);
    if (pendingApproval == null) return;

    final msgId = pendingApproval.messageId;
    if (msgId.isEmpty || !messageIdMap.containsKey(msgId)) return;

    // Re-emit the event so the UI shows the interactive card again.
    _emit(GroupInteractionRequestEvent(
      agentId: pendingApproval.agentId,
      agentName: pendingApproval.agentName,
      interactionType: 'plan_approval',
      data: Map<String, dynamic>.from(pendingApproval.planData),
      groupStreamingMessageId: msgId,
    ));
  }

  // ---------------------------------------------------------------------------
  // Sending messages
  // ---------------------------------------------------------------------------

  Future<void> sendMessage({
    required String content,
    required List<PendingAttachment> pendingAttachments,
    required VoidCallback clearMessageController,
    String? replyToId,
    List<MentionEntry> mentions = const [],
  }) async {
    final hasPendingAttachments = pendingAttachments.isNotEmpty;
    LoggerService().debug('User sending message', tag: 'ChatController');

    if (content.isEmpty && !hasPendingAttachments) return;

    if (!isGroupMode && agentId == null) {
      _emit(ShowSnackBarEvent('chat_noAgentSelected'));
      return;
    }

    final attachmentsToSend = List<PendingAttachment>.from(pendingAttachments);
    pendingAttachments.clear();

    clearMessageController();

    // Capture reply state
    final capturedReplyToId = replyToId ?? replyingToMessage?.id;
    cancelReply();

    // Save all pending attachments and build AttachmentData list
    final savedAttachmentMessages = <Message>[];
    final attachmentDataList = <AttachmentData>[];
    if (attachmentsToSend.isNotEmpty) {
      final userId = getUserId();
      final userName = getUserName();

      for (final att in attachmentsToSend) {
        final message = await attachmentService.saveAttachment(
          file: att.file,
          channelId: currentChannelId ?? '',
          userId: userId,
          userName: userName,
          agentId: agentId ?? '',
        );
        if (att.isFromClipboard) {
          try { att.file.deleteSync(); } catch (_) {}
        }
        if (message != null) {
          messages.add(message);
          messageIdMap[message.id] = message;
          _notify();
          _emit(RequestScrollToBottomEvent(force: true));
          savedAttachmentMessages.add(message);

          final attData = await attachmentService.buildAttachmentData(message);
          if (attData != null && !attData.exceedsSizeLimit) {
            attachmentDataList.add(attData);
          }
        }
      }
    }

    final hasAttachments = attachmentDataList.isNotEmpty;

    // If only attachments (no text), send each attachment individually
    if (content.isEmpty) {
      if (hasAttachments && !isGroupMode) {
        for (final msg in savedAttachmentMessages) {
          await sendAttachmentToAgent(msg);
        }
      }
      return;
    }

    // Queue if processing
    if (isProcessing) {
      if (hasAttachments && !isGroupMode) {
        for (final msg in savedAttachmentMessages) {
          await sendAttachmentToAgent(msg);
        }
      }
      messageQueue.add(content);
      _notify();
      return;
    }

    if (isGroupMode) {
      LoggerService().debug('sendMessage -> processGroupMessage (isGroupMode=true, groupAgents=${groupAgents.length}, adminId=$groupAdminAgentId)', tag: 'ChatController');
      await processGroupMessage(content, replyToId: capturedReplyToId, attachments: hasAttachments ? attachmentDataList : null, mentions: mentions);
    } else {
      await processMessage(content, replyToId: capturedReplyToId, attachments: hasAttachments ? attachmentDataList : null, attachmentMessages: hasAttachments ? savedAttachmentMessages : null);
    }
  }

  /// Stop only the current message being streamed, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentMessageOnly() {
    LoggerService().debug('Stopping current message only (queue preserved)', tag: 'ChatController');

    if (streamingMessageId != null) {
      final stoppedId = streamingMessageId!;
      final idx = messages.indexWhere((m) => m.id == stoppedId);
      if (idx != -1) {
        final current = messages[idx];
        final stoppedContent = streamingContent.isNotEmpty
            ? '$streamingContent\n\n[Stopped]'
            : '[Stopped]';
        messages[idx] = Message(
          id: current.id,
          content: stoppedContent,
          timestampMs: current.timestampMs,
          from: current.from,
          to: current.to,
          type: current.type,
          metadata: current.metadata,
        );
        messageIdMap[current.id] = messages[idx];
      }
      streamingMessageId = null;
      streamingContent = '';
      _notify();
    }

    acpCancellationToken?.cancel();
    // DO NOT clear messageQueue — let processNextInQueue() pick up the next one
    _notify();
  }

  /// Stop all active group streaming messages, but leave the queue intact
  /// so that the next queued message can be processed.
  void stopCurrentGroupMessageOnly() {
    LoggerService().debug('Stopping current group messages only (queue preserved)', tag: 'ChatController');

    // Mark all active group streaming messages with [Stopped]
    for (final sid in groupStreamingMessageIds) {
      final existing = messageIdMap[sid];
      if (existing != null) {
        final idx = messages.indexOf(existing);
        if (idx != -1) {
          final current = messages[idx];
          final stoppedContent = current.content.isNotEmpty
              ? '${current.content}\n\n[Stopped]'
              : '[Stopped]';
          final updated = Message(
            id: current.id,
            content: stoppedContent,
            timestampMs: current.timestampMs,
            from: current.from,
            to: current.to,
            type: current.type,
            metadata: current.metadata,
          );
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
      }
    }

    // Cancel the cancellation token to stop all active agent tasks
    acpCancellationToken?.cancel();

    // Force-complete all group tasks in ChatService
    if (currentChannelId != null) {
      chatService.cancelActiveGroupTasks(currentChannelId!);
    }

    // Complete all pending group interaction Completers with null.
    // Note: plan_approval is no longer tracked in pendingGroupInteractions —
    // its Completer lives in ChatService._pendingPlanApprovals and survives
    // channel navigation. So this loop only cancels other interaction types.
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();

    // Reset group streaming state but DO NOT clear messageQueue
    respondingAgentNames.clear();
    groupStreamingMessageIds.clear();
    isProcessing = false;
    _notify();
    processNextInQueue();
  }

  void stopStreaming() {
    LoggerService().debug('Stopping streaming', tag: 'ChatController');

    if (streamingMessageId != null) {
      final stoppedId = streamingMessageId!;
      final idx = messages.indexWhere((m) => m.id == stoppedId);
      if (idx != -1) {
        final current = messages[idx];
        final stoppedContent = streamingContent.isNotEmpty
            ? '$streamingContent\n\n[Stopped]'
            : '[Stopped]';
        messages[idx] = Message(
          id: current.id,
          content: stoppedContent,
          timestampMs: current.timestampMs,
          from: current.from,
          to: current.to,
          type: current.type,
          metadata: current.metadata,
        );
        messageIdMap[current.id] = messages[idx];
      }
      streamingMessageId = null;
      streamingContent = '';
      _notify();
    }

    acpCancellationToken?.cancel();

    // Clear queued messages so they won't be sent after stopping
    messageQueue.clear();
    _notify();
  }

  void stopGroupStreaming() {
    LoggerService().debug('Stopping group streaming', tag: 'ChatController');

    // Mark all active group streaming messages with [Stopped]
    for (final sid in groupStreamingMessageIds) {
      final existing = messageIdMap[sid];
      if (existing != null) {
        final idx = messages.indexOf(existing);
        if (idx != -1) {
          final current = messages[idx];
          final stoppedContent = current.content.isNotEmpty
              ? '${current.content}\n\n[Stopped]'
              : '[Stopped]';
          final updated = Message(
            id: current.id,
            content: stoppedContent,
            timestampMs: current.timestampMs,
            from: current.from,
            to: current.to,
            type: current.type,
            metadata: current.metadata,
          );
          messages[idx] = updated;
          messageIdMap[updated.id] = updated;
        }
      }
    }

    // Cancel the cancellation token to stop all active agent tasks
    acpCancellationToken?.cancel();

    // Force-complete all group tasks in ChatService so typing indicators
    // are cleared and reattach won't resume cancelled tasks.
    if (currentChannelId != null) {
      chatService.cancelActiveGroupTasks(currentChannelId!);
    }

    // Cancel any pending plan_approval so the orchestration loop terminates.
    if (currentChannelId != null) {
      chatService.cancelPlanApproval(currentChannelId!);
    }

    // Complete all pending group interaction Completers with null.
    // Note: plan_approval is no longer tracked here — its Completer is in
    // ChatService._pendingPlanApprovals and was cancelled above.
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();

    // Reset group streaming state
    respondingAgentNames.clear();
    groupStreamingMessageIds.clear();
    messageQueue.clear();
    isProcessing = false;
    _notify();
  }

  Future<void> processNextInQueue() async {
    if (messageQueue.isEmpty) return;

    final nextContent = messageQueue.removeAt(0);
    _notify();
    if (isGroupMode) {
      await processGroupMessage(nextContent);
    } else {
      await processMessage(nextContent);
    }
  }

  // ---------------------------------------------------------------------------
  // Process DM message
  // ---------------------------------------------------------------------------

  Future<void> processMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<Message>? attachmentMessages}) async {
    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    _notify();

    lastUserQuestion = content;
    acpCancellationToken = ACPCancellationToken();

    // Set to true when the agent supports async-confirmation: the task lives
    // on past this method's return, and the finally block must NOT clear
    // `streamingMessageId` / `isProcessing` — those belong to the task's
    // onTaskFinished callback, which fires later when task.completed arrives.
    bool awaitingAsyncTask = false;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = LocalLLMAgentService.instance.isLocalAgent(remoteAgent);

      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      // 注意：不再在此做前置的 checkAgentHealth 探测。
      // AgentMessagingService 内部在建连阶段已带 3 次指数退避重试 +
      // checkAgentHealth 兜底，并通过 onReconnecting 回调把进度推给 UI。
      // 移除这里可以避免"一次失败就抛出"的体验，并减少一次冗余 ping。

      // Add user message to UI immediately
      final userMessage = Message(
        id: 'temp_user_${DateTime.now().millisecondsSinceEpoch}',
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: userId, type: 'user', name: userName),
        to: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        type: MessageType.text,
        replyTo: replyToId,
      );

      streamingMessageId = 'streaming_${DateTime.now().millisecondsSinceEpoch}';
      streamingContent = '';
      final streamingMessage = Message(
        id: streamingMessageId!,
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
        from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        type: MessageType.text,
      );

      messages.add(userMessage);
      messages.add(streamingMessage);
      messageIdMap[userMessage.id] = userMessage;
      messageIdMap[streamingMessage.id] = streamingMessage;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));

      if (currentChannelId != null) {
        final currentMessages = await chatService.loadChannelMessages(
          currentChannelId!, limit: 40,
        );
        historySentCount = currentMessages.where((m) => m.type == MessageType.text).length;
      }

      final agentResponse = await chatService.sendMessageToAgent(
        content: content,
        agent: remoteAgent,
        userId: userId,
        userName: userName,
        channelId: currentChannelId,
        replyToId: replyToId,
        dmSystemPrompt: dmSystemPrompt,
        acpCancellationToken: acpCancellationToken,
        attachments: attachments,
        onReconnecting: (attempt, total) {
          if (attempt == 0) {
            _emit(HideReconnectingSnackBarEvent());
          } else {
            _emit(ShowReconnectingSnackBarEvent(attempt, total));
          }
        },
        onOsToolConfirmation: (toolName, args, risk) async {
          final event = ShowOsToolConfirmationEvent(toolName, args, risk);
          _emit(event);
          return await event.result.future;
        },
        onStreamChunk: (chunk) {
          streamingContent += chunk;
          final idx = messages.indexWhere((m) => m.id == streamingMessageId);
          if (idx != -1) {
            final updated = Message(
              id: streamingMessageId!,
              content: streamingContent,
              timestampMs: messages[idx].timestampMs,
              from: messages[idx].from,
              to: messages[idx].to,
              type: MessageType.text,
              metadata: messages[idx].metadata,
            );
            messages[idx] = updated;
            messageIdMap[updated.id] = updated;
          }
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
        onActionConfirmation: (actionData) {
          final idx = messages.indexWhere((m) => m.id == streamingMessageId);
          if (idx != -1) {
            final updated = Message(
              id: streamingMessageId!,
              content: streamingContent,
              timestampMs: messages[idx].timestampMs,
              from: messages[idx].from,
              to: messages[idx].to,
              type: MessageType.text,
              metadata: {'action_confirmation': Map<String, dynamic>.from(actionData)},
            );
            messages[idx] = updated;
            messageIdMap[updated.id] = updated;
          }
          _notify();
        },
        onSingleSelect: (selectData) {
          _updateStreamingMetadata({'single_select': Map<String, dynamic>.from(selectData)});
        },
        onMultiSelect: (selectData) {
          _updateStreamingMetadata({'multi_select': Map<String, dynamic>.from(selectData)});
        },
        onFileUpload: (uploadData) {
          _updateStreamingMetadata({'file_upload': Map<String, dynamic>.from(uploadData)});
        },
        onForm: (formData) {
          _updateStreamingMetadata({'form': Map<String, dynamic>.from(formData)});
        },
        onFileMessage: (fileData) async {
          await _handleFileMessage(fileData);
        },
        onMessageMetadata: (metadata) {
          final idx = messages.indexWhere((m) => m.id == streamingMessageId);
          if (idx != -1) {
            final existingMetadata = Map<String, dynamic>.from(messages[idx].metadata ?? {});
            existingMetadata.addAll(metadata);
            final updated = Message(
              id: streamingMessageId!,
              content: messages[idx].content,
              timestampMs: messages[idx].timestampMs,
              from: messages[idx].from,
              to: messages[idx].to,
              type: messages[idx].type,
              metadata: existingMetadata,
            );
            messages[idx] = updated;
            messageIdMap[updated.id] = updated;
          }
          _notify();
        },
        onRequestHistory: (historyData) {
          pendingHistoryRequest = Map<String, dynamic>.from(historyData);
        },
      );

      // Phase 2-A: async-confirmation fast path.
      // When the agent supports async_confirmation, `sendMessageToAgent`
      // returns `null` as soon as the agent has ACK'd the request — the
      // streaming chunks, action_confirmation metadata, and eventual
      // task.completed all flow through TaskCallbacks asynchronously.
      //
      // Hook the underlying ActiveTask's onTaskFinished so that when the
      // agent's SDK turn finally ends (milliseconds to seconds later), we
      // reload messages from DB, drop the streaming id, and clear the
      // processing flag. Until then the UI stays responsive — the user can
      // tap Allow / Deny on a confirmation card, or even send a follow-up.
      final asyncConn = chatService.getACPConnection(remoteAgent.id);
      final supportsAsync = asyncConn?.supportsAsyncConfirmation ?? false;
      if (supportsAsync && currentChannelId != null) {
        final activeTask = chatService.getActiveTask(currentChannelId!);
        if (activeTask != null) {
          awaitingAsyncTask = true;
          final channelAtDispatch = currentChannelId;
          activeTask.onTaskFinished = () async {
            try {
              await activeTask.dbSaveCompleter.future;
            } catch (_) {}
            // Only clean up if we're still on the same channel (user may have
            // navigated away). If they did, the values are already detached
            // and another call will just be a no-op on stale state.
            if (currentChannelId == channelAtDispatch) {
              acpCancellationToken = null;
              streamingMessageId = null;
              streamingContent = '';
              await loadMessages();
              isProcessing = false;
              _notify();
              processNextInQueue();
            }
          };
        }
      }

      // Handle pending history request
      bool handledHistorySupplement = false;
      if (pendingHistoryRequest != null) {
        final historyData = pendingHistoryRequest!;
        pendingHistoryRequest = null;

        if (agentResponse != null) {
          try { await chatService.deleteMessage(agentResponse.id); } catch (_) {}
        }

        final reason = historyData['reason'] as String? ?? 'Agent needs more context';
        final requestId = historyData['request_id'] as String? ?? '';
        final requestedCount = historyData['requested_count'] as int? ?? 40;

        addSystemHint('$reason');

        final dialogEvent = ShowHistoryRequestDialogEvent(reason);
        _emit(dialogEvent);
        final approved = await dialogEvent.result.future;

        if (approved) {
          handledHistorySupplement = true;
          addSystemHint('Loading more chat history...');

          streamingMessageId = 'streaming_reanswer_${DateTime.now().millisecondsSinceEpoch}';
          streamingContent = '';
          acpCancellationToken = ACPCancellationToken();

          final reanswer = Message(
            id: streamingMessageId!,
            content: '',
            timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
            from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
            to: MessageFrom(id: userId, type: 'user', name: userName),
            type: MessageType.text,
          );
          messages.add(reanswer);
          messageIdMap[reanswer.id] = reanswer;
          _notify();
          _emit(RequestScrollToBottomEvent(force: true));

          int currentRequestedCount = requestedCount;
          const int maxSupplementRounds = 3;
          try {
            for (int round = 0; round < maxSupplementRounds; round++) {
              final supplementResult = await chatService.sendHistorySupplement(
                agent: remoteAgent,
                sessionId: currentChannelId!,
                requestId: requestId,
                originalQuestion: lastUserQuestion ?? '',
                offset: historySentCount,
                batchSize: currentRequestedCount,
                onStreamChunk: (chunk) {
                  streamingContent += chunk;
                  final idx = messages.indexWhere((m) => m.id == streamingMessageId);
                  if (idx != -1) {
                    final updated = Message(
                      id: streamingMessageId!,
                      content: streamingContent,
                      timestampMs: messages[idx].timestampMs,
                      from: messages[idx].from,
                      to: messages[idx].to,
                      type: MessageType.text,
                    );
                    messages[idx] = updated;
                    messageIdMap[updated.id] = updated;
                  }
                  scheduleStreamingRebuild();
                  if (!isUserScrolledUp) {
                    _emit(RequestScrollToBottomEvent());
                  }
                },
                acpCancellationToken: acpCancellationToken,
              );

              if (supplementResult == null) {
                addSystemHint('No more history records available');
                messages.removeWhere((m) => m.id == streamingMessageId);
                messageIdMap.remove(streamingMessageId);
                _notify();
                break;
              }

              historySentCount += supplementResult.actualSentCount;

              if (supplementResult.pendingHistoryRequest != null) {
                final nextReason = supplementResult.pendingHistoryRequest!['reason'] as String? ?? 'Agent needs more context';
                currentRequestedCount = supplementResult.pendingHistoryRequest!['requested_count'] as int? ?? 40;
                if (supplementResult.message.content.isEmpty) {
                  try { await chatService.deleteMessage(supplementResult.message.id); } catch (_) {}
                }
                addSystemHint(nextReason);
                addSystemHint('Loading more chat history...');
                streamingContent = '';
                acpCancellationToken = ACPCancellationToken();
                continue;
              }

              addSystemHint('History loaded, agent is re-answering...');
              break;
            }
          } catch (e) {
            addSystemHint('Failed to load history: $e');
            messages.removeWhere((m) => m.id == streamingMessageId);
            messageIdMap.remove(streamingMessageId);
            _notify();
          }
        } else {
          addSystemHint('History request ignored');
        }
      }

      if (!handledHistorySupplement && agentResponse == null) {
        // Phase 2-A: in async-confirmation mode, `sendMessageToAgent` returns
        // null as soon as the agent has acknowledged the request — the actual
        // response (text + confirmation metadata) flows through the registered
        // TaskCallbacks asynchronously. A `null` here is NOT an error in that
        // mode; suppress the snackbar and leave the streaming message in place
        // for the callbacks to keep updating.
        final isAsync = chatService
                .getACPConnection(remoteAgent.id)
                ?.supportsAsyncConfirmation ??
            false;
        if (!isAsync) {
          _emit(ShowSnackBarEvent('chat_responseError'));
        }
      }

      isAgentOnline = true;
      _notify();
      // In async mode, skip loadMessages() here — the DB save happens later
      // (in onTaskCompleted), so reloading now would overwrite the in-memory
      // streaming content with a stale DB snapshot. The onTaskFinished
      // callback does its own loadMessages() when the task actually ends.
      if (!awaitingAsyncTask) {
        await loadMessages();
      }
    } catch (e, stackTrace) {
      LoggerService().error('Send message failed', tag: 'ChatController', error: e, stackTrace: stackTrace);
      messageQueue.clear();
      await loadMessages();
      _emit(ShowErrorSnackBarEvent('$e'));
    } finally {
      if (awaitingAsyncTask) {
        // Async path: don't clear streamingMessageId / isProcessing here —
        // the activeTask.onTaskFinished callback owns that cleanup and will
        // fire when the agent's SDK turn actually ends. We still drain the
        // send queue so the next queued message can start preparing.
        processNextInQueue();
      } else {
        acpCancellationToken = null;
        streamingMessageId = null;
        streamingContent = '';
        pendingHistoryRequest = null;
        isProcessing = false;
        _notify();
        processNextInQueue();
      }
    }
  }

  void _updateStreamingMetadata(Map<String, dynamic> metadata) {
    final idx = messages.indexWhere((m) => m.id == streamingMessageId);
    if (idx != -1) {
      final updated = Message(
        id: streamingMessageId!,
        content: streamingContent,
        timestampMs: messages[idx].timestampMs,
        from: messages[idx].from,
        to: messages[idx].to,
        type: MessageType.text,
        metadata: metadata,
      );
      messages[idx] = updated;
      messageIdMap[updated.id] = updated;
    }
    _notify();
  }

  void _updateGroupStreamingMetadata(String streamingId, String key, Map<String, dynamic> data) {
    final existing = messageIdMap[streamingId];
    if (existing != null) {
      final idx = messages.indexOf(existing);
      if (idx != -1) {
        final existingMetadata = Map<String, dynamic>.from(messages[idx].metadata ?? {});
        existingMetadata[key] = Map<String, dynamic>.from(data);
        final updated = Message(
          id: streamingId,
          content: messages[idx].content,
          timestampMs: messages[idx].timestampMs,
          from: messages[idx].from,
          to: messages[idx].to,
          type: messages[idx].type,
          metadata: existingMetadata,
        );
        messages[idx] = updated;
        messageIdMap[updated.id] = updated;
      }
    }
    _notify();
  }

  Future<void> _handleFileMessage(Map<String, dynamic> fileData) async {
    try {
      final url = fileData['url'] as String?;
      final filename = fileData['filename'] as String?;
      final fileMimeType = fileData['mime_type'] as String?;
      int? size = (fileData['size'] as num?)?.toInt();
      final thumbnailBase64 = fileData['thumbnail_base64'] as String?;

      // Prefer explicit file_id field, fall back to extracting from URL path
      String? fileId = fileData['file_id'] as String?;
      if ((fileId == null || fileId.isEmpty) && url != null && url.isNotEmpty) {
        try {
          final uri = Uri.parse(url);
          if (uri.hasScheme &&
              uri.pathSegments.length >= 2 &&
              uri.pathSegments[uri.pathSegments.length - 2] == 'files') {
            fileId = uri.pathSegments.last;
          }
        } catch (_) {}
      }

      // Need at least a url or file_id to handle the message
      if ((url == null || url.isEmpty) && (fileId == null || fileId.isEmpty)) return;

      // If size is missing or zero and url is a non-empty local path, read from filesystem
      if ((size == null || size == 0) && url != null && url.isNotEmpty && !url.startsWith('http')) {
        try {
          final f = File(url);
          if (await f.exists()) size = await f.length();
        } catch (_) {}
      }

      final isImage = fileMimeType != null && fileMimeType.startsWith('image/');
      final msgType = isImage ? MessageType.image : MessageType.file;

      final metadata = <String, dynamic>{
        'download_status': 'pending',
        'name': filename ?? 'file',
        'type': fileMimeType ?? 'application/octet-stream',
        'size': size ?? 0,
      };

      if (url != null && url.isNotEmpty) metadata['source_url'] = url;

      if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
        metadata['thumbnail_base64'] = thumbnailBase64;
      }

      if (fileId != null) {
        metadata['file_id'] = fileId;
      }

      final currentAgentName = agentName ?? 'Agent';
      final messageId = 'file_${DateTime.now().millisecondsSinceEpoch}';
      await localDatabaseService.createMessage(
        id: messageId,
        channelId: currentChannelId ?? '',
        senderId: agentId ?? '',
        senderType: 'agent',
        senderName: currentAgentName,
        content: isImage
            ? '[Image: ${filename ?? "image"}]'
            : '[File: ${filename ?? "file"}]',
        messageType: msgType.toString().split('.').last,
        metadata: metadata,
      );

      await loadMessages();
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_fileMessageFailed:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Process group message
  // ---------------------------------------------------------------------------

  Future<void> processGroupMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<MentionEntry> mentions = const []}) async {
    if (currentChannelId == null || groupAgents.isEmpty) {
      LoggerService().debug('processGroupMessage ABORTED: channelId=$currentChannelId, groupAgents=${groupAgents.length}', tag: 'ChatController');
      return;
    }
    LoggerService().debug('processGroupMessage: channelId=$currentChannelId, agents=${groupAgents.map((a) => a.name).toList()}, adminId=$groupAdminAgentId', tag: 'ChatController');

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    acpCancellationToken = ACPCancellationToken();
    _notify();

    final userMessage = Message(
      id: 'temp_user_${DateTime.now().millisecondsSinceEpoch}',
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: replyToId,
    );
    messages.add(userMessage);
    messageIdMap[userMessage.id] = userMessage;
    _notify();
    _emit(RequestScrollToBottomEvent(force: true));

    final streamingIds = <String, String>{};
    final streamingContents = <String, String>{};

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();

      // Determine which agents to actually trigger based on structured mentions.
      // If the caller provided explicit MentionEntry list, use notify:true entries.
      // Fall back to legacy text-parsing when no structured mentions are provided
      // (e.g. queued messages, agent-triggered flows).
      List<String> mentionedAgentIds;
      if (mentions.isNotEmpty) {
        final notifyMentions = mentions.where((m) => m.notify).toList();
        if (notifyMentions.any((m) => m.id == 'all')) {
          mentionedAgentIds = agentIds;
        } else {
          mentionedAgentIds = notifyMentions.map((m) => m.id).toList();
        }
      } else {
        mentionedAgentIds = parseMentionedAgentIds(content);
      }

      // Build metadata to persist on the user message.
      final Map<String, dynamic>? userMsgMetadata = mentions.isNotEmpty
          ? {'mentions': mentions.map((m) => m.toJson()).toList()}
          : null;

      await chatService.sendMessageToGroup(
        channelId: currentChannelId!,
        content: content,
        userId: userId,
        userName: userName,
        agentIds: agentIds,
        mentionedAgentIds: mentionedAgentIds,
        mentionOnlyMode: mentionOnlyMode,
        adminAgentId: groupAdminAgentId,
        replyToId: replyToId,
        flowMode: groupChannel?.flowMode ?? false,
        acpCancellationToken: acpCancellationToken,
        userMessageMetadata: userMsgMetadata,
        onAgentStart: (aid, anm) {
          final sid = 'group_streaming_${aid}_${DateTime.now().millisecondsSinceEpoch}';
          streamingIds[aid] = sid;
          streamingContents[aid] = '';
          final sm = Message(
            id: sid,
            content: '',
            timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
            from: MessageFrom(id: aid, type: 'agent', name: anm),
            to: MessageFrom(id: userId, type: 'user', name: userName),
            type: MessageType.text,
          );
          respondingAgentNames.add(anm);
          groupStreamingMessageIds.add(sid);
          messages.add(sm);
          messageIdMap[sm.id] = sm;
          _notify();
          _emit(RequestScrollToBottomEvent(force: true));
        },
        onStreamChunk: (aid, anm, chunk) {
          final sid = streamingIds[aid];
          if (sid == null) return;
          streamingContents[aid] = (streamingContents[aid] ?? '') + chunk;
          final updatedContent = streamingContents[aid]!;
          final existing = messageIdMap[sid];
          if (existing != null) {
            final idx = messages.indexOf(existing);
            if (idx != -1) {
              final updated = Message(
                id: sid,
                content: updatedContent,
                timestampMs: messages[idx].timestampMs,
                from: messages[idx].from,
                to: messages[idx].to,
                type: MessageType.text,
              );
              messages[idx] = updated;
              messageIdMap[updated.id] = updated;
            }
          }
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
        onAgentDone: (aid, anm, skipped) {
          final sid = streamingIds[aid];
          if (skipped && sid != null) {
            messages.removeWhere((m) => m.id == sid);
            messageIdMap.remove(sid);
            groupStreamingMessageIds.remove(sid);
          } else if (sid != null) {
            groupStreamingMessageIds.remove(sid);
          }
          streamingIds.remove(aid);
          streamingContents.remove(aid);
          respondingAgentNames.remove(anm);
          _notify();
        },
        onAllDone: () {},
        onActiveWorkflowChanged: (workflowId) => setActiveWorkflowId(workflowId),
        onInteractionRequest: (agentId, agentName, interactionType, data) async {
          // Determine the message ID to attach the interactive component to.
          // If the agent is still streaming, use the streaming message ID.
          // If the agent has already finished (local LLM path), the streaming
          // ID is gone — reconcile first so the DB message is in the list,
          // then use the saved message ID injected by the service.
          var sid = streamingIds[agentId];
          if (sid == null) {
            // Agent already done — reconcile to load DB message into the list
            await reconcileGroupMessages();
            final savedMsgId = data.remove('_savedMessageId') as String?;
            if (savedMsgId != null && messageIdMap.containsKey(savedMsgId)) {
              sid = savedMsgId;
            }
          }

          // 1. Update message metadata to show the interactive component
          if (sid != null) {
            _updateGroupStreamingMetadata(sid, interactionType, data);
            // Persist the interaction metadata to DB so it survives a channel
            // switch. Without this, returning to the chat reloads from DB and
            // the plan_approval / action_confirmation card is missing, making
            // the message appear blank or invisible.
            // updateMessageMetadata overwrites the entire metadata field, so
            // merge with whatever is already in memory before writing.
            final existingMeta = Map<String, dynamic>.from(
                messageIdMap[sid]?.metadata ?? {});
            existingMeta[interactionType] = data;
            localDatabaseService
                .updateMessageMetadata(sid, existingMeta)
                .ignore();
          }

          // 2. Create event, track it, emit, and await with timeout
          final event = GroupInteractionRequestEvent(
            agentId: agentId,
            agentName: agentName,
            interactionType: interactionType,
            data: data,
            groupStreamingMessageId: sid ?? agentId,
          );
          pendingGroupInteractions[sid ?? agentId] = event;
          _notify();
          _emit(event);

          // form / file_upload / action_confirmation / single_select / multi_select
          // are always non-blocking: the current turn ends immediately so the
          // user can interact with the component.
          // plan_approval is also non-blocking here: the actual blocking wait is
          // managed by ChatService._pendingPlanApprovals, which survives channel
          // navigation. The UI card is already persisted to DB by the code above.
          const _nonBlockingTypes = {'form', 'file_upload', 'action_confirmation', 'single_select', 'multi_select', 'plan_approval'};
          if (_nonBlockingTypes.contains(interactionType)) {
            if (!event.result.isCompleted) {
              event.result.complete(const {'_non_blocking': true});
            }
            pendingGroupInteractions.remove(sid ?? agentId);
            _notify();
            return const {'_non_blocking': true};
          }

          try {
            return await event.result.future.timeout(
              const Duration(minutes: 5),
              onTimeout: () => null,
            );
          } finally {
            pendingGroupInteractions.remove(sid ?? agentId);
            _notify();
          }
        },
      );

      await reconcileGroupMessages();
      markMessagesAsReadIfAtBottom();
    } catch (e, stackTrace) {
      LoggerService().error('processGroupMessage error: $e', tag: 'ChatController', error: e, stackTrace: stackTrace);
      _emit(ShowErrorSnackBarEvent('chat_groupChatError:$e'));
    } finally {
      acpCancellationToken = null;
      streamingMessageId = null;
      streamingContent = '';
      // Complete all pending group interaction Completers with null
      for (final e in pendingGroupInteractions.values) {
        if (!e.result.isCompleted) e.result.complete(null);
      }
      pendingGroupInteractions.clear();
      isProcessing = false;
      respondingAgentNames.clear();
      groupStreamingMessageIds.clear();
      _notify();
      processNextInQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Send attachment to agent
  // ---------------------------------------------------------------------------

  Future<void> sendAttachmentToAgent(Message attachmentMessage) async {
    final attachmentData = await attachmentService.buildAttachmentData(attachmentMessage);
    if (attachmentData == null) return;
    if (attachmentData.exceedsSizeLimit) {
      _emit(ShowSnackBarEvent('File too large (max 20MB) to send to agent'));
      return;
    }

    final userId = getUserId();
    final userName = getUserName();

    isProcessing = true;
    _notify();

    acpCancellationToken = ACPCancellationToken();

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      final isLocal = LocalLLMAgentService.instance.isLocalAgent(remoteAgent);
      if (!isLocal && remoteAgent.endpoint.isEmpty) {
        throw Exception('Agent has no valid endpoint');
      }

      streamingMessageId = 'streaming_${DateTime.now().millisecondsSinceEpoch}';
      streamingContent = '';
      final sm = Message(
        id: streamingMessageId!,
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch + 1,
        from: MessageFrom(id: remoteAgent.id, type: 'agent', name: remoteAgent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        type: MessageType.text,
      );

      messages.add(sm);
      messageIdMap[sm.id] = sm;
      _notify();
      _emit(RequestScrollToBottomEvent(force: true));

      final agentResponse = await chatService.sendMessageToAgent(
        content: attachmentMessage.content,
        agent: remoteAgent,
        userId: userId,
        userName: userName,
        channelId: currentChannelId,
        dmSystemPrompt: dmSystemPrompt,
        acpCancellationToken: acpCancellationToken,
        attachments: [attachmentData],
        existingUserMessage: attachmentMessage,
        onStreamChunk: (chunk) {
          streamingContent += chunk;
          final idx = messages.indexWhere((m) => m.id == streamingMessageId);
          if (idx != -1) {
            final updated = Message(
              id: streamingMessageId!,
              content: streamingContent,
              timestampMs: messages[idx].timestampMs,
              from: messages[idx].from,
              to: messages[idx].to,
              type: MessageType.text,
              metadata: messages[idx].metadata,
            );
            messages[idx] = updated;
            messageIdMap[updated.id] = updated;
          }
          scheduleStreamingRebuild();
          if (!isUserScrolledUp) {
            _emit(RequestScrollToBottomEvent());
          }
        },
      );

      if (agentResponse != null) {
        final idx = messages.indexWhere((m) => m.id == streamingMessageId);
        if (idx != -1) {
          messages[idx] = agentResponse;
          messageIdMap.remove(streamingMessageId);
          messageIdMap[agentResponse.id] = agentResponse;
        }
        _notify();
      } else {
        messages.removeWhere((m) => m.id == streamingMessageId);
        messageIdMap.remove(streamingMessageId);
        _notify();
      }
    } catch (e) {
      messages.removeWhere((m) => m.id == streamingMessageId);
      messageIdMap.remove(streamingMessageId);
      _notify();
    } finally {
      streamingMessageId = null;
      streamingContent = '';
      isProcessing = false;
      _notify();
      processNextInQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Interactive response handlers (delegates to InteractiveResponseHandler)
  // ---------------------------------------------------------------------------

  /// Helper: for group chat with local LLM agents that have already finished,
  /// just persist the user's interactive response to the message metadata in
  /// DB.  Returns true if handled (caller should return early).
  Future<bool> _handleGroupInteractionLocally(
    Message originalMessage,
    String metadataKey,
    Map<String, dynamic> selectedData, {
    String? responseText,
  }) async {
    if (!isGroupMode) return false;
    final updatedMeta = Map<String, dynamic>.from(originalMessage.metadata ?? {});
    final section = Map<String, dynamic>.from(
      updatedMeta[metadataKey] as Map<String, dynamic>? ?? {},
    );
    section.addAll(selectedData);
    section['selected_at'] = DateTime.now().millisecondsSinceEpoch;
    updatedMeta[metadataKey] = section;

    // Update in-memory message
    final idx = messages.indexWhere((m) => m.id == originalMessage.id);
    if (idx != -1) {
      final updated = Message(
        id: originalMessage.id,
        content: originalMessage.content,
        timestampMs: originalMessage.timestampMs,
        from: originalMessage.from,
        to: originalMessage.to,
        type: originalMessage.type,
        replyTo: originalMessage.replyTo,
        metadata: updatedMeta,
      );
      messages[idx] = updated;
      messageIdMap[updated.id] = updated;
      _notify();
    }

    try {
      await localDatabaseService.updateMessageMetadata(originalMessage.id, updatedMeta);
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }

    // For local LLM agents, trigger a follow-up round so the agent can
    // process the user's interaction response and generate a reply.
    // Prefix with @agentName so the agent has context that it is being
    // directly addressed (needed for it to generate UI widgets like
    // action_confirmation).  When there is a group admin and the mentioned
    // agent IS the admin, sendMessageToGroup will detect that the sole
    // mention is the admin and fall through to the admin orchestration loop
    // (path 5b) rather than the simple direct-dispatch path (5a), so the
    // admin's subsequent @mentions of member agents will still be honoured.
    if (responseText != null && originalMessage.from.isAgent) {
      final agentName = originalMessage.from.name;
      Future.microtask(() => processGroupMessage('@$agentName $responseText'));
    }

    return true;
  }

  void handlePlanApprovalResponded(
    Message originalMessage,
    bool approved, {
    String? feedback,
    List<String>? skippedTaskIds,
  }) {
    // Update UI immediately
    _updateGroupStreamingMetadata(
      originalMessage.id,
      'plan_approval_responded',
      {'approved': approved},
    );
    // Merge _approved into the plan_approval data so the card badge updates
    final existing = messageIdMap[originalMessage.id];
    if (existing != null) {
      final existingPlanData = existing.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (existingPlanData != null) {
        final merged = Map<String, dynamic>.from(existingPlanData);
        merged['_approved'] = approved;
        _updateGroupStreamingMetadata(originalMessage.id, 'plan_approval', merged);
      }
    }

    // Submit result through ChatService Completer (survives channel switch)
    if (currentChannelId != null) {
      chatService.completePlanApproval(currentChannelId!, {
        'approved': approved,
        if (feedback != null && feedback.isNotEmpty) 'feedback': feedback,
        if (skippedTaskIds != null && skippedTaskIds.isNotEmpty)
          'skipped_task_ids': skippedTaskIds,
      });
    }
  }

  Future<void> handleActionSelected(
    Message originalMessage,
    String confirmationId,
    String actionId,
    String actionLabel, {
    String? confirmationContext,
  }) async {
    LoggerService().info(
      'handleActionSelected: confirmationId=$confirmationId, '
      'actionId=$actionId, label="$actionLabel", '
      'context=$confirmationContext, isProcessing=$isProcessing',
      tag: 'ChatController',
    );
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_action_id': actionId,
        'selected_action_label': actionLabel,
      });
      _updateGroupStreamingMetadata(originalMessage.id, 'action_confirmation_responded', {'action_id': actionId, 'action_label': actionLabel});
      return;
    }

    // Check if this is a plan confirmation (agent used action_confirmation instead of
    // the system plan_approval UI). Use execution-trigger phrasing so the admin knows
    // to proceed with task delegation rather than re-plan.
    final isPlanConfirm = confirmationId.startsWith('plan_confirm');
    final responseTextForGroup = isPlanConfirm && actionId != 'modify'
        ? 'User selected action: $actionLabel. 请立即开始按计划执行，直接委派任务给各成员，不要重新输出计划。'
        : 'User selected action: $actionLabel';

    if (await _handleGroupInteractionLocally(originalMessage, 'action_confirmation', {
      'selected_action_id': actionId,
    }, responseText: responseTextForGroup)) return;

    // NOTE: intentionally NOT gated on `isProcessing`. An action-confirmation
    // tap is a reply to the in-flight task, not a fresh user turn — for ACP
    // agents (e.g. codebuddy-code's canUseTool), the reply is delivered as
    // a new `agent.chat` that the agent classifies as an allow/deny verdict,
    // and only THEN does the original task's `task.completed` fire. Guarding
    // on `isProcessing` here would drop the tap silently, stranding the user
    // (task hangs forever, UI spinner never clears).

    try {
      await interactiveResponseHandler.handleActionConfirmation(
        originalMessage: originalMessage,
        confirmationId: confirmationId,
        actionId: actionId,
        actionLabel: actionLabel,
        confirmationContext: confirmationContext,
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleSingleSelectSubmitted(
    Message originalMessage,
    String selectId,
    String optionId,
    String optionLabel,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({
        'selected_option_id': optionId,
        'selected_option_label': optionLabel,
      });
      _updateGroupStreamingMetadata(originalMessage.id, 'single_select_responded', {'option_id': optionId, 'option_label': optionLabel});
      return;
    }
    // See handleActionSelected for why `isProcessing` is not checked here.

    if (await _handleGroupInteractionLocally(originalMessage, 'single_select', {
      'selected_option_id': optionId,
    }, responseText: 'Selected: $optionLabel')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'single_select',
        selectedData: {'selected_option_id': optionId},
        responseText: 'Selected: $optionLabel',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleMultiSelectSubmitted(
    Message originalMessage,
    String selectId,
    List<String> optionIds,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'selected_option_ids': optionIds});
      _updateGroupStreamingMetadata(originalMessage.id, 'multi_select_responded', {'option_ids': optionIds});
      return;
    }
    // See handleActionSelected for why `isProcessing` is not checked here.

    if (await _handleGroupInteractionLocally(originalMessage, 'multi_select', {
      'selected_option_ids': optionIds,
    }, responseText: 'Selected: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'multi_select',
        selectedData: {'selected_option_ids': optionIds},
        responseText: 'Selected: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleFileUploadSubmitted(
    Message originalMessage,
    String uploadId,
    List<Map<String, dynamic>> files,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'uploaded_files': files});
      _updateGroupStreamingMetadata(originalMessage.id, 'file_upload_responded', {'files': files});
      return;
    }
    if (isProcessing && !isGroupMode) return;


    if (await _handleGroupInteractionLocally(originalMessage, 'file_upload', {
      'uploaded_files': files,
    }, responseText: 'Uploaded files: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'file_upload',
        selectedData: {'uploaded_files': files},
        responseText: 'Uploaded files: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  Future<void> handleFormSubmitted(
    Message originalMessage,
    String formId,
    Map<String, dynamic> values,
    String summary,
  ) async {
    final pending = pendingGroupInteractions[originalMessage.id];
    if (pending != null && !pending.result.isCompleted) {
      pending.result.complete({'submitted_values': values});
      _updateGroupStreamingMetadata(originalMessage.id, 'form_responded', {'values': values});
      return;
    }
    if (isProcessing && !isGroupMode) return;

    if (await _handleGroupInteractionLocally(originalMessage, 'form', {
      'submitted_values': values,
    }, responseText: 'Form submitted: $summary')) return;

    try {
      await interactiveResponseHandler.handleSelectResponse(
        originalMessage: originalMessage,
        metadataKey: 'form',
        selectedData: {'submitted_values': values},
        responseText: 'Form submitted: $summary',
      );
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Reply
  // ---------------------------------------------------------------------------

  void startReply(Message message) {
    replyingToMessage = message;
    _notify();
  }

  void cancelReply() {
    replyingToMessage = null;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  Future<void> searchMessages(String query) async {
    if (query.trim().isEmpty) {
      searchQuery = '';
      isSearching = false;
      _notify();
      await loadMessages();
      return;
    }

    isSearching = true;
    searchQuery = query;
    _notify();

    try {
      final results = await searchService.searchMessages(
        query: query,
        channelId: currentChannelId,
      );

      messages = results.map((r) => r.message).toList();
      rebuildMessageIdMap();
      isSearching = false;
      _notify();
    } catch (e) {
      isSearching = false;
      _notify();
      _emit(ShowErrorSnackBarEvent('chat_searchError:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Message operations
  // ---------------------------------------------------------------------------

  Future<void> deleteMessage(Message message) async {
    if (message.type == MessageType.image || message.type == MessageType.file || message.type == MessageType.audio) {
      await attachmentService.deleteAttachment(message);
    } else {
      await chatService.deleteMessage(message.id);
    }

    messages.removeWhere((m) => m.id == message.id);
    messageIdMap.remove(message.id);
    _notify();
  }

  Future<void> rollbackMessage(Message message, {bool reEdit = false}) async {
    if (agentId == null || currentChannelId == null) return;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      await chatService.rollbackFromMessage(
        messageId: message.id,
        channelId: currentChannelId!,
        agent: remoteAgent,
      );

      await loadMessages();
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_rollbackFailed:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  void resetSession(TextEditingController messageController) {
    messageController.text = '/reset';
    // The UI will call sendMessage
  }

  Future<void> createNewSession() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();

    try {
      final newChannelId = await chatService.createNewSession(
        userId: userId,
        userName: userName,
        agentId: agentId!,
        agentName: agentName ?? 'Agent',
      );

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);

      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        agentId: agentId,
        agentName: agentName,
        agentAvatar: agentAvatar,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_newSessionFailed:$e'));
    }
  }

  Future<void> createNewGroupSession() async {
    if (groupChannel == null || currentChannelId == null) return;

    final userId = getUserId();

    try {
      final newChannelId = await chatService.createNewGroupSession(
        channelId: currentChannelId!,
        userId: userId,
      );

      await localDatabaseService.touchChannelUpdatedAt(newChannelId);

      _emit(NavigateToSessionEvent(
        channelId: newChannelId,
        embedded: embedded,
      ));
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_newGroupSessionFailed:$e'));
    }
  }

  Future<void> clearCurrentSessionHistory() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final sessionId = currentChannelId
        ?? await chatService.getLatestActiveChannelId(userId, agentId!)
        ?? chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingSession'));

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);

      if (remoteAgent != null && remoteAgent.isOnline) {
        try {
          await chatService.sendMessageToAgent(
            content: '/reset',
            agent: remoteAgent,
            userId: userId,
            userName: userName,
            channelId: sessionId,
          );
        } catch (_) {}
      }

      final sessions = await chatService.getAgentSessions(agentId: agentId!);

      if (sessions.length > 1) {
        await localDatabaseService.deleteChannelMessages(sessionId);
        await localDatabaseService.deleteChannel(sessionId);

        final remaining = sessions.where((s) => s.id != sessionId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
        ));
      } else {
        await localDatabaseService.deleteChannelMessages(sessionId);

        _emit(DismissOverlayEvent());
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_sessionCleared'));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearSessionFailed:$e'));
    }
  }

  Future<void> clearAllSessionsHistory() async {
    if (agentId == null) return;

    final userId = getUserId();
    final userName = getUserName();
    final sessionId = currentChannelId
        ?? await chatService.getLatestActiveChannelId(userId, agentId!)
        ?? chatService.generateChannelId(userId, agentId!);

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);

      if (remoteAgent != null && remoteAgent.isOnline) {
        try {
          await chatService.sendMessageToAgent(
            content: '/reset-all',
            agent: remoteAgent,
            userId: userId,
            userName: userName,
            channelId: sessionId,
          );
        } catch (_) {}
      }

      final sessions = await chatService.getAgentSessions(agentId: agentId!);
      final defaultChannelId = chatService.generateChannelId(userId, agentId!);

      for (final session in sessions) {
        await localDatabaseService.deleteChannelMessages(session.id);
        if (session.id != defaultChannelId) {
          await localDatabaseService.deleteChannel(session.id);
        }
      }

      final defaultChannel = await localDatabaseService.getChannelById(defaultChannelId);
      if (defaultChannel == null) {
        final channel = Channel.withMemberIds(
          id: defaultChannelId,
          name: 'Chat with ${agentName ?? 'Agent'}',
          type: 'dm',
          memberIds: [userId, agentId!],
          isPrivate: true,
        );
        await localDatabaseService.createChannel(channel, userId);
      }

      _emit(DismissOverlayEvent());
      final isAlreadyDefault = currentChannelId == defaultChannelId;

      if (isAlreadyDefault) {
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_allSessionsCleared'));
      } else {
        _emit(NavigateToSessionEvent(
          channelId: defaultChannelId,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
        ));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearAllSessionsFailed:$e'));
    }
  }

  Future<void> clearGroupSessionHistory() async {
    if (groupChannel == null || currentChannelId == null) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingGroupSession'));

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final parentGroupId = groupChannel!.groupFamilyId;
      final sessions = await chatService.getGroupSessions(parentGroupId: parentGroupId);

      if (sessions.length > 1) {
        await chatService.clearGroupSessionHistory(
          channelId: currentChannelId!,
          agentIds: agentIds,
        );
        await localDatabaseService.deleteChannel(currentChannelId!);

        final remaining = sessions.where((s) => s.id != currentChannelId).toList();
        final targetSession = remaining.first;

        _emit(DismissOverlayEvent());
        _emit(NavigateToSessionEvent(
          channelId: targetSession.id,
          embedded: embedded,
        ));
      } else {
        await chatService.clearGroupSessionHistory(
          channelId: currentChannelId!,
          agentIds: agentIds,
        );

        _emit(DismissOverlayEvent());
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_groupSessionCleared'));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearGroupSessionFailed:$e'));
    }
  }

  Future<void> clearAllGroupSessionsHistory() async {
    if (groupChannel == null || currentChannelId == null) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingAllGroupSessions'));

    try {
      final agentIds = groupAgents.map((a) => a.id).toList();
      final parentGroupId = groupChannel!.groupFamilyId;

      await chatService.clearAllGroupSessions(
        parentGroupId: parentGroupId,
        currentChannelId: currentChannelId!,
        agentIds: agentIds,
      );

      _emit(DismissOverlayEvent());
      final isAlreadyParent = currentChannelId == parentGroupId;

      if (isAlreadyParent) {
        messages.clear();
        messageIdMap.clear();
        _notify();
        _emit(ShowSnackBarEvent('chat_allGroupSessionsCleared'));
      } else {
        _emit(NavigateToSessionEvent(
          channelId: parentGroupId,
          embedded: embedded,
        ));
      }
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearAllGroupSessionsFailed:$e'));
    }
  }

  Future<void> batchDeleteSessions(List<String> sessionIds, {required bool isGroup}) async {
    if (sessionIds.isEmpty) return;

    _emit(ShowLoadingOverlayEvent('chat_clearingAllSessions'));

    try {
      // Guard: never delete the parent group channel itself, only child sessions.
      // Use groupFamilyId so the parent is protected regardless of which session is currently open.
      final parentGroupId = groupChannel?.groupFamilyId;
      final idsToDelete = isGroup && parentGroupId != null
          ? sessionIds.where((id) => id != parentGroupId).toList()
          : sessionIds;

      for (final id in idsToDelete) {
        await localDatabaseService.deleteChannelMessages(id);
        await localDatabaseService.deleteChannel(id);
      }

      _emit(DismissOverlayEvent());
      _emit(ShowSnackBarEvent('chat_batchDeleteSuccess:${idsToDelete.length}'));
    } catch (e) {
      _emit(DismissOverlayEvent());
      _emit(ShowErrorSnackBarEvent('chat_clearSessionFailed:$e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Group member management
  // ---------------------------------------------------------------------------

  Future<void> addGroupMember(RemoteAgent agent) async {
    if (currentChannelId == null) return;

    await localDatabaseService.addChannelMember(currentChannelId!, agent.id);

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: true,
    );
    messages.add(systemMsg);
    messageIdMap[systemMsg.id] = systemMsg;
    _notify();
    _emit(RequestScrollToBottomEvent());

    await refreshGroupMembers();
  }

  Future<void> removeGroupMember(RemoteAgent agent) async {
    if (currentChannelId == null) return;

    await localDatabaseService.removeChannelMember(currentChannelId!, agent.id);

    final systemMsg = await chatService.notifyGroupMembershipChange(
      currentChannelId!,
      agent.id,
      agent.name,
      isJoin: false,
    );
    messages.add(systemMsg);
    messageIdMap[systemMsg.id] = systemMsg;
    _notify();
    _emit(RequestScrollToBottomEvent());

    await refreshGroupMembers();
  }

  Future<void> refreshGroupMembers() async {
    if (currentChannelId == null) return;
    final userId = getUserId();

    final channel = await localDatabaseService.getChannelById(currentChannelId!);
    final memberIds = await localDatabaseService.getChannelMemberIds(currentChannelId!);
    final agentIdsList = memberIds.where((id) => id != userId && id != 'user').toList();
    final agents = <RemoteAgent>[];
    for (final aid in agentIdsList) {
      final agent = await localDatabaseService.getRemoteAgentById(aid);
      if (agent != null) agents.add(agent);
    }

    groupAgents = agents;
    groupChannel = channel;
    groupAdminAgentId = channel?.adminAgentId;
    _notify();
  }

  Future<List<ChannelMember>> saveMemberGroupBio(RemoteAgent agent, String? newGroupBio) async {
    if (currentChannelId == null) return groupChannel?.members ?? [];

    final parentGroupId = groupChannel?.groupFamilyId ?? currentChannelId!;
    final sessions = await localDatabaseService.getGroupSessions(parentGroupId);
    for (final session in sessions) {
      await localDatabaseService.updateChannelMemberGroupBio(session.id, agent.id, newGroupBio);
    }

    await refreshGroupMembers();
    return groupChannel?.members ?? [];
  }

  List<String> parseMentionedAgentIds(String content) {
    if (content.contains('@all')) {
      return groupAgents.map((a) => a.id).toList();
    }
    final mentioned = <String>[];
    for (final agent in groupAgents) {
      if (content.contains('@${agent.name}')) {
        mentioned.add(agent.id);
      }
    }
    return mentioned;
  }

  // ---------------------------------------------------------------------------
  // Group message reconciliation
  // ---------------------------------------------------------------------------

  Future<void> reconcileGroupMessages() async {
    if (currentChannelId == null) return;

    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);

    final tempMessages = <String, int>{};
    for (int i = 0; i < messages.length; i++) {
      final id = messages[i].id;
      if (id.startsWith('group_streaming_') || id.startsWith('temp_user_')) {
        tempMessages[id] = i;
      }
    }

    LoggerService().debug('reconcileGroupMessages: ${tempMessages.length} temp, ${dbMessages.length} db, ${messages.length} total', tag: 'ChatController');

    if (tempMessages.isEmpty) {
      messages = dbMessages;
      rebuildMessageIdMap();
      _notify();
      return;
    }

    final matchedDbIds = <String>{};
    final usedTempIds = <String>{};

    // Pass 1: exact content match
    for (final dbMsg in dbMessages) {
      if (matchedDbIds.contains(dbMsg.id)) continue;
      String? matchedTempId;
      for (final entry in tempMessages.entries) {
        if (usedTempIds.contains(entry.key)) continue;
        final tempMsg = messages[entry.value];
        if (tempMsg.from.id == dbMsg.from.id &&
            tempMsg.content.trim() == dbMsg.content.trim()) {
          matchedTempId = entry.key;
          break;
        }
      }
      if (matchedTempId != null) {
        final idx = tempMessages[matchedTempId]!;
        messages[idx] = dbMsg;
        matchedDbIds.add(dbMsg.id);
        usedTempIds.add(matchedTempId);
        // Migrate any pending interaction keyed on the old streaming ID
        // to the new DB message ID so form/select submissions can still
        // find the Completer after reconciliation replaces the message.
        if (pendingGroupInteractions.containsKey(matchedTempId)) {
          pendingGroupInteractions[dbMsg.id] =
              pendingGroupInteractions.remove(matchedTempId)!;
        }
      }
    }

    // Pass 2: for unmatched DB messages, match by sender ID alone.
    // The DB content may differ from the streaming content because the
    // service strips redundant agent-name prefixes before saving.  When
    // there is exactly one remaining temp message from the same sender,
    // treat it as a match so the streaming placeholder is replaced
    // correctly and doesn't disappear.
    for (final dbMsg in dbMessages) {
      if (matchedDbIds.contains(dbMsg.id)) continue;
      final candidates = tempMessages.entries
          .where((e) => !usedTempIds.contains(e.key) && messages[e.value].from.id == dbMsg.from.id)
          .toList();
      if (candidates.length == 1) {
        final entry = candidates.first;
        final idx = entry.value;
        messages[idx] = dbMsg;
        matchedDbIds.add(dbMsg.id);
        usedTempIds.add(entry.key);
        // Migrate any pending interaction keyed on the old streaming ID
        // to the new DB message ID so form/select submissions can still
        // find the Completer after reconciliation replaces the message.
        if (pendingGroupInteractions.containsKey(entry.key)) {
          pendingGroupInteractions[dbMsg.id] =
              pendingGroupInteractions.remove(entry.key)!;
        }
      }
    }

    LoggerService().debug('reconcileGroupMessages: pass1 matched ${matchedDbIds.length}, pass2 total matched ${usedTempIds.length}', tag: 'ChatController');

    // Remove unmatched temp messages, but keep streaming messages that
    // have non-empty content when no corresponding DB message exists —
    // the DB save may have failed and discarding the only copy of the
    // response would lose it permanently.
    final dbSenderIds = dbMessages.map((m) => m.from.id).toSet();
    messages.removeWhere((m) {
      if (!m.id.startsWith('group_streaming_') && !m.id.startsWith('temp_user_')) {
        return false;
      }
      if (usedTempIds.contains(m.id)) return false;
      // Keep streaming messages with content when no DB message was
      // found from this sender (i.e. the DB save likely failed).
      if (m.id.startsWith('group_streaming_') &&
          m.content.trim().isNotEmpty &&
          !dbSenderIds.contains(m.from.id)) {
        return false;
      }
      return true;
    });

    final existingIds = messages.map((m) => m.id).toSet();
    for (final dbMsg in dbMessages) {
      if (!existingIds.contains(dbMsg.id) && !matchedDbIds.contains(dbMsg.id)) {
        messages.add(dbMsg);
      }
    }

    messages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    rebuildMessageIdMap();
    LoggerService().debug('reconcileGroupMessages done: ${messages.length} messages', tag: 'ChatController');
    _notify();
  }

  void scheduleStreamingRebuild() {
    if (_pendingStreamingRebuild) return;
    _pendingStreamingRebuild = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingStreamingRebuild = false;
      _notify();
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void addSystemHint(String text) {
    final hint = Message(
      id: 'hint_${DateTime.now().millisecondsSinceEpoch}',
      content: text,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
    );
    messages.add(hint);
    messageIdMap[hint.id] = hint;
    _notify();
    _emit(RequestScrollToBottomEvent());
  }

  /// Update agent info (e.g. after editing in detail screen)
  void updateAgentInfo(String? name, String? avatar) {
    agentName = name;
    agentAvatar = avatar;
    _notify();
  }
}
