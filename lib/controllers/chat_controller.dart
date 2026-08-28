import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../models/mention_entry.dart';
import '../models/message.dart';
import '../models/channel.dart';
import '../models/remote_agent.dart';
import '../models/attachment_data.dart';
import '../models/pending_attachment.dart';
import '../models/queued_message.dart';
import '../services/chat_service.dart';
import '../services/messaging/agent_messaging_service.dart';
import '../services/local_database_service.dart';
import '../services/attachment_service.dart';
import '../services/message_search_service.dart';
import '../services/acp_agent_connection.dart';
import '../services/app_lifecycle_service.dart';
import '../services/notification_service.dart';
import '../services/interactive_response_handler.dart';
import '../services/logger_service.dart';
import '../services/she_service.dart';
import '../services/workflow/workflow_service.dart';
import '../services/approval/pending_approval_hub.dart';
import '../services/approval/pending_approval_item.dart';
import '../models/workflow_models.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_agent_host_service.dart' show isPeerAgentChannel;
import '../peer/services/peer_storage_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../storage/store_uri_reader.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent;
import '../peer/peer_approval_selection.dart';
import '../peer/peer_approval_payload.dart';
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import '../services/workflow/workflow_restore_planner.dart';
import '../services/workflow/workflow_pending_approval_picker.dart';
import '../services/workflow/workflow_plan_approval_sync.dart';
import '../services/group/group_member_session_service.dart';
import '../services/dispatch/she_relay_session_service.dart';
import '../services/mailbox/channel_mailbox_service.dart';
import '../services/mailbox/inbox_subscribe_service.dart';
import '../services/noise_identity.dart';
import '../utils/session_utils.dart';
import 'chat_workflow_coordinator.dart';
import 'chat_attachment_coordinator.dart';
import 'chat_attachment_validator.dart';
import 'chat_streaming_text.dart';
import 'chat_lifecycle_coordinator.dart';
import 'chat_group_streaming_tracker.dart';
import 'chat_group_turn_gate.dart';
import 'group_mention_resolver.dart';
import 'chat_message_reconciler.dart';
import 'chat_send_planner.dart';
import 'dm_send_turn_planner.dart';
import 'queued_message_ops.dart';
import 'group_interaction_planner.dart';
import 'peer_device_label_resolver.dart';
import 'chat_load_channel_planner.dart';
import 'streaming_action_confirmation.dart';
import 'inbound_file_message_parser.dart';
import 'peer_approval_completer_resolver.dart';
import 'chat_events.dart';
import 'chat_message_window.dart';
import '../storage/agent_workspace_uris.dart';

