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
import '../services/messaging/agent_messaging_service.dart';
import '../services/local_database_service.dart';
import '../services/attachment_service.dart';
import '../services/message_search_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/local_llm_agent_service.dart';
import '../services/app_lifecycle_service.dart';
import '../services/notification_service.dart';
import '../services/interactive_response_handler.dart';
import '../services/logger_service.dart';
import '../services/she_service.dart';
import '../services/workflow/workflow_service.dart';
import '../services/approval/pending_approval_hub.dart';
import '../services/approval/pending_approval_item.dart';
import '../models/workflow_models.dart';
import '../models/workflow_pending_approval.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_agent_host_service.dart' show isPeerAgentChannel;
import '../peer/services/peer_storage_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent;
import '../peer/peer_approval_selection.dart';
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import '../services/workflow/workflow_restore_planner.dart';
import '../services/workflow/workflow_pending_approval_picker.dart';
import '../services/workflow/workflow_plan_approval_sync.dart';
import '../services/group/group_member_session_service.dart';
import '../services/dispatch/she_relay_session_service.dart';
import 'chat_workflow_coordinator.dart';
import 'chat_attachment_coordinator.dart';
import 'chat_attachment_validator.dart';
import 'chat_streaming_text.dart';
import 'chat_lifecycle_coordinator.dart';
import 'chat_group_streaming_tracker.dart';
import 'group_mention_resolver.dart';
import 'chat_message_reconciler.dart';
import 'chat_send_planner.dart';
import 'dm_send_turn_planner.dart';
import 'group_interaction_planner.dart';
import 'peer_device_label_resolver.dart';
import 'chat_load_channel_planner.dart';
import 'streaming_action_confirmation.dart';
import 'inbound_file_message_parser.dart';
import 'peer_approval_completer_resolver.dart';
import 'chat_events.dart';

// ChatEvent 及其全部子类已拆分到 chat_events.dart，这里重新导出，
// 使现有 `import '../controllers/chat_controller.dart'` 的调用方无需改动。
export 'chat_events.dart';

// 部分低耦合的方法簇（会话管理、群成员管理）以 part + mixin 形式拆到独立文件，
// 与本文件同属一个库，因此可直接访问 _ChatControllerBase 的私有字段与辅助方法。
part 'chat_controller_sessions.dart';
part 'chat_controller_group_members.dart';
part 'chat_controller_interactions.dart';
part 'chat_controller_messaging.dart';
part 'chat_controller_workflow.dart';
part 'chat_controller_load.dart';

// ---------------------------------------------------------------------------
// ChatController
// ---------------------------------------------------------------------------

/// ChatController 的状态与核心逻辑基类。
///
/// 持有全部字段、构造与核心方法；低耦合的方法簇通过 part 文件中的 mixin
/// （[_MessagingOps]、[_SessionOps]、[_GroupMemberOps]、[_InteractionOps]）挂载到具体的 [ChatController] 子类上。
abstract class _ChatControllerBase extends ChangeNotifier with InteractiveStreamingContext {
  // ---- Constructor parameters ----
  final String? agentId;
  final String? initialAgentName;
  final String? initialAgentAvatar;
  final String? initialChannelId;
  final bool embedded;
  final VoidCallback? onClose;
  final void Function(String channelId, {String? highlightMessageId})? onSwitchChannel;
  final String Function() getUserId;
  final String Function() getUserName;

  // ---- Services ----
  late final ChatService chatService;
  late final AttachmentService attachmentService;
  late final ChatAttachmentCoordinator attachmentCoordinator;
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
  final ChatStreamingSession streaming = ChatStreamingSession();

  /// DM 流式回合期间收到 DB 写入通知时置位：全量 reload 会顶掉流式占位
  /// 气泡（applyContentTo 找不到目标后流式静默中断），推迟到回合结束
  /// （streaming.clear 触发 onClear）后补一次 reconcile。
  bool _dmReconcileAfterStreaming = false;

  @override
  String? get streamingMessageId => streaming.messageId;
  @override
  set streamingMessageId(String? v) {
    if (v == null) {
      streaming.messageId = null;
    } else {
      streaming.messageId = v;
    }
  }

