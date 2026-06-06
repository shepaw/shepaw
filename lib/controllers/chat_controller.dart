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
import '../services/workflow/workflow_service.dart';
import '../models/workflow_models.dart';
import '../peer/services/peer_agent_host_service.dart' show isPeerAgentChannel;
import '../peer/services/peer_storage_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_connection.dart' show PeerConnectionEvent;
import '../peer/models/paired_peer.dart' show PeerConnectionState;
import 'chat_events.dart';

// ChatEvent 及其全部子类已拆分到 chat_events.dart，这里重新导出，
// 使现有 `import '../controllers/chat_controller.dart'` 的调用方无需改动。
export 'chat_events.dart';

// 部分低耦合的方法簇（会话管理、群成员管理）以 part + mixin 形式拆到独立文件，
// 与本文件同属一个库，因此可直接访问 _ChatControllerBase 的私有字段与辅助方法。
part 'chat_controller_sessions.dart';
part 'chat_controller_group_members.dart';
part 'chat_controller_interactions.dart';

// ---------------------------------------------------------------------------
// ChatController
// ---------------------------------------------------------------------------

/// ChatController 的状态与核心逻辑基类。
///
/// 持有全部字段、构造与核心方法；低耦合的方法簇通过 part 文件中的 mixin
/// （[_SessionOps]、[_GroupMemberOps]）挂载到具体的 [ChatController] 子类上。
abstract class _ChatControllerBase extends ChangeNotifier with InteractiveStreamingContext {
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

  /// 当前 agent 若来自配对设备（peer agent），记录其来源 peerId。其在线状态跟随
  /// 该设备的 P2P 连接状态，而非普通的健康轮询；为 null 表示非 peer agent。
  String? _agentSourcePeerId;

  /// peer 连接状态变化订阅，用于让 peer agent 的在线状态实时跟随设备上/下线。
  StreamSubscription<PeerConnectionEvent>? _peerConnSub;

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

  /// 当前会话来源设备标签。仅当本机作为 host、当前会话是某配对设备的入站会话
  /// （channelId 形如 `peer__{peerId}__{agentId}`）时为非空，用于在聊天界面标题
  /// 上标注「来自哪个设备」，避免多设备会话名过长被省略时分不清。
  String? sourceDeviceLabel;

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

  /// Cancellation token for the currently executing workflow.
  WorkflowCancellationToken? _workflowCancelToken;

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

  /// Cancel a running workflow execution.
  /// Called when user explicitly stops a workflow from the UI.
  Future<void> cancelRunningWorkflow() async {
    final workflowId = _activeWorkflowId;
    if (workflowId == null) return;

    // Signal cancellation to the execution loop
    _workflowCancelToken?.cancel();
    _workflowCancelToken = null;

    // Complete all pending interaction Completers so blocked steps can exit
    for (final e in pendingGroupInteractions.values) {
      if (!e.result.isCompleted) e.result.complete(null);
    }
    pendingGroupInteractions.clear();

    // Mark workflow as cancelled in DB
    final workflowService = WorkflowService.instance;
    await workflowService.cancelWorkflow(workflowId);

    _activeWorkflowId = null;
    notifyListeners();
  }

  /// Called when user approves a workflow plan — just shows the progress panel.
  /// The actual startWorkflow + execution is handled by handleWorkflowApproval
  /// from the progress panel, or directly when approved via plan_approval card.
  Future<void> _handleWorkflowApproved(String workflowId) async {
    // Only set the active ID to show the panel — do NOT call startWorkflow here.
    // handleWorkflowApproval (triggered from the panel) is the canonical entry
    // point for starting execution. This avoids the double-start race (C2).
    setActiveWorkflowId(workflowId);
  }