// ChatEvent 及其全部子类已拆分到 chat_events.dart，这里重新导出，
// 使现有 `import '../controllers/chat_controller.dart'` 的调用方无需改动。
export 'chat_events.dart';
export 'chat_message_window.dart';

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

  /// True when older history may still exist beyond the in-memory window.
  bool hasMoreOlderMessages = false;

  /// True while [loadOlderMessages] is in flight.
  bool isLoadingOlderMessages = false;

  // ---- Streaming state ----
  final ChatStreamingSession streaming = ChatStreamingSession();

  /// DM 流式回合期间收到 DB 写入通知时置位：全量 reload 会顶掉流式占位
  /// 气泡（applyContentTo 找不到目标后流式静默中断），推迟到回合结束
  /// （streaming.clear 触发 onClear）后补一次 reconcile。
  bool _dmReconcileAfterStreaming = false;

  /// 僵尸 streaming 会话的兜底定时器：回合终态事件丢失（onTaskCompleted /
  /// onTaskError 未达、peer 挂起等）时 streaming.clear() 永不执行，被 defer
  /// 的 DB reconcile 会永久挂起。定时器强制自愈：无存活任务时清掉僵尸占位
  /// 并补做 reload；任务仍存活时不动（终态事件会负责清理，避免顶掉流式占位）。
  Timer? _dmReconcileFallbackTimer;

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

  /// 待发送队列：按频道存放在 ChatService 侧（跨 Controller 生命周期存活）。
  /// 退出聊天页后队列不随 dispose 丢失，重进时由 loadMessages 重新接管发送。
  List<QueuedMessage> get messageQueue =>
      chatService.pendingSendQueue(currentChannelId ?? '');

  /// 群编排代际守卫：stop 后旧编排的 abort-summarize 会跑完（设计上不带
  /// 取消令牌），其 finally/流式回调不得再触碰新轮共享状态。
  final GroupTurnGate groupTurnGate = GroupTurnGate();

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
  StreamSubscription<InboxMailReplyEvent>? _inboxPushSub;
  final List<String> _inboxSubscribeTargetIds = [];
  VoidCallback? _typingListener;

  void _clearInboxPush() {
    _inboxPushSub?.cancel();
    _inboxPushSub = null;
    for (final id in _inboxSubscribeTargetIds) {
      InboxSubscribeService.instance.unsubscribe(id);
    }
    _inboxSubscribeTargetIds.clear();
  }

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

  /// agentId → 储物袋工作区 URI，供消息内相对路径链接打开。
  Map<String, List<String>> workspaceUrisByAgentId = const {};

  List<String> get defaultWorkspaceUris {
    final id = agentId;
    if (id == null) return const [];
    return workspaceUrisByAgentId[id] ?? const [];
  }

  Future<void> _refreshWorkspaceUris() async {
    final agents = <RemoteAgent>[...groupAgents];
    if (agentId != null && !agents.any((a) => a.id == agentId)) {
      final agent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (agent != null) agents.add(agent);
    }
    final map = <String, List<String>>{};
    for (final agent in agents) {
      map[agent.id] = await collectAgentWorkspaceUris(agent);
    }
    workspaceUrisByAgentId = map;
  }
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
  /// Prefetch older history when the user scrolls up. Returns how many
  /// messages were prepended (0 if none / busy / exhausted).
  Future<int> loadOlderMessages();
  Future<void> _refreshHasMoreOlderMessages();


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
    _dmReconcileFallbackTimer?.cancel();
    unawaited(reloadMessagesFromDB());
  }

  /// 为 [_dmReconcileAfterStreaming] 安排兜底：回合终态事件丢失导致
  /// streaming.clear() 永不执行时，被 defer 的 reload 会永久挂起（UI 一直
  /// 停在「等待回复中」，重进才恢复）。30s 后：任务已不在（僵尸会话）→
  /// 清掉占位补做 reload；任务仍存活 → 轮询 DB，本回合回复已落库则强制
  /// reconcile 渲染，未落库则保留占位等下一轮（回合结束仍由终态事件清理）。
  void _scheduleDmReconcileFallback() {
    if (_dmReconcileFallbackTimer?.isActive ?? false) return;
    _dmReconcileFallbackTimer = Timer(const Duration(seconds: 30), () {
      _dmReconcileFallbackTimer = null;
      if (!_dmReconcileAfterStreaming) return;
      final cid = currentChannelId;
      if (cid != null && chatService.getActiveTask(cid) != null) {
        unawaited(_forceDmReconcileWithLiveTask(cid));
        return;
      }
      if (streaming.isActive) {
        // 僵尸占位：clear 触发 onClear → 补做被 defer 的 reload。
        streaming.clear();
      } else {
        _dmReconcileAfterStreaming = false;
        unawaited(reloadMessagesFromDB());
      }
    });
  }

  /// 活回合兜底：DB 已出现本回合的回复行（flush 旁路落库、终态事件丢失）
  /// → 强制 reconcile，回复立即渲染（占位折叠进 flush 行，chunk 继续应用）。
  /// 回复未落库 → 回合仍在进行，保留占位，恢复 defer 标志等下一轮兜底。
  Future<void> _forceDmReconcileWithLiveTask(String cid) async {
    final dbMessages = await chatService.loadChannelMessages(
      cid,
      limit: ChatMessageWindow.initialLimit,
    );
    if (streaming.isActive &&
        !ChatMessageReconciler.dbHasTurnReply(
          dbMessages: dbMessages,
          turnBeganAtMs: streaming.beganAtMs,
        )) {
      _dmReconcileAfterStreaming = true;
      _scheduleDmReconcileFallback();
      return;
    }
    _dmReconcileAfterStreaming = false;
    await reloadMessagesFromDB();
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
    //
    // 群聊必须按 groupAgents 匹配 peer 成员——Controller.agentId 不是 peer
    // 成员 id，若仍按 DM 过滤，审核卡会静默丢失，peer 一直卡在待审。
    _orphanApprovalSub =
        PeerAgentClientService.instance.orphanApprovalEvents.listen((event) {
      final peerId = event['peer_id'] as String?;
      final remoteId = event['remote_agent_id'] as String?;
      if (peerId == null || remoteId == null) return;

      if (isGroupMode) {
        final member = matchGroupPeerAgent(
          groupAgents: groupAgents,
          peerId: peerId,
          remoteAgentId: remoteId,
        );
        if (member == null) return;
        _handleGroupOrphanPeerApproval(
          agentId: member.id,
          agentName: member.name,
          actionData: event,
        );
        return;
      }

      if (peerAgentLocalId(peerId, remoteId) != agentId &&
          legacyPeerAgentLocalId(peerId, remoteId) != agentId) {
        return;
      }
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
    // 注意：不要在这里清空 messageQueue —— 队列按频道存放在 ChatService 侧，
    // 必须跨页面存活，重进后由 loadMessages 恢复发送。
    _healthCheckTimer?.cancel();
    _dmReconcileFallbackTimer?.cancel();
    _peerConnSub?.cancel();
    _orphanApprovalSub?.cancel();
    _channelUpdateSub?.cancel();
    _clearInboxPush();
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

  /// Implemented by [_MessagingOps]: surface a peer orphan approval onto a
  /// group-chat host bubble (and PendingApprovalHub) when sendChat already
  /// finished before `agent_approval_req` arrived.
  void _handleGroupOrphanPeerApproval({
    required String agentId,
    required String agentName,
    required Map<String, dynamic> actionData,
  });

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

    String? messageContent = interruptedInfo['content'];
    if (messageContent == null || messageContent.isEmpty) {
      final userMsgId = interruptedInfo['userMessageId'];
      if (userMsgId != null && userMsgId.isNotEmpty) {
        for (final msg in messages.reversed) {
          if (msg.id == userMsgId) {
            messageContent = msg.content;
            break;
          }
        }
        if (messageContent == null || messageContent.isEmpty) {
          final dbMessages = await chatService.loadChannelMessages(
            currentChannelId!,
            limit: ChatMessageWindow.maxCached,
          );
          for (final msg in dbMessages.reversed) {
            if (msg.id == userMsgId) {
              messageContent = msg.content;
              break;
            }
          }
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
    final windowLimit = messages.isEmpty
        ? ChatMessageWindow.initialLimit
        : messages.length.clamp(
            ChatMessageWindow.initialLimit,
            ChatMessageWindow.maxCached,
          );
    final dbMessages = await chatService.loadChannelMessages(
      currentChannelId!,
      limit: windowLimit,
    );
    if (isGroupMode) {
      messages.clear();
      messageIdMap.clear();
      for (final m in dbMessages) {
        messages.add(m);
        messageIdMap[m.id] = m;
      }
    } else {
      // 流式回合进行中：onStreamChunk 正直接驱动 UI，全量替换会顶掉
      // streaming 占位气泡（以及贴在上面的审批卡）。默认标记待办、回合
      // 结束补 reconcile；但 DB 已出现本回合的回复行（flush 旁路落库而
      // 终态事件丢失）时直接 merge——占位折叠进 flush 行、锚点改指，
      // 回复立即渲染，chunk 继续应用，不再干等终态事件。
      final hasLiveTask = chatService.getActiveTask(currentChannelId!) != null;
      // 回合一开始任务可能尚未登记（登记在发送流程内）——会话「新鲜」
      // 时按活跃处理，不能凭「没有 ActiveTask」把刚开始的回合当僵尸清掉。
      final turnFresh = streaming.beganWithin(const Duration(seconds: 10));
      final deferReload = ChatStreamingSession.shouldDeferReload(
        streamingActive: streaming.isActive,
        hasLiveTask: hasLiveTask || turnFresh,
      );
      if (deferReload &&
          !ChatMessageReconciler.dbHasTurnReply(
            dbMessages: dbMessages,
            turnBeganAtMs: streaming.beganAtMs,
          )) {
        _dmReconcileAfterStreaming = true;
        // 兜底：回合终态事件丢失时 streaming.clear() 永不执行，被 defer 的
        // reload 会永久挂起（UI 卡「等待回复」，重进才恢复）。定时器轮询
        // DB：回复落库即强制 reconcile；回合正常结束仍由终态事件清理。
        _scheduleDmReconcileFallback();
        return;
      }
      if (streaming.isActive) {
        // 提前复位标志：onClear 不再重入 reload（本函数随后自行 merge）。
        _dmReconcileAfterStreaming = false;
        if (!hasLiveTask) {
          // 僵尸会话：无任务、占位已无宿主，直接清掉。
          streaming.clear();
        }
      }
      _mergeDmStreamingPlaceholders(dbMessages);
      rebuildMessageIdMap();
      // 活回合占位被 merge 折叠进 flush 行（id 改名）→ 改指锚点，后续
      // chunk 继续应用。
      if (streaming.isActive) {
        streaming.repointAnchor(messages);
      }
      if (chatService.getActiveTask(currentChannelId!) == null) {
        isProcessing = false;
        acpCancellationToken = null;
      }
    }
    unawaited(_refreshHasMoreOlderMessages());
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
      if (isGroupMode) {
        messages = loadedMessages;
      } else {
        // 与 loadMessages 一致：保留在途流式占位，避免点击引用跳转后
        // 顶掉正在流式的气泡（applyContentTo 找不到目标会静默中断）。
        _mergeDmStreamingPlaceholders(loadedMessages);
      }
      rebuildMessageIdMap();
      streaming.repointAnchor(messages);
      unawaited(_refreshHasMoreOlderMessages());
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
        final bool nextOnline;
        if (agent.isPeerAgent) {
          // peer agent 通过 P2P 隧道访问对端本地 agent，其可用性完全取决于来源
          // 配对设备是否在线，因此在线状态直接跟随该设备的连接状态。
          _agentSourcePeerId = agent.sourcePeerId;
          final peerId = agent.sourcePeerId;
          nextOnline = peerId != null &&
              PeerConnectionManager.instance.getPeerState(peerId) ==
                  PeerConnectionState.connected;
        } else {
          _agentSourcePeerId = null;
          nextOnline = agent.status.isOnline;
        }
        final changed = isAgentOnline != nextOnline || isCheckingHealth;
        isAgentOnline = nextOnline;
        isCheckingHealth = false;
        // 10s 轮询即使状态没变也会 _notify，整页 Markdown 重布局，滑动会突然变钝。
        if (changed) _notify();
      }
    } catch (_) {
      if (isCheckingHealth) {
        isCheckingHealth = false;
        _notify();
      }
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

  /// 回滚 [message] 之后的所有消息。成功返回 `true`；守卫失败或异常返回
  /// `false`（异常时已发出错误 snackbar）。`reEdit` 供调用方在成功后把原文
  /// 预填进输入框（预填本身由调用方完成，这里只负责回滚结果）。
  Future<bool> rollbackMessage(Message message, {bool reEdit = false}) async {
    if (agentId == null || currentChannelId == null) return false;

    try {
      final remoteAgent = await localDatabaseService.getRemoteAgentById(agentId!);
      if (remoteAgent == null) throw Exception('Agent not found');

      await chatService.rollbackFromMessage(
        messageId: message.id,
        channelId: currentChannelId!,
        agent: remoteAgent,
      );

      await loadMessages();
      return true;
    } catch (e) {
      _emit(ShowErrorSnackBarEvent('chat_rollbackFailed:$e'));
      return false;
    }
  }

  // ---- 待发送队列逐条管理 ----

  /// 编辑队列中 [id] 的消息内容。trim 后为空会被拒绝。返回是否命中。
  bool editQueuedMessage(String id, String newContent) {
    final hit = QueuedMessageOps.edit(messageQueue, id, newContent);
    if (hit) _notify();
    return hit;
  }

  /// 删除队列中 [id] 的消息。返回是否命中。
  bool removeQueuedMessage(String id) {
    final hit = QueuedMessageOps.remove(messageQueue, id);
    if (hit) _notify();
    return hit;
  }

  /// 将队列中 [id] 的消息移动 [delta] 位（-1 上移 / +1 下移）。
  /// 越界或 `delta == 0` 时无操作。返回是否命中。
  bool moveQueuedMessage(String id, int delta) {
    final hit = QueuedMessageOps.move(messageQueue, id, delta);
    if (hit) _notify();
    return hit;
  }

  /// 清空当前频道的待发送队列。
  void clearQueuedMessages() {
    if (messageQueue.isEmpty) return;
    messageQueue.clear();
    _notify();
  }

  /// 发送失败后把当前失败消息 + 待发送队列中的消息合并倒回输入框。
  ///
  /// 队列清空（消息不再留在面板），由 [RestoreQueueToComposerEvent] 通知 UI
  /// 填输入框并聚焦。多条以 `\n\n` 分隔保持发送顺序；带附件的消息只倒回
  /// 文本（附件随发送失败丢弃）。
  void _restoreQueueToComposer({String? failedContent}) {
    final queue = messageQueue;
    final parts = <String>[
      if (failedContent != null && failedContent.trim().isNotEmpty)
        failedContent.trim(),
      for (final m in queue)
        if (m.content.trim().isNotEmpty) m.content.trim(),
    ];
    if (parts.isEmpty) return;
    messageQueue.clear();
    _emit(RestoreQueueToComposerEvent(parts.join('\n\n')));
    _notify();
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

    final windowLimit = messages.isEmpty
        ? ChatMessageWindow.initialLimit
        : messages.length.clamp(
            ChatMessageWindow.initialLimit,
            ChatMessageWindow.maxCached,
          );
    final dbMessages = await chatService.loadChannelMessages(
      currentChannelId!,
      limit: windowLimit,
    );
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
      // 流式占位被折叠进 DB 行后 id 已改名：同步改指停止按钮集合与
      // workflow streaming 映射，否则该回合后续 chunk/停止操作都找不到
      // 目标气泡（配合 tracker.applyContent 的兜底自愈）。
      if (groupStreamingMessageIds.contains(entry.key)) {
        groupStreamingMessageIds.remove(entry.key);
        groupStreamingMessageIds.add(entry.value);
      }
      for (final e in _workflowStreamingIds.entries) {
        if (e.value == entry.key) {
          _workflowStreamingIds[e.key] = entry.value;
        }
      }
      // Persist interaction cards folded from temp hosts onto DB rows
      // (orphan peer approvals that raced past agent_done).
      Message? migrated;
      for (final m in result.messages) {
        if (m.id == entry.value) {
          migrated = m;
          break;
        }
      }
      final meta = migrated?.metadata;
      if (meta != null &&
          (meta['action_confirmation'] != null ||
              meta['plan_approval'] != null)) {
        localDatabaseService.updateMessageMetadata(entry.value, meta).ignore();
      }
    }

    messages = result.messages;
    rebuildMessageIdMap();
    unawaited(_refreshHasMoreOlderMessages());
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
    _dmReconcileFallbackTimer?.cancel();

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