  @override
  String get streamingContent => streaming.content;
  @override
  set streamingContent(String v) => streaming.content = v;

  // ---- Processing / queue ----
  bool isProcessing = false;
  ACPCancellationToken? acpCancellationToken;
  List<String> messageQueue = [];

  // ---- Agent health state ----
  bool isAgentOnline = false;
  bool isCheckingHealth = true;
  Timer? _healthCheckTimer;

  /// 当前 agent 若来自配对设备（peer agent），记录其来源 peerId。其在线状态跟随
  /// 该设备的 P2P 连接状态，而非普通的健康轮询；为 null 表示非 peer agent。
  String? _agentSourcePeerId;

  /// Whether the current DM agent is a peer-shared agent (protocol=peer).
  /// Used to hide features that only apply to local/ACP agents (e.g. session
  /// system-prompt overrides, which peer relay does not forward).
  bool get isPeerAgent => _agentSourcePeerId != null;

  /// peer 连接状态变化订阅，用于让 peer agent 的在线状态实时跟随设备上/下线。
  StreamSubscription<PeerConnectionEvent>? _peerConnSub;

  /// 孤儿审批（无活动 sendChat turn 的 agent_approval_req，如 hub 重启后
  /// 重放的待决审批）订阅，让卡片仍能渲染在当前会话里。
  StreamSubscription<Map<String, dynamic>>? _orphanApprovalSub;

  // ---- Reply state ----
  Message? replyingToMessage;
  String? highlightedMessageId;

  // ---- Channel / lifecycle ----
  String? currentChannelId;
  final ChatLifecycleCoordinator lifecycle = ChatLifecycleCoordinator();

  /// Subscription to service-side DB writes for the current channel (system
  /// messages, member failure notices) so they surface in the chat
  /// immediately instead of waiting for the next full reconcile.
  StreamSubscription<List<Message>>? _channelUpdateSub;
  StreamSubscription<AgentTaskCompletion>? _agentTaskCompletionSub;
  VoidCallback? _typingListener;

  bool get isAppActive => lifecycle.isAppActive;

  // ---- History request tracking ----
  int historySentCount = 40;
  String? lastUserQuestion;
  Map<String, dynamic>? pendingHistoryRequest;

  // ---- Mutable agent info ----
  String? agentName;
  String? agentAvatar;

  /// 当前会话来源设备标签。仅当本机作为 host、当前会话是某配对设备的入站会话
  /// （channelId 形如 `peer__{peerId}__{agentId}`）时为非空，用于在聊天界面标题
  /// 上标注「来自哪个设备」，避免多设备会话名过长被省略时分不清。
  String? sourceDeviceLabel;

  // ---- Group mode state ----
  bool isGroupMode = false;
  Channel? groupChannel;

  /// She 私聊的工作流能力（She 自规划自执行复杂需求）。
  /// 频道加载时按 `isDM && agentIds.contains(SheService.sheId)` 计算，
  /// 用于解除工作流面板/恢复逻辑的群聊门控。
  bool dmWorkflowEnabled = false;
  List<RemoteAgent> groupAgents = [];
  Set<String> respondingAgentNames = {};
  bool mentionOnlyMode = false;
  String? groupAdminAgentId;
  Set<String> groupStreamingMessageIds = {};
  Map<String, GroupInteractionRequestEvent> pendingGroupInteractions = {};

  /// When viewing a DM that was auto-created for a group member, these point
  /// at the linked group session. Input is disabled; UI offers a jump to group.
  String? sourceGroupChannelId;
  String? sourceGroupName;

  bool get isViewingGroupBoundMemberSession =>
      sourceGroupChannelId != null && sourceGroupChannelId!.isNotEmpty;

  /// When viewing a DM that was auto-created for She's chat/dispatch relay,
  /// this points at the linked She↔user session. Input is disabled; UI offers
  /// a jump to the She conversation.
  String? sourceSheChannelId;

  bool get isViewingSheBoundSession =>
      sourceSheChannelId != null && sourceSheChannelId!.isNotEmpty;