  /// Handle workflow approval/rejection from the WorkflowProgressPanel.
  Future<void> handleWorkflowApproval(bool approved, {String? feedback}) async {
    final workflowId = _activeWorkflowId;
    if (workflowId == null || currentChannelId == null) return;

    final workflowService = WorkflowService(db: localDatabaseService);

    if (approved) {
      await workflowService.startWorkflow(workflowId);
      notifyListeners();

      // Create a cancellation token for this workflow execution
      final cancelToken = WorkflowCancellationToken();
      _workflowCancelToken = cancelToken;

      // Auto-execute all stages in the background.
      // processGroupAgent inside executeWorkflowSteps handles message creation
      // and streaming internally. We just reconcile afterwards.
      chatService.executeWorkflowSteps(
        workflowId: workflowId,
        channelId: currentChannelId!,
        userId: getUserId(),
        userName: getUserName(),
        cancelToken: cancelToken,
        onAgentStart: (aid, anm) {
          respondingAgentNames.add(anm);
          _notify();
        },
        onAgentDone: (aid, anm, skipped) {
          respondingAgentNames.remove(anm);
          _notify();
          reconcileGroupMessages();
        },
        onInteractionRequest: (agentId, agentName, interactionType, data) async {
          // During workflow step execution, interactions must block until
          // the user responds. This prevents steps from being marked
          // "completed" before the user fills a form / selects an action.

          // Determine the message ID — the agent's message is already saved
          // to DB by processGroupAgent before this callback fires.
          await reconcileGroupMessages();
          final savedMsgId = data.remove('_savedMessageId') as String?;
          String? sid;
          if (savedMsgId != null && messageIdMap.containsKey(savedMsgId)) {
            sid = savedMsgId;
          }

          // Update message metadata to show the interactive component
          if (sid != null) {
            _updateGroupStreamingMetadata(sid, interactionType, data);
            final existingMeta = Map<String, dynamic>.from(
                messageIdMap[sid]?.metadata ?? {});
            existingMeta[interactionType] = data;
            localDatabaseService
                .updateMessageMetadata(sid, existingMeta)
                .ignore();
          }

          // Create event with a Completer that BLOCKS until user responds
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

          // Block here until the user actually responds (no timeout for workflow steps)
          try {
            final result = await event.result.future.timeout(
              const Duration(minutes: 30),
              onTimeout: () => null,
            );
            return result;
          } finally {
            pendingGroupInteractions.remove(sid ?? agentId);
            _notify();
          }
        },
      );
    } else {
      await workflowService.cancelWorkflow(workflowId);
      _activeWorkflowId = null;
      notifyListeners();

      // M5: Send rejection feedback to Admin so it can re-plan
      if (feedback != null && feedback.isNotEmpty && currentChannelId != null) {
        final feedbackMessage = '用户拒绝了工作流计划并提出修改意见: $feedback';
        try {
          await processGroupMessage(feedbackMessage);
        } catch (e) {
          LoggerService().error('Failed to send workflow rejection feedback', tag: 'ChatController', error: e);
        }
      }
    }
  }

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
    // peer agent 的在线状态需实时跟随来源设备上/下线，不能只靠 10s 轮询。
    _peerConnSub = PeerConnectionManager.instance.events.listen((event) {
      if (_agentSourcePeerId != null && event.peerId == _agentSourcePeerId) {
        refreshAgentStatus();
      }
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
    _peerConnSub?.cancel();
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
      // channel 已落库时按 channel 解析；全新会话（channel 尚未持久化）回退到
      // 构造参数 agentId，确保 peer agent 首次对话也能展示来源设备标签。
      sourceDeviceLabel = channel != null
          ? await _resolveSourceDeviceLabel(channel)
          : await _resolveClientPeerAgentDeviceLabel(null);
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

  /// 解析当前会话的来源设备标签。
  ///
  /// 覆盖两类「来自配对设备」的会话：
  /// - **Host 侧入站会话**（`peer__{peerId}__{agentId}`）：从 channel 成员中取出
  ///   `peer:{peerId}` 成员，按 peerId 查配对设备名；查不到时回退到 channel 名称中
  ///   `← ` 之后的部分。
  /// - **Client 侧访问对端分享的 agent**（普通 `dm_` channel，agent 为 peer 类型）：
  ///   从 agent 成员对应的 [RemoteAgent.sourcePeerId] 实时查配对设备名，回退到
  ///   [RemoteAgent.sourcePeerName] 快照。
  ///
  /// 都解析不到时返回 null。
  Future<String?> _resolveSourceDeviceLabel(Channel channel) async {
    if (isPeerAgentChannel(channel.id)) {
      return _resolveHostInboundDeviceLabel(channel);
    }
    return _resolveClientPeerAgentDeviceLabel(channel);
  }

  /// Host 侧：本机被某配对设备访问时的入站会话来源设备名。
  Future<String?> _resolveHostInboundDeviceLabel(Channel channel) async {
    String? peerId;
    for (final m in channel.members) {
      if (m.id.startsWith('peer:')) {
        peerId = m.id.substring('peer:'.length);
        break;
      }
    }

    final byId = await _peerDeviceNameById(peerId);
    if (byId != null) return byId;

    // 回退：channel 名称形如 `Agent 名 ← 设备名`
    const sep = ' ← ';
    final idx = channel.name.lastIndexOf(sep);
    if (idx >= 0) {
      final label = channel.name.substring(idx + sep.length).trim();
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  /// Client 侧：当前 DM 会话访问的是对端分享的 peer agent 时的来源设备名。
  Future<String?> _resolveClientPeerAgentDeviceLabel(Channel? channel) async {
    // 优先用 channel 中的 agent 成员；取不到时回退到构造参数 agentId。
    String? targetAgentId = agentId;
    final agentMembers =
        channel?.members.where((m) => m.isAgent).toList() ?? const [];
    if (agentMembers.isNotEmpty) {
      targetAgentId = agentMembers.first.id;
    }
    if (targetAgentId == null) return null;

    try {
      final agent = await localDatabaseService.getRemoteAgentById(targetAgentId);
      if (agent == null || !agent.isPeerAgent) return null;

      // 优先用 sourcePeerId 实时查配对设备名（设备改名后能跟随更新）。
      final byId = await _peerDeviceNameById(agent.sourcePeerId);
      if (byId != null) return byId;

      // 回退：agent metadata 中的设备名快照。
      final snapshot = agent.sourcePeerName;
      if (snapshot != null && snapshot.isNotEmpty) return snapshot;
    } catch (_) {}
    return null;
  }

  /// 按 peerId 查配对设备的显示名；查不到或为空时返回 null。
  Future<String?> _peerDeviceNameById(String? peerId) async {
    if (peerId == null || peerId.isEmpty) return null;
    try {
      final peers = await PeerStorageService().loadAllPeers();
      for (final p in peers) {
        if (p.id == peerId && p.deviceName.isNotEmpty) return p.deviceName;
      }
    } catch (_) {}
    return null;
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

      final isLocal = remoteAgent.isLocal;

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
          // Workflow: if this is a plan_approval with a workflow ID, show the progress panel
          if (interactionType == 'plan_approval') {
            final workflowId = data['_workflowId'] as String?;
            if (workflowId != null) {
              setActiveWorkflowId(workflowId);
            }
          }

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

      final isLocal = remoteAgent.isLocal;
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

/// 聊天页面控制器。
///
/// 在 [_ChatControllerBase] 的状态与核心逻辑之上，通过 mixin 组合会话管理
/// （[_SessionOps]）与群成员管理（[_GroupMemberOps]）两个职责模块。
class ChatController extends _ChatControllerBase
    with _SessionOps, _GroupMemberOps, _InteractionOps {
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