  /// Workflow step streaming placeholders keyed by agent id.
  Map<String, String> get _workflowStreamingIds => workflow.streamingIds;
  Map<String, String> get _workflowStreamingContents =>
      workflow.streamingContents;

  // ---- DM channel system prompt override ----
  /// Custom system prompt set by the user for the current DM channel.
  /// When non-null, overrides the agent's default system prompt.
  String? dmSystemPrompt;

  // ---- Frame coalescing ----
  bool _pendingStreamingRebuild = false;
  bool _pendingStreamingScroll = false;

  /// Workflow panel + local execution bookkeeping.
  final ChatWorkflowCoordinator workflow = ChatWorkflowCoordinator();

  /// The ID of the currently active workflow (set during flow execution).
  String? get activeWorkflowId => workflow.activeWorkflowId;

  /// Whether the floating workflow progress panel should be visible.
  bool get showWorkflowProgressPanel => workflow.showProgressPanel;

  /// Active workflow exists but the user collapsed the progress panel.
  bool get workflowNeedsPanelAttention => workflow.needsPanelAttention;

  // ---- Workflow / load hooks (implemented by mixins) ----
  void reopenWorkflowPanel();
  WorkflowPeerApprovalPending? get workflowPeerApprovalPending;
  WorkflowCancellationToken? get _workflowCancelToken;
  set _workflowCancelToken(WorkflowCancellationToken? value);
  void setActiveWorkflowId(String? id);
  void setWorkflowPeerApprovalPending(WorkflowPeerApprovalPending? pending);
  void dismissWorkflowPanel();
  Future<void> cancelRunningWorkflow();
  Future<void> handleWorkflowApproval(bool approved, {String? feedback});
  Future<void> _resumeWorkflowExecutionIfNeeded(String workflowId);
  Future<void> _restoreWorkflowContext();
  void _markPlanApprovalRespondedForWorkflow(
    String workflowId,
    bool approved, {
    String? feedback,
    bool completeCompleter = true,
  });
  Future<void> _flushPlanApprovalResponseToDb(
    String workflowId,
    bool approved, {
    String? feedback,
  });
  void _preserveInMemoryPlanApprovalResponses();
  void _reapplyStashedPlanApprovalResponses();
  Future<void> _flushAllStashedPlanApprovalResponses();
  Future<void> loadMessages();


  _ChatControllerBase({
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
    attachmentService = AttachmentService(databaseService);
    attachmentCoordinator = ChatAttachmentCoordinator(attachmentService);
    searchService = MessageSearchService(databaseService);
    interactiveResponseHandler = InteractiveResponseHandler(this);
    streaming.onClear = _onStreamingSessionCleared;
  }

  /// 流式回合结束：若期间有 DB 写入通知被推迟，补一次 reconcile（把
  /// dispatch 状态卡、服务侧注入的消息等同步进 UI）。
  void _onStreamingSessionCleared() {
    if (!_dmReconcileAfterStreaming) return;
    _dmReconcileAfterStreaming = false;
    unawaited(reloadMessagesFromDB());
  }

  /// Initialize the controller. Call this after constructing.
  Future<void> init() async {
    await loadMessages();
    refreshAgentStatus();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      refreshAgentStatus();
    });
    // peer agent 的在线状态需实时跟随来源设备上/下线，不能只靠 10s 轮询。
    _peerConnSub = PeerConnectionManager.instance.events.listen((event) {
      if (_agentSourcePeerId != null && event.peerId == _agentSourcePeerId) {
        refreshAgentStatus();
      }
    });
    // 孤儿审批（hub 重启后重放、或 agent_done 抢先完成 turn 的审批）没有
    // 活动 turn 的回调可挂，经这里渲染成普通卡片；点击走 submitApproval
    // 只需 approval_id，bridge 侧有 deferred relay 兜底。
    _orphanApprovalSub =
        PeerAgentClientService.instance.orphanApprovalEvents.listen((event) {
      final peerId = event['peer_id'] as String?;
      final remoteId = event['remote_agent_id'] as String?;
      if (peerId == null || remoteId == null) return;
      if (peerAgentLocalId(peerId, remoteId) != agentId) return;
      _handleStreamingActionConfirmation(event);
    });
  }

  @override
  void dispose() {
    AppLifecycleService().setActiveChannel(null);
    if (currentChannelId != null) {
      chatService.detachTaskUI(currentChannelId!);
      chatService.detachGroupTaskUI(currentChannelId!);
    }
    // Detach workflow UI only — do NOT cancel. ChatService keeps the
    // execution loop alive so switching back reattaches instead of restarting.
    final wfId = activeWorkflowId;
    if (wfId != null) {
      chatService.detachWorkflowExecutionUI(wfId);
    }
    workflow.detachOnDispose();
    messageQueue.clear();
    _healthCheckTimer?.cancel();
    _peerConnSub?.cancel();
    _orphanApprovalSub?.cancel();
    _channelUpdateSub?.cancel();
    _agentTaskCompletionSub?.cancel();
    if (_typingListener != null) {
      chatService.typingChannelIds.removeListener(_typingListener!);
      _typingListener = null;
    }
    // 注意：不要在这里 close 频道的消息流控制器。_messageControllers 是按
    // 频道共享的 broadcast 流，可能还有其他页面（压栈的同频道 ChatScreen、
    // 桌面双栏替换中的新页面）正在监听；close 会让存活页面的订阅静默失效，
    // 服务侧写入的消息从此只能等下次全量加载才显示。
    _eventController.close();
    super.dispose();
  }

  void _emit(ChatEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Implemented by [_MessagingOps]: attach/replace an action-confirmation
  /// card on a host bubble. Called from the base's orphan-approval listener.
  void _handleStreamingActionConfirmation(Map<String, dynamic> actionData);

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
    final shouldHandleResume = lifecycle.onLifecycleChanged(resumed);
    if (!shouldHandleResume) return;

    // Delay DB writes slightly — on iOS the SQLite file handle may still be
    // readonly for a brief moment after the app returns from background.
    Future.delayed(const Duration(milliseconds: 500), () {
      markMessagesAsReadIfAtBottom();
      handleResumeFromBackground();
    });
  }

  Future<void> handleResumeFromBackground() async {
    final bgMs = lifecycle.takeBackgroundedAtMs();
    if (bgMs == null || currentChannelId == null) return;

    final duration = ChatLifecycleCoordinator.backgroundDuration(bgMs);
    if (duration == null) return;

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

      streaming.clear();
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


  // ---- Messaging hooks (implemented by [_MessagingOps]) ----
  void reattachToActiveTask();
  void reattachToGroupActiveTasks();
  void _reattachPendingPlanApproval();
  void scheduleStreamingRebuild();
  void scheduleStreamingScrollToBottom();
  Future<void> processNextInQueue();
  void _updateStreamingMetadata(Map<String, dynamic> metadata);
  Future<void> processMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<Message>? attachmentMessages});
  Future<void> processGroupMessage(String content, {String? replyToId, List<AttachmentData>? attachments, List<MentionEntry> mentions = const []});
  String? _resolveGroupInteractionMessageId({
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
    String? preferredSid,
  });
  void _updateGroupStreamingMetadata(String streamingId, String key, Map<String, dynamic> data);

  // ---- Workflow hooks (implemented by [_WorkflowOps]) ----
  void _handleDmWorkflowPlanCreated(String workflowId, Map<String, dynamic> planData);

  Future<void> reloadMessagesFromDB() async {
    if (currentChannelId == null) return;
    _preserveInMemoryPlanApprovalResponses();
    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
    if (isGroupMode) {
      messages.clear();
      messageIdMap.clear();
      for (final m in dbMessages) {
        messages.add(m);
        messageIdMap[m.id] = m;
      }
    } else {
      // 流式回合进行中：onStreamChunk 正直接驱动 UI，全量替换会顶掉
      // streaming 占位气泡导致流式中断。标记待办，回合结束时补 reconcile。
      // 僵尸防护：服务侧任务已结束（回调被摘除 / 完成事件丢失）而 streaming
      // 仍未 clear 时，继续推迟将永远等不到回合结束 —— 清掉占位立即刷新。
      final deferReload = ChatStreamingSession.shouldDeferReload(
        streamingActive: streaming.isActive,
        hasLiveTask: chatService.getActiveTask(currentChannelId!) != null,
      );
      if (deferReload) {
        _dmReconcileAfterStreaming = true;
        return;
      }
      if (streaming.isActive) streaming.clear();
      _mergeDmStreamingPlaceholders(dbMessages);
      rebuildMessageIdMap();
      if (chatService.getActiveTask(currentChannelId!) == null) {
        isProcessing = false;
        acpCancellationToken = null;
      }
    }
    _reapplyStashedPlanApprovalResponses();
    unawaited(_flushAllStashedPlanApprovalResponses());
    _notify();
    // 消息已展示在当前打开的页面（如 She 频道里的 [Agent Reply] 注入、
    // 服务侧回合的最终回复）→ 同步标记已读，避免对话列表出现"看得见
    // 却消不掉"的未读角标。
    unawaited(markMessagesAsReadIfAtBottom());
  }

  void rebuildMessageIdMap() {
    messageIdMap = {for (final m in messages) m.id: m};
  }

  /// Ensure [messageId] is present in the in-memory list, loading older history if needed.
  Future<bool> ensureMessageLoaded(String messageId) async {
    if (messages.any((m) => m.id == messageId)) return true;
    if (currentChannelId == null) return false;

    try {
      final loadedMessages = await chatService.loadChannelMessagesIncluding(
        currentChannelId!,
        messageId,
      );
      if (!loadedMessages.any((m) => m.id == messageId)) return false;
      messages = loadedMessages;
      rebuildMessageIdMap();
      _notify();
      return true;
    } catch (e) {
      LoggerService().warning(
        'Failed to load message for scroll: $messageId',
        tag: 'ChatController',
        error: e,
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Agent health
  // ---------------------------------------------------------------------------

  Future<void> refreshAgentStatus() async {
    if (agentId == null) return;
    try {
      final agent = await localDatabaseService.getAgentById(agentId!);
      if (agent != null) {
        if (agent.isPeerAgent) {
          // peer agent 通过 P2P 隧道访问对端本地 agent，其可用性完全取决于来源
          // 配对设备是否在线，因此在线状态直接跟随该设备的连接状态。
          _agentSourcePeerId = agent.sourcePeerId;
          final peerId = agent.sourcePeerId;
          isAgentOnline = peerId != null &&
              PeerConnectionManager.instance.getPeerState(peerId) ==
                  PeerConnectionState.connected;
        } else {
          _agentSourcePeerId = null;
          isAgentOnline = agent.status.isOnline;
        }
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

  List<String> parseMentionedAgentIds(String content) {
    return GroupMentionResolver.parseFromContent(
      content,
      [for (final a in groupAgents) (id: a.id, name: a.name)],
    );
  }

  // ---------------------------------------------------------------------------
  // Group message reconciliation
  // ---------------------------------------------------------------------------

  /// Merge in-memory DM `streaming_*` placeholders with DB messages.
  ///
  /// Unlike group chats (which use [reconcileGroupMessages]), DM historically
  /// did a hard replace in [loadMessages], which dropped the live streaming
  /// bubble whenever the final DB row was missing or still empty (e.g. peer
  /// cancel before answer text). Keep the placeholder when it still has
  /// visible content and no usable DB agent message exists yet.
  void _mergeDmStreamingPlaceholders(List<Message> dbMessages) {
    messages = ChatMessageReconciler.mergeDmStreamingPlaceholders(
      current: messages,
      dbMessages: dbMessages,
    );
  }

  Future<void> reconcileGroupMessages() async {
    if (currentChannelId == null) return;

    final dbMessages = await chatService.loadChannelMessages(currentChannelId!);
    final result = ChatMessageReconciler.reconcileGroupMessages(
      current: messages,
      dbMessages: dbMessages,
    );

    LoggerService().debug(
      'reconcileGroupMessages: temps=${messages.where((m) => ChatMessageReconciler.isGroupTempId(m.id)).length}, '
      'db=${dbMessages.length}, migrations=${result.pendingKeyMigrations.length}',
      tag: 'ChatController',
    );

    for (final entry in result.pendingKeyMigrations.entries) {
      if (pendingGroupInteractions.containsKey(entry.key)) {
        pendingGroupInteractions[entry.value] =
            pendingGroupInteractions.remove(entry.key)!;
      }
    }

    messages = result.messages;
    rebuildMessageIdMap();
    LoggerService().debug(
      'reconcileGroupMessages done: ${messages.length} messages',
      tag: 'ChatController',
    );
    _notify();
    unawaited(markMessagesAsReadIfAtBottom());
  }

  /// Subscribe to service-side DB writes for the current channel. Services
  /// (group executor, orchestration, workflow, dispatch/She relay) write
  /// user-visible messages directly to the DB and then call
  /// notifyChannelUpdate; without this listener those messages only appear
  /// after the next full reload (i.e. re-entering the chat). Reconcile is
  /// idempotent and preserves streaming placeholders, so it is safe to run
  /// mid-turn — for DM, [reloadMessagesFromDB] defers while a streaming
  /// session is active and re-runs when it ends.
  void _subscribeChannelUpdates() {
    final cid = currentChannelId;
    if (cid == null) return;
    _channelUpdateSub?.cancel();
    _agentTaskCompletionSub?.cancel();
    _channelUpdateSub = chatService.getMessageStream(cid).listen((_) {
      if (isGroupMode) {
        unawaited(reconcileGroupMessages());
      } else {
        unawaited(reloadMessagesFromDB());
      }
    });
    _agentTaskCompletionSub =
        chatService.agentTaskCompletionStream.listen((event) {
      if (isGroupMode) return;
      if (event.channelId != cid) return;
      unawaited(_handleAgentTaskCompleted(event));
    });
    _subscribeTypingForReattach();
  }

  /// 1:1 回合终态（消息已落库）后的 UI 自愈：补做可能因竞态/detach 漏掉的刷新。
  Future<void> _handleAgentTaskCompleted(AgentTaskCompletion event) async {
    if (_eventController.isClosed) return;
    if (currentChannelId != event.channelId) return;

    _dmReconcileAfterStreaming = false;

    if (streaming.isActive &&
        chatService.getActiveTask(event.channelId) == null) {
      streaming.clear();
    }

    await reloadMessagesFromDB();

    if (chatService.getActiveTask(event.channelId) == null) {
      isProcessing = false;
      acpCancellationToken = null;
      _notify();
    }
  }

  /// 服务侧发起的回合（DispatchService 唤起 She、peer 入站等）开始时，
  /// 打开的聊天页借此挂接流式输出；否则只能在回合结束后一次性看到
  /// 整段回复。用户自己发起的回合不经过这里（isProcessing / streaming
  /// 已占位，守卫会跳过）。
  void _subscribeTypingForReattach() {
    if (_typingListener != null) {
      chatService.typingChannelIds.removeListener(_typingListener!);
      _typingListener = null;
    }
    _typingListener = () {
      if (isGroupMode) return;
      final cid = currentChannelId;
      if (cid == null) return;
      if (!chatService.typingChannelIds.value.contains(cid)) return;
      // 已有 UI 回合在进行（自己发送或已挂接）→ 不重复挂接
      if (streaming.isActive || isProcessing) return;
      if (chatService.getActiveTask(cid) == null) return;
      reattachToActiveTask();
    };
    chatService.typingChannelIds.addListener(_typingListener!);
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

/// 聊天页面控制器。
///
/// 在 [_ChatControllerBase] 的状态与核心逻辑之上，通过 mixin 组合会话管理
/// （[_SessionOps]）与群成员管理（[_GroupMemberOps]）两个职责模块。
class ChatController extends _ChatControllerBase
    with
        _LoadOps,
        _WorkflowOps,
        _MessagingOps,
        _SessionOps,
        _GroupMemberOps,
        _InteractionOps {
  ChatController({
    required super.agentId,
    super.initialAgentName,
    super.initialAgentAvatar,
    super.initialChannelId,
    super.embedded,
    super.onClose,
    super.onSwitchChannel,
    required super.getUserId,
    required super.getUserName,
  });
}
