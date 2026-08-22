import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../services/local_user_identity.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../models/pending_attachment.dart';
import '../models/remote_agent.dart';
import '../models/model_routing_config.dart';
import '../services/audio_recording_service.dart';
import '../services/composer_draft_service.dart';
import '../services/local_database_service.dart';
import '../services/group/group_member_session_service.dart';
import '../utils/layout_utils.dart';
import '../widgets/drawer_swipe_detector.dart';
import '../widgets/right_drawer_route.dart';
import '../l10n/app_localizations.dart';
import '../controllers/chat_controller.dart';
import '../controllers/chat_attachment_coordinator.dart';
import '../theme/app_theme.dart';
import '../widgets/chat/chat_app_bar.dart';
import '../models/store_attachment_ref.dart';
import '../widgets/chat/storage_file_picker_screen.dart';
import '../widgets/chat/chat_more_drawer.dart';
import '../widgets/chat/chat_input_area.dart';
import '../widgets/chat/chat_message_list.dart';
import '../widgets/chat/chat_reply_preview.dart';
import '../widgets/chat/session_list_panel.dart';
import '../widgets/chat/group_session_list_panel.dart';
import '../widgets/chat/session_list_header_menu.dart';
import '../widgets/chat/session_search_results.dart';
import '../widgets/chat/session_unread_badge.dart';
import '../widgets/chat/group_members_panel.dart';
import '../widgets/chat/add_group_member_panel.dart';
import '../widgets/avatar_image.dart';
import '../widgets/voice_record_overlay.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';
import 'agent_runtime_context_screen.dart';
import '../services/logger_service.dart';
import '../services/error_handler_service.dart';
import '../services/she_service.dart';
import 'channel_trace_screen.dart';
import 'group_workflow_screen.dart';
import '../widgets/workflow/workflow_progress_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../service_locator.dart' show getIt;

/// User's response to the "sync remote sessions" prompt.
/// Both choices are persisted; the dialog is only shown while undecided.
enum _PeerSyncChoice { sync, disable }

/// 聊天页抽屉打开手势的触发阈值（px）：左滑位移达到该距离才判定为打开
/// 手势，抽屉开始跟随手指。必须明显大于 SelectionArea 的 18px touchSlop，
/// 否则上下滚动时手指带出的轻微横向漂移（旧配置 8px 在 dy/dx<1 的起手
/// 瞬间即接受）会误开抽屉 —— 滚动中 dy 早在 18px 就交给消息列表（见
/// verticalScrollSlop），抽屉根本等不到 8px 阈值以下的机会。
/// 气泡上的左滑也能打开抽屉：气泡文本在空闲时不包 SelectionArea（见
/// message_bubble.dart 的 _wrapWithTextSelection），选区的横向拖拽识别器
/// 不参与竞技场，抽屉以同样 30px 阈值在气泡上起手（与普通区域一致）。
const double _chatDrawerOpenSwipeThreshold = 30;

class ChatScreen extends StatefulWidget {
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final String? channelId;
  final bool embedded;
  final VoidCallback? onClose;
  final void Function(String channelId, {String? highlightMessageId})?
      onSwitchChannel;
  final ValueChanged<String?>? onShowTraces;
  final void Function(String channelId, String channelName)?
      onShowGroupWorkflow;

  /// When set, scroll to and highlight this message after loading.
  final String? highlightMessageId;

  /// When true, show a back arrow in the app bar (e.g. returning to search).
  final bool showBackButton;

  const ChatScreen({
    Key? key,
    this.agentId,
    this.agentName,
    this.agentAvatar,
    this.channelId,
    this.embedded = false,
    this.onClose,
    this.onSwitchChannel,
    this.onShowTraces,
    this.onShowGroupWorkflow,
    this.highlightMessageId,
    this.showBackButton = false,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final ChatController _controller;

  /// 右侧会话抽屉共用的动画控制器：同时驱动抽屉路由（RightDrawerRoute 的
  /// sharedController，不自行销毁）与页面联动平移（RightDrawerLinkedPage），
  /// 保证抽屉与聊天页动画、手势拖动逐帧同源。
  late final AnimationController _drawerController;
  StreamSubscription<ChatEvent>? _eventSubscription;

  /// 断连失败的 peer turn 在重连后的历史 reconcile 通知订阅。
  StreamSubscription<String>? _reconcileSubscription;

  /// True while pulling this synced session's transcript from the remote,
  /// so the app bar can show a "同步远端…" indicator.
  bool _syncingPeerHistory = false;

  // UI-only state (bound to widget tree)
  final _messageController = TextEditingController();
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _textFieldFocusNode = FocusNode();
  final _chatInputKey = GlobalKey<ChatInputAreaState>();

  // Voice recording (UI-bound)
  late AudioRecordingService _audioRecordingService;
  StreamSubscription<RecordingState>? _recordingSubscription;
  bool _isRecording = false;
  bool _isCancelZone = false;
  Duration _recordingElapsed = Duration.zero;
  double _recordingAmplitude = 0.0;

  // Pending attachments (UI-bound)
  List<PendingAttachment> get _pendingAttachments => _pendingQueue.items;
  final PendingAttachmentQueue _pendingQueue = PendingAttachmentQueue();

  // Emoji picker (UI-bound)
  bool _showEmojiPicker = false;

  // Scroll state (UI-bound)
  bool _isUserScrolledUp = false;

  /// True while we drive scroll via jumpTo/scrollTo. Programmatic motion can
  /// emit [UserScrollNotification] and falsely set [_isUserScrolledUp].
  /// Cleared after newest item is visible again (or a hard timeout) — long
  /// lists settle slower than a single frame / short fixed delay.
  bool _isProgrammaticScrolling = false;
  int _programmaticScrollGeneration = 0;
  Timer? _programmaticScrollClearTimer;

  /// After send/reattach, keep following the stream until the user clearly
  /// scrolls away from the newest message. Prevents long-list jumpTo from
  /// freezing UI with a sticky scrolled-up flag.
  bool _liveFollowStreaming = false;
  int _unreadMessageCount = 0;

  /// Unread agent/group messages in sessions other than the one being viewed.
  int _otherSessionsUnreadCount = 0;
  int _trackedMessageCount = 0;

  /// 防止会话抽屉重复打开（会话加载是异步的，连点会叠出两个抽屉）。
  bool _isChatDrawerOpen = false;

  /// 抽屉打开手势（触屏左滑）的实时位移（px，左滑为正），会话加载完成前
  /// 手指继续移动时累计，push 时换算为初始进度。
  double _drawerGestureOpenDx = 0;

  /// 打开手势在会话加载完成前已抬手时记录的速度（px/s）；null 表示手势未结束。
  double? _drawerGestureEndVelocity;

  /// 跟手模式下打开的抽屉句柄；null 表示当前抽屉为按钮打开或未打开。
  RightDrawerHandle? _drawerHandle;

  /// 当前抽屉路由（按钮 / 手势两种打开方式都有）。
  ///
  /// 注意：pop 只会让 `popped` future 完成，路由要等退场动画结束才
  /// dispose。本字段在路由销毁后才清空（见 [_showSessionList]），这样
  /// 退场动画期间再次切换会话（`_openDrawerSession`）仍能拿到
  /// `dismissed`，保证切换前一定等抽屉彻底关闭。
  RightDrawerRoute? _drawerRoute;

  // Pending highlight from search navigation
  String? _pendingHighlightMessageId;

  // Whether She agent needs LLM model configuration
  bool _sheNeedsConfig = false;

  // Whether the current agent's LLM supports audio/voice input
  bool _agentSupportsAudio = false;

  // Whether the current agent supports image input routing
  bool _agentSupportsImage = false;

  /// Last draft key used for migrate-from-agent → channel.
  String? _lastDraftKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _controller = ChatController(
      agentId: widget.agentId,
      initialAgentName: widget.agentName,
      initialAgentAvatar: widget.agentAvatar,
      initialChannelId: widget.channelId,
      embedded: widget.embedded,
      onClose: widget.onClose,
      onSwitchChannel: widget.onSwitchChannel,
      getUserId: () => LocalUserIdentity.id,
      getUserName: () => LocalUserIdentity.displayName,
    );

    _controller.addListener(_onControllerChanged);
    _eventSubscription = _controller.events.listen(_handleControllerEvent);

    _audioRecordingService = AudioRecordingService();
    _recordingSubscription = _audioRecordingService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isRecording = state.isRecording;
          _recordingElapsed = state.elapsed;
          _recordingAmplitude = state.amplitude;
        });
      }
    });

    _restoreComposerDraft();
    _messageController.addListener(_onTextChanged);
    _textFieldFocusNode.addListener(_onFocusChanged);
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    }

    unawaited(_controller.init().then((_) {
      if (!mounted) return;
      _trackedMessageCount = _controller.messages.length;
      _refreshOtherSessionsUnread();
    }));
    _audioRecordingService.requestPermission();
    _pendingHighlightMessageId = widget.highlightMessageId;
    _checkSheNeedsConfig();
    _checkAgentAudioSupport();
    _checkAgentImageSupport();
    _maybeSyncPeerAgent();
    _ensurePeerSlashCommands();
    // 断连期间被判死的 turn，其结果可能仍留在远端 —— 重连后 service 会发
    // reconcile 通知，这里对当前 agent 做一次增量历史同步把结果补回。
    _reconcileSubscription =
        PeerAgentClientService.instance.reconcileRequests.listen((key) {
      unawaited(_onPeerReconcileRequest(key));
    });
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightMessageId != null &&
        widget.highlightMessageId != oldWidget.highlightMessageId) {
      _pendingHighlightMessageId = widget.highlightMessageId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pendingHighlightMessageId == null) return;
        final mid = _pendingHighlightMessageId!;
        _pendingHighlightMessageId = null;
        _scrollToMessage(mid);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    }
    // Capture text before tearing down; publish after this frame so the
    // conversation list can reorder once navigation has settled.
    final draftText = _messageController.text;
    final draftKey = _composerDraftKey();
    final agentId = widget.agentId;
    final groupFamilyId = _composerGroupFamilyId();
    if (draftKey != null) {
      getIt<ComposerDraftService>().setDraft(
        draftKey,
        draftText,
        agentId: agentId,
        groupFamilyId: groupFamilyId,
      );
    }
    final draftService = getIt<ComposerDraftService>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      draftService.publish();
    });

    _eventSubscription?.cancel();
    _reconcileSubscription?.cancel();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _recordingSubscription?.cancel();
    _itemPositionsListener.itemPositions
        .removeListener(_onItemPositionsChanged);
    _programmaticScrollClearTimer?.cancel();
    _audioRecordingService.dispose();
    _messageController.dispose();
    _textFieldFocusNode.dispose();
    // 先停再释放：mixin 的 ticker 在 super.dispose() 里才释放，直接 dispose
    // 仍处于 active 状态的控制器会触发 ticker 断言。
    _drawerController.stop();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.onAppLifecycleChanged(state == AppLifecycleState.resumed);

    // If the app loses focus while recording (e.g. Samsung edge panel, app
    // switch, incoming call), stop the recording so it doesn't run forever.
    if (state != AppLifecycleState.resumed &&
        _audioRecordingService.currentState.isRecording) {
      _audioRecordingService.cancelRecording();
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _maybeMigrateComposerDraftKey();
    final messageCount = _controller.messages.length;
    if (messageCount != _trackedMessageCount) {
      _trackedMessageCount = messageCount;
      unawaited(_refreshOtherSessionsUnread());
    }
    final isStreaming = _controller.streamingMessageId != null ||
        _controller.groupStreamingMessageIds.isNotEmpty;
    if (!isStreaming) {
      _liveFollowStreaming = false;
    } else if (_liveFollowStreaming && _isUserScrolledUp) {
      // Live-follow turn: never let a sticky scrolled-up flag starve rebuilds.
      _clearScrolledUpState(notify: false);
    } else if (_isUserScrolledUp && _isNewestMessageVisible()) {
      _clearScrolledUpState(notify: false);
    }
    // Always rebuild while streaming. Skipping setState when "scrolled up"
    // used to freeze the bubble for the whole turn (especially with long
    // lists where jumpTo falsely sticks the flag). Follow-scroll is gated
    // separately; chunk notifies are already coalesced to one per frame.
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Event handling
  // ---------------------------------------------------------------------------

  void _handleControllerEvent(ChatEvent event) {
    if (!mounted) return;

    switch (event) {
      case ShowSnackBarEvent(:final message):
        _showLocalizedSnackBar(message);
      case ShowErrorSnackBarEvent(:final message):
        _showLocalizedSnackBar(message, isError: true);
      case ShowRetrySnackBarEvent(:final interruptedInfo):
        final l10n = AppLocalizations.of(context);
        showTopToast(
          context,
          l10n.chat_connectionInterrupted,
          icon: Icons.wifi_off,
          color: Colors.orange,
          duration: const Duration(seconds: 8),
          actionLabel: l10n.chat_connectionInterruptedRetry,
          onAction: () => _controller.retryLastUserMessage(interruptedInfo),
        );
      case ShowReconnectingSnackBarEvent(:final attempt, :final total):
        final l10n = AppLocalizations.of(context);
        // 持久提示——每次尝试前重复触发会覆盖旧 toast（_TopToastManager 内部会先
        // dismiss 当前实例再插入新实例）。duration 设得足够长以覆盖完整重试周期；
        // 结束时由 HideReconnectingSnackBarEvent 主动 hideTopToast。
        showTopToast(
          context,
          l10n.chat_reconnectingAttempt(attempt, total),
          icon: Icons.wifi_tethering,
          color: Colors.orange,
          duration: const Duration(seconds: 30),
        );
      case HideReconnectingSnackBarEvent():
        hideTopToast();
      case NavigateToSessionEvent(
          :final channelId,
          :final agentId,
          :final agentName,
          :final agentAvatar,
          :final embedded
        ):
        // 新建/切换会话（createNewSession 等）会导航替换当前页：必须先关抽屉
        // 并等它彻底销毁，否则共享动画控制器随本页 dispose，抽屉冻结在屏幕
        // 上（见 _closeDrawerAndWait 注释）。_handleNavigateToSession 内部
        // 先 await 再导航，这里异步调度。
        unawaited(_handleNavigateToSession(
          channelId: channelId,
          agentId: agentId,
          agentName: agentName,
          agentAvatar: agentAvatar,
          embedded: embedded,
        ));
      case ShowLoadingOverlayEvent(:final message):
        _showClearingOverlay(message);
      case DismissOverlayEvent():
        Navigator.of(context).pop();
      case RequestScrollToBottomEvent(:final force):
        if (_pendingHighlightMessageId != null) {
          final mid = _pendingHighlightMessageId!;
          _pendingHighlightMessageId = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToMessage(mid);
          });
        } else {
          // Force (new send / reattach) always resumes live follow — otherwise a
          // stuck scrolled-up flag from a prior turn keeps skipping rebuilds /
          // follow-scrolls (worse with long message lists).
          if (force) {
            _liveFollowStreaming = true;
            if (_isUserScrolledUp) {
              _clearScrolledUpState(notify: false);
            }
          }
          _scrollToBottom(force: force);
        }
      case ShowHistoryRequestDialogEvent(:final reason, :final result):
        _showHistoryRequestDialog(reason).then((approved) {
          if (!result.isCompleted) result.complete(approved);
        });
      case ShowOsToolConfirmationEvent(
          :final toolName,
          :final args,
          :final risk,
          :final result
        ):
        _showOsToolConfirmation(toolName, args, risk).then((approved) {
          if (!result.isCompleted) result.complete(approved);
        });
      case CloseScreenEvent():
        if (widget.embedded) {
          widget.onClose?.call();
        } else {
          Navigator.pop(context);
        }
      case AgentInfoUpdatedEvent():
        // Already handled via notifyListeners
        break;
      case GroupInteractionRequestEvent():
        // User is already in this chat — the approval/interaction card is in
        // the message list. Only scroll into view; do not also toast.
        _scrollToBottom(force: true);
    }
  }

  void _showLocalizedSnackBar(String key, {bool isError = false}) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final text = _resolveSnackBarMessage(l10n, key);
    showTopToast(
      context,
      text,
      icon: isError ? Icons.error_outline : Icons.info_outline,
      color: isError ? Colors.red.shade400 : Colors.blueGrey,
    );
  }

  /// 将 controller 发出的 SnackBar key 解析为本地化字符串。
  /// 支持格式：
  /// - 纯 key：'chat_sessionCleared' → l10n.chat_sessionCleared
  /// - 带参数 key：'chat_batchDeleteSuccess:3' → l10n.chat_batchDeleteSuccess(3)
  /// - 未匹配的 key → 按冒号分割取后半部分（兼容错误信息透传）
  String _resolveSnackBarMessage(AppLocalizations l10n, String key) {
    // 解析 key 和参数
    final colonIdx = key.indexOf(':');
    final name = colonIdx >= 0 ? key.substring(0, colonIdx) : key;
    final param = colonIdx >= 0 ? key.substring(colonIdx + 1) : '';

    switch (name) {
      case 'chat_sessionCleared':
        return l10n.chat_sessionCleared;
      case 'chat_allSessionsCleared':
        return l10n.chat_allSessionsCleared;
      case 'chat_groupSessionCleared':
        return l10n.chat_groupSessionCleared;
      case 'chat_allGroupSessionsCleared':
        return l10n.chat_allGroupSessionsCleared;
      case 'chat_noAgentSelected':
        return l10n.chat_noAgentSelected;
      case 'chat_groupBoundInputDisabled':
        return l10n.chat_groupBoundInputDisabled;
      case 'chat_batchDeleteSuccess':
        return l10n.chat_batchDeleteSuccess(int.tryParse(param) ?? 0);
      case 'chat_clearSessionFailed':
        return l10n.chat_clearSessionFailed(param);
      case 'chat_loadFailed':
        return l10n.chat_loadFailed(param);
      case 'chat_searchError':
        return l10n.chat_searchError(param);
      case 'chat_rollbackFailed':
        return l10n.chat_rollbackFailed(param);
      case 'chat_groupChatError':
        return l10n.chat_groupChatError(param);
      case 'chat_fileMessageFailed':
        return l10n.chat_fileMessageFailed(param);
      case 'chat_reconnectFailed':
        return l10n.chat_reconnectFailed;
      case 'chat_responseError':
        return l10n.chat_responseError(param);
      case 'chat_peerTurnStillRunning':
        return l10n.chat_peerTurnStillRunning;
      case 'chat_historyLoadFailed':
        return l10n.chat_historyLoadFailed(param);
      case 'chat_modalityNotSupported':
        switch (param) {
          case 'audio':
            return l10n.chat_modalityNotSupported_audio;
          case 'video':
            return l10n.chat_modalityNotSupported_video;
          case 'image':
          default:
            return l10n.chat_modalityNotSupported_image;
        }
      default:
        // 未知 key：若含冒号则取后半部分（错误详情），否则原样返回
        return colonIdx >= 0 ? param : key;
    }
  }

  // ---------------------------------------------------------------------------
  // Text / scroll / focus callbacks
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    // Mention detection is handled inside ChatInputArea
    _persistComposerDraft();
  }

  String? _composerDraftKey() {
    return ComposerDraftService.keyFor(
      channelId: _controller.currentChannelId ?? widget.channelId,
      agentId: widget.agentId,
    );
  }

  String? _composerGroupFamilyId() {
    return _controller.groupChannel?.groupFamilyId;
  }

  void _restoreComposerDraft() {
    final key = _composerDraftKey();
    if (key == null) return;
    _lastDraftKey = key;
    final service = getIt<ComposerDraftService>();
    var draft = service.getDraft(key);
    // Channel may not have been resolved on the previous leave; fall back to
    // the agent-scoped draft and migrate it forward.
    final agentId = widget.agentId;
    if (draft.isEmpty &&
        agentId != null &&
        agentId.isNotEmpty &&
        key != ComposerDraftService.agentListKey(agentId)) {
      final agentKey = ComposerDraftService.agentListKey(agentId);
      draft = service.getDraft(agentKey);
      if (draft.isNotEmpty) {
        service.migrate(fromKey: agentKey, toKey: key);
        // Keep list alias so the conversation list can still find it.
        service.setDraft(
          key,
          draft,
          agentId: agentId,
          groupFamilyId: _composerGroupFamilyId(),
        );
      }
    }
    if (draft.isEmpty) return;
    _messageController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
  }

  void _persistComposerDraft({bool notify = false}) {
    final key = _composerDraftKey();
    if (key == null) return;
    _lastDraftKey = key;
    getIt<ComposerDraftService>().setDraft(
      key,
      _messageController.text,
      agentId: widget.agentId,
      groupFamilyId: _composerGroupFamilyId(),
      notify: notify,
    );
  }

  void _clearComposerDraft() {
    final key = _composerDraftKey();
    if (key == null) return;
    getIt<ComposerDraftService>().clearDraft(
      key,
      agentId: widget.agentId,
      groupFamilyId: _composerGroupFamilyId(),
    );
  }

  /// When channelId resolves after load, migrate drafts and write list aliases.
  void _maybeMigrateComposerDraftKey() {
    final channelId = _controller.currentChannelId;
    if (channelId == null || channelId.isEmpty) return;

    final service = getIt<ComposerDraftService>();
    final agentId = widget.agentId;
    final groupFamilyId = _composerGroupFamilyId();

    if (_lastDraftKey != channelId) {
      if (agentId != null && agentId.isNotEmpty) {
        service.migrate(
          fromKey: ComposerDraftService.agentListKey(agentId),
          toKey: channelId,
        );
      }
      if (_messageController.text.isEmpty) {
        final draft = service.getDraft(channelId);
        if (draft.isNotEmpty) {
          _messageController.value = TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
          );
        }
      }
      _lastDraftKey = channelId;
      if (_messageController.text.trimRight().isNotEmpty) {
        _persistComposerDraft();
      }
      return;
    }

    // Channel already known — sync group list alias once it becomes available.
    if (groupFamilyId != null &&
        _messageController.text.trimRight().isNotEmpty &&
        !service.hasDraft(ComposerDraftService.groupListKey(groupFamilyId))) {
      _persistComposerDraft();
    }
  }

  void _onFocusChanged() {
    if (_textFieldFocusNode.hasFocus && _showEmojiPicker) {
      setState(() {
        _showEmojiPicker = false;
      });
    }
  }

  /// Reverse list: index 0 is the newest message at the visual bottom.
  bool _isNewestMessageVisible() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    return positions.any((p) => p.index == 0);
  }

  void _clearScrolledUpState({bool notify = true}) {
    _isUserScrolledUp = false;
    _unreadMessageCount = 0;
    _controller.isUserScrolledUp = false;
    if (notify && mounted) setState(() {});
  }

  void _beginProgrammaticScroll() {
    _isProgrammaticScrolling = true;
    final generation = ++_programmaticScrollGeneration;
    _programmaticScrollClearTimer?.cancel();

    // Long lists may take several frames before jumpTo lands and before
    // ItemPositionsListener reports index 0. Keep the guard until then,
    // with a hard ceiling so a failed jump cannot stick forever.
    final startedAt = DateTime.now();
    const maxWait = Duration(milliseconds: 800);

    void settle() {
      if (!mounted || generation != _programmaticScrollGeneration) return;
      if (_isNewestMessageVisible() ||
          DateTime.now().difference(startedAt) >= maxWait) {
        _isProgrammaticScrolling = false;
        return;
      }
      _programmaticScrollClearTimer =
          Timer(const Duration(milliseconds: 50), settle);
    }

    _programmaticScrollClearTimer =
        Timer(const Duration(milliseconds: 50), settle);
  }

  void _onItemPositionsChanged() {
    if (!mounted || _isProgrammaticScrolling) return;
    if (_isUserScrolledUp && _isNewestMessageVisible()) {
      _clearScrolledUpState();
      _controller.markMessagesAsReadIfAtBottom();
      unawaited(_refreshOtherSessionsUnread());
    }
    unawaited(_maybeLoadOlderMessages());
  }

  /// When the user scrolls near the oldest loaded edge, prepend the next page
  /// and re-anchor so the viewport does not jump.
  Future<void> _maybeLoadOlderMessages() async {
    final c = _controller;
    if (!c.hasMoreOlderMessages || c.isLoadingOlderMessages) return;
    if (c.messages.isEmpty) return;
    // Stay out of the way of live follow / programmatic jumpTo.
    if (_liveFollowStreaming || _isProgrammaticScrolling) return;

    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    final itemCount = c.messages.length;
    var maxIndex = 0;
    ItemPosition? topMost;
    for (final p in positions) {
      if (p.index >= maxIndex) {
        maxIndex = p.index;
        topMost = p;
      }
    }
    // Reverse list: high index == older. Trigger when within 4 of the oldest.
    if (maxIndex < itemCount - 4) return;
    if (topMost == null) return;

    final anchorIndex = topMost.index;
    final anchorAlignment = topMost.itemLeadingEdge;

    final added = await c.loadOlderMessages();
    if (!mounted || added <= 0) return;
    if (!_itemScrollController.isAttached) return;

    _beginProgrammaticScroll();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      final newIndex = anchorIndex + added;
      if (newIndex < 0 || newIndex >= _controller.messages.length) return;
      _itemScrollController.jumpTo(
        index: newIndex,
        alignment: anchorAlignment,
      );
    });
  }

  void _onUserScroll(ScrollDirection direction) {
    // Ignore idle and programmatic jumpTo/scrollTo — those can report
    // ScrollDirection.forward and freeze streaming UI updates.
    if (_isProgrammaticScrolling || direction == ScrollDirection.idle) {
      return;
    }
    // In a reverse list, ScrollDirection.forward means scrolling toward older
    // messages (upward visually), and ScrollDirection.reverse means scrolling
    // toward newer messages (downward visually).
    if (direction == ScrollDirection.forward) {
      // Direction alone is not enough: programmatic settles can look like
      // forward while index 0 is still on screen. Long lists also leave a
      // window where positions are stale and index 0 is briefly unreported.
      if (_isNewestMessageVisible()) return;
      // Intentional leave-bottom: stop live follow for this turn.
      _liveFollowStreaming = false;
      if (!_isUserScrolledUp) {
        // Update the flag synchronously before setState so that
        // _onControllerChanged can read the correct value immediately in the
        // same frame.
        _isUserScrolledUp = true;
        _controller.isUserScrolledUp = true;
        setState(() {});
      }
    } else if (direction == ScrollDirection.reverse) {
      // User is scrolling toward the bottom — handled in _onScrollEnd /
      // item position listener.
    }
  }

  void _onScrollEnd(ScrollMetrics metrics) {
    // When the user finishes scrolling and the list is at the very bottom
    // (atEdge && pixels == 0 in a reverse list), clear the scrolled-up state.
    // minScrollExtent == 0 corresponds to the bottom in a reverse list.
    if (metrics.atEdge && metrics.pixels == metrics.minScrollExtent) {
      if (_isUserScrolledUp) {
        _clearScrolledUpState();
        _controller.markMessagesAsReadIfAtBottom();
        unawaited(_refreshOtherSessionsUnread());
      }
    }
  }

  void _scrollToBottom({bool force = false, bool isNewMessage = false}) {
    if (_controller.messages.isEmpty) return;
    if (!force && _isUserScrolledUp && !_liveFollowStreaming) {
      if (isNewMessage) {
        setState(() {
          _unreadMessageCount++;
        });
      }
      return;
    }
    if (isNewMessage) {
      _controller.markMessagesAsReadIfAtBottom();
    }
    // In reverse mode, index 0 is the newest (bottom) message.
    // During streaming, jump instantly: a 300ms scrollTo per chunk races with
    // UserScrollNotification and can stick [_isUserScrolledUp], freezing UI.
    final streamingFollow = _liveFollowStreaming ||
        _controller.streamingMessageId != null ||
        _controller.groupStreamingMessageIds.isNotEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.messages.isEmpty) return;
      if (!_itemScrollController.isAttached) return;
      _beginProgrammaticScroll();
      if (force || streamingFollow) {
        _itemScrollController.jumpTo(index: 0, alignment: 0.0);
      } else {
        _itemScrollController
            .scrollTo(
          index: 0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        )
            .whenComplete(() {
          if (!mounted) return;
          // Extend guard past animation so trailing notifications are ignored.
          _beginProgrammaticScroll();
        });
      }
    });
  }

  Future<void> _refreshOtherSessionsUnread() async {
    final channelId = _controller.currentChannelId;
    if (channelId == null) {
      if (_otherSessionsUnreadCount != 0 && mounted) {
        setState(() => _otherSessionsUnreadCount = 0);
      }
      return;
    }

    var count = 0;
    try {
      if (_controller.isGroupMode) {
        final group = _controller.groupChannel;
        if (group != null) {
          count = await _controller.localDatabaseService
              .getUnreadCountForGroupFamilyExcludingChannel(
            group.groupFamilyId,
            channelId,
          );
        }
      } else if (widget.agentId != null) {
        count = await _controller.localDatabaseService
            .getUnreadCountForAgentExcludingChannel(
          widget.agentId!,
          channelId,
        );
      }
    } catch (_) {}

    if (!mounted || count == _otherSessionsUnreadCount) return;
    setState(() => _otherSessionsUnreadCount = count);
  }

  void _jumpToBottom() {
    _clearScrolledUpState();
    _controller.markMessagesAsReadIfAtBottom();
    unawaited(_refreshOtherSessionsUnread());
    if (_controller.messages.isNotEmpty && _itemScrollController.isAttached) {
      // In reverse mode, index 0 is the newest (bottom) message.
      _beginProgrammaticScroll();
      _itemScrollController.jumpTo(index: 0, alignment: 0.0);
    }
  }

  Future<void> _scrollToMessage(String messageId) async {
    final loaded = await _controller.ensureMessageLoaded(messageId);
    if (!loaded || !mounted) return;

    final idx = _controller.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    setState(() {});

    // Convert chronological index to reversed index.
    final reversedIdx = _controller.messages.length - 1 - idx;
    await _scrollToReversedIndex(reversedIdx);
    if (!mounted) return;

    setState(() {
      _controller.highlightedMessageId = messageId;
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _controller.highlightedMessageId = null;
        });
      }
    });
  }

  Future<void> _scrollToReversedIndex(int reversedIdx) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!mounted) return;
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (!_itemScrollController.isAttached) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      try {
        await _itemScrollController.scrollTo(
          index: reversedIdx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
        return;
      } catch (_) {
        await WidgetsBinding.instance.endOfFrame;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Emoji
  // ---------------------------------------------------------------------------

  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() {
        _showEmojiPicker = false;
      });
      _textFieldFocusNode.requestFocus();
    } else {
      _textFieldFocusNode.unfocus();
      setState(() {
        _showEmojiPicker = true;
      });
    }
  }

  void _onEmojiSelected(Category? category, Emoji emoji) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final cursorPos = selection.baseOffset;
    if (cursorPos < 0) {
      _messageController.text = text + emoji.emoji;
      _messageController.selection =
          TextSelection.collapsed(offset: _messageController.text.length);
    } else {
      final newText = text.substring(0, cursorPos) +
          emoji.emoji +
          text.substring(cursorPos);
      _messageController.text = newText;
      _messageController.selection =
          TextSelection.collapsed(offset: cursorPos + emoji.emoji.length);
    }
  }

  void _onBackspacePressed() {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final cursorPos = selection.baseOffset;
    if (cursorPos > 0 && text.isNotEmpty) {
      final newText =
          text.substring(0, cursorPos - 1) + text.substring(cursorPos);
      _messageController.text = newText;
      _messageController.selection =
          TextSelection.collapsed(offset: cursorPos - 1);
    }
  }

  // ---------------------------------------------------------------------------
  // Clipboard paste (desktop)
  // ---------------------------------------------------------------------------

  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_textFieldFocusNode.hasFocus) return false;
    // Paste is handled via PasteTextIntent in ChatInputArea (Actions widget).
    // Do not handle it here to avoid double invocation.
    return false;
  }

  Future<bool> _handleDesktopPaste() async {
    try {
      // First, check for files (e.g. from Finder copy).
      // Files take priority because Finder also puts a thumbnail image on the
      // clipboard alongside the file path, which would cause the image branch
      // to fire incorrectly if we checked images first.
      final pastedFiles = await Pasteboard.files();
      if (pastedFiles.isNotEmpty) {
        for (final filePath in pastedFiles) {
          final file = File(filePath);
          if (await file.exists()) {
            await _addPendingAttachment(file, isFromClipboard: false);
          }
        }
        return true;
      }
      // No files — try image bytes (e.g. screenshot or copy image from browser)
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File(
            '${tempDir.path}/paste_${DateTime.now().millisecondsSinceEpoch}.png');
        await tempFile.writeAsBytes(imageBytes);
        await _addPendingAttachment(tempFile, isFromClipboard: true);
        return true;
      }
    } catch (e) {
      LoggerService()
          .error('Error handling clipboard paste', tag: 'ChatScreen', error: e);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Attachments
  // ---------------------------------------------------------------------------

  Future<void> _addPendingAttachment(File file,
      {bool isFromClipboard = false}) async {
    if (_pendingQueue.isFull) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context)
              .chat_maxAttachments(_pendingQueue.maxItems),
          icon: Icons.attachment,
          color: Colors.orange,
        );
      }
      return;
    }
    try {
      final added = await _pendingQueue.addFromFile(
        file,
        isFromClipboard: isFromClipboard,
      );
      if (added && mounted) {
        setState(() {});
      }
    } catch (e) {
      LoggerService()
          .error('Error staging attachment', tag: 'ChatScreen', error: e);
    }
  }

  void _removePendingAttachment(PendingAttachment att) {
    setState(() {
      _pendingQueue.remove(att);
    });
  }

  void _showAttachmentOptions() {
    LoggerService().debug(
        '_showAttachmentOptions called, isDesktop=${LayoutUtils.isDesktopLayout(context)}',
        tag: 'ChatScreen');
    // Desktop uses a floating popover anchored to the attachment button
    // inside ChatInputArea (same interaction as emoji). This path is for
    // mobile bottom sheet only.
    final l10n = AppLocalizations.of(context);
    LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(l10n.chat_photoLibrary),
            onTap: () {
              Navigator.pop(context);
              _pickAndStageImage();
            },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: Text(l10n.chat_camera),
            onTap: () {
              Navigator.pop(context);
              _pickAndStageImage();
            },
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: Text(l10n.chat_file),
            onTap: () {
              Navigator.pop(context);
              _pickAndStageFile();
            },
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(l10n.chat_storageBag),
            onTap: () {
              Navigator.pop(context);
              _pickFromStorageBag();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickFromStorageBag() async {
    final remaining = _pendingQueue.maxItems - _pendingQueue.length;
    if (remaining <= 0) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context)
              .chat_maxAttachments(_pendingQueue.maxItems),
          icon: Icons.attachment,
          color: Colors.orange,
        );
      }
      return;
    }
    try {
      final refs = await Navigator.push<List<StoreAttachmentRef>>(
        context,
        MaterialPageRoute(
          builder: (_) => StorageFilePickerScreen(maxSelection: remaining),
        ),
      );
      if (refs == null || refs.isEmpty) return;
      for (final ref in refs) {
        if (_pendingQueue.isFull) break;
        final added = await _pendingQueue.addFromStoreRef(ref);
        if (added && mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      LoggerService()
          .error('_pickFromStorageBag error', tag: 'ChatScreen', error: e);
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_sendFileError('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  Future<void> _pickAndStageFile() async {
    LoggerService().debug('_pickAndStageFile called', tag: 'ChatScreen');
    try {
      final file = await _controller.attachmentService.pickFile();
      LoggerService().debug('pickFile returned: $file', tag: 'ChatScreen');
      if (file == null) return;
      await _addPendingAttachment(file);
    } catch (e) {
      LoggerService()
          .error('_pickAndStageFile error', tag: 'ChatScreen', error: e);
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_sendFileError('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  Future<void> _pickAndStageImage() async {
    if (widget.agentId != null && !_agentSupportsImage) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_modalityNotSupported_image,
          icon: Icons.image_not_supported_outlined,
          color: Colors.orange,
        );
      }
      return;
    }
    try {
      final image = await _controller.attachmentService.pickImage();
      if (image == null) return;
      await _addPendingAttachment(image);
    } catch (e) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_sendImageError('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Voice recording
  // ---------------------------------------------------------------------------

  Future<void> _sendVoiceMessage() async {
    if (widget.agentId != null && !_agentSupportsAudio) {
      showTopToast(
        context,
        AppLocalizations.of(context).chat_modalityNotSupported_audio,
        icon: Icons.mic_off,
        color: Colors.orange,
      );
      return;
    }

    final result = await _audioRecordingService.stopRecording();
    if (result == null) return;

    if (result.durationMs < 1000) {
      showTopToast(
        context,
        AppLocalizations.of(context).chat_voiceTooShort,
        icon: Icons.mic_off,
        color: Colors.orange,
      );
      try {
        await File(result.filePath).delete();
      } catch (_) {}
      return;
    }

    final userId = _controller.getUserId();
    final userName = _controller.getUserName();

    final message = await _controller.attachmentService.saveVoiceMessage(
      filePath: result.filePath,
      durationMs: result.durationMs,
      waveform: result.waveform,
      channelId: _controller.currentChannelId ?? '',
      userId: userId,
      userName: userName,
      agentId: widget.agentId ?? '',
      channelType: _controller.isGroupMode ? 'group' : null,
      parentGroupId: _controller.isGroupMode
          ? (_controller.groupChannel?.groupFamilyId ??
              _controller.currentChannelId)
          : null,
    );

    if (message != null) {
      _controller.addLocalMessage(message);
      _scrollToBottom(force: true);
      _controller.sendAttachmentToAgent(message);
    }
  }

  // ---------------------------------------------------------------------------
  // Send message
  // ---------------------------------------------------------------------------

  void _sendMessage() {
    final content = _messageController.text.trim();
    final mentions = _chatInputKey.currentState?.currentMentions ?? const [];
    _controller.sendMessage(
      content: content,
      pendingAttachments: _pendingAttachments,
      clearMessageController: () {
        _messageController.clear();
        _clearComposerDraft();
        setState(() {
          _pendingQueue.clear();
        });
      },
      replyToId: _controller.replyingToMessage?.id,
      mentions: mentions,
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  Future<void> _navigateToAgentDetail() async {
    if (widget.agentId == null) return;
    await _navigateToAgentDetailById(widget.agentId!);
  }

  /// 直接以编辑模式打开 Agent 详情页，无需先进入详情再点击编辑
  Future<void> _navigateToAgentDetailForEdit() async {
    if (widget.agentId == null) return;
    final remoteAgent = await _controller.localDatabaseService
        .getRemoteAgentById(widget.agentId!);
    if (remoteAgent != null && mounted) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RemoteAgentDetailScreen(
            agent: remoteAgent,
            initialEditMode: true,
          ),
        ),
      );
      if (result == 'deleted' && mounted) {
        if (widget.embedded) {
          widget.onClose?.call();
        } else {
          Navigator.pop(context);
        }
      } else if (mounted) {
        final updated = await _controller.localDatabaseService
            .getRemoteAgentById(widget.agentId!);
        if (updated != null) {
          _controller.updateAgentInfo(updated.name, updated.avatar);
        }
        _checkAgentAudioSupport();
        _checkAgentImageSupport();
      }
    }
  }

  Future<void> _navigateToAgentDetailById(String agentId) async {
    final remoteAgent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (remoteAgent != null && mounted) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RemoteAgentDetailScreen(agent: remoteAgent),
        ),
      );
      if (result == 'deleted' && mounted) {
        if (_controller.isGroupMode) {
          await _controller.refreshGroupMembers();
        } else {
          if (widget.embedded) {
            widget.onClose?.call();
          } else {
            Navigator.pop(context);
          }
        }
      } else if (mounted) {
        final updated =
            await _controller.localDatabaseService.getRemoteAgentById(agentId);
        if (updated != null) {
          _controller.updateAgentInfo(updated.name, updated.avatar);
        }
        if (agentId == widget.agentId) {
          _checkAgentAudioSupport();
          _checkAgentImageSupport();
        }
      }
    }
  }

  Future<void> _navigateToGroupDetail() async {
    final channel = _controller.groupChannel;
    if (channel == null) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupDetailScreen(channel: channel),
      ),
    );
    if (result == true && mounted) {
      // Group was deleted
      if (widget.embedded) {
        widget.onClose?.call();
      } else {
        Navigator.pop(context);
      }
    }
  }

  Future<void> _navigateToStorageSpace() async {
    final c = _controller;
    if (c.isGroupMode) {
      final channel = c.groupChannel;
      if (channel == null) return;
      final ownerId = channel.parentGroupId?.isNotEmpty == true
          ? channel.parentGroupId!
          : channel.id;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AgentRuntimeContextScreen(
            ownerId: ownerId,
            displayName: channel.name,
          ),
        ),
      );
      return;
    }

    final agentId = widget.agentId;
    if (agentId == null) return;
    final remoteAgent =
        await c.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentRuntimeContextScreen(
          ownerId: agentId,
          displayName: c.agentName ?? remoteAgent?.name ?? agentId,
          agent: remoteAgent,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Session list
  // ---------------------------------------------------------------------------

  // ── 抽屉打开手势（触屏左滑，跟手模式）──
  // 打开手势与抽屉内右滑关闭手势共用同一个 RightDrawerHandle：加载会话
  // 期间手指继续移动的位移先累计，push 后直接驱动抽屉进度。

  void _onOpenGestureStart(double openDx) {
    _drawerGestureOpenDx = openDx;
    _drawerGestureEndVelocity = null;
    _startOpenDrawer(gestureDx: openDx);
  }

  void _onOpenGestureUpdate(double openDx) {
    _drawerGestureOpenDx = openDx;
    final handle = _drawerHandle;
    if (handle != null) {
      handle.setProgress(openDx / handle.width);
    }
  }

  void _onOpenGestureEnd(double velocityDx, double openDx) {
    _drawerGestureOpenDx = openDx;
    final handle = _drawerHandle;
    if (handle != null) {
      handle.settle(velocityDx: velocityDx, openDx: openDx);
    } else {
      // 会话还在加载中：记下速度，push 后由加载流程补一次 settle
      // （openDx 已累计在 _drawerGestureOpenDx）。
      _drawerGestureEndVelocity = velocityDx;
    }
  }

  Future<void> _startOpenDrawer({required double gestureDx}) async {
    if (_controller.isGroupMode) {
      await _showGroupSessionList(gestureDx: gestureDx);
    } else {
      await _showSessionList(gestureDx: gestureDx);
    }
  }

  void _showChannelTraces() {
    final channelId = _controller.currentChannelId;
    if (widget.onShowTraces != null) {
      widget.onShowTraces!(channelId);
      return;
    }
    Navigator.of(context, rootNavigator: widget.embedded).push(
      MaterialPageRoute(
        builder: (_) => ChannelTraceScreen(
          channelId: channelId,
          channelName: widget.agentName,
        ),
      ),
    );
  }

  void _showGroupWorkflow() {
    final channelId = _controller.currentChannelId;
    if (channelId == null) return;
    final l10n = AppLocalizations.of(context);
    final c = _controller;
    final channelName = c.groupChannel?.name ??
        (SheService.isSheIdentity(c.agentId)
            ? SheService.resolveDisplayName(c.agentName, l10n.she_name)
            : (c.agentName ?? ''));
    if (widget.onShowGroupWorkflow != null) {
      widget.onShowGroupWorkflow!(channelId, channelName);
      return;
    }
    Navigator.of(context, rootNavigator: widget.embedded).push(
      MaterialPageRoute(
        builder: (_) => GroupWorkflowScreen(
          channelId: channelId,
          channelName: channelName,
        ),
      ),
    );
  }

  Future<void> _showSessionList({double? gestureDx}) async {
    if (widget.agentId == null) return;
    final gestureMode = gestureDx != null;
    if (_isChatDrawerOpen) return;
    _isChatDrawerOpen = true;
    try {
      final sessions = await _sortSessionsByLatestMessage(
        await _controller.chatService
            .getAgentSessions(agentId: widget.agentId!),
      );
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      final c = _controller;
      final refreshTick = ValueNotifier<int>(0);
      final selectionModeRequest = ValueNotifier<int>(0);

      final drawer = ChatMoreDrawer(
        header: _buildDmDrawerHeader(l10n),
        headerOnTap: _navigateToAgentDetail,
        headerTrailingIcon: Icons.edit_outlined,
        headerTrailingTooltip: l10n.chat_editAgent,
        onHeaderTrailing: _navigateToAgentDetailForEdit,
        searchHint: l10n.chat_searchSessions,
        bodyBuilder: (context, query) {
          if (query.trim().isNotEmpty) {
            return SessionSearchResults(
              query: query.trim(),
              sessions: sessions,
              searchService: c.searchService,
              onSwitchSession: _openDrawerSession,
              onLocateMessage: _locateSearchMessage,
            );
          }
          return SessionListPanel(
            sessions: sessions,
            currentChannelId: c.currentChannelId,
            controller: c,
            onNewSession: () => c.createNewSession(),
            onSwitchSession: _openDrawerSession,
            onBatchDelete: (ids) => c.batchDeleteSessions(ids, isGroup: false),
            listRefreshTick: refreshTick,
            selectionModeRequest: selectionModeRequest,
            // 「更多」按钮放「新建会话」行右侧，搜索栏只保留输入。
            moreButton: SessionListHeaderMoreButton(
              sessions: sessions,
              databaseService: c.localDatabaseService,
              refreshTick: refreshTick,
              onMarkAll: () => _markAllDrawerSessionsRead(sessions, refreshTick),
              onShowTraces: () {
                Navigator.pop(context);
                _showChannelTraces();
              },
              onResetSession: () {
                Navigator.pop(context);
                _messageController.text = '/reset';
                _sendMessage();
              },
              onEnterSelectionMode:
                  sessions.length > 1 ? () => selectionModeRequest.value++ : null,
            ),
          );
        },
        footerActions: [
          ChatDrawerAction(
            icon: Icons.inventory_2_outlined,
            label: l10n.chat_storageSpace,
            onTap: _navigateToStorageSpace,
          ),
          if (c.dmWorkflowEnabled)
            ChatDrawerAction(
              icon: Icons.account_tree_outlined,
              label: l10n.chat_workflow,
              onTap: _showGroupWorkflow,
            ),
        ],
      );

      final width = _chatDrawerWidth(context);
      final handle = gestureMode
          ? RightDrawerHandle(
              width: width, openThreshold: _chatDrawerOpenSwipeThreshold)
          : null;
      _drawerHandle = handle;
      final route = LayoutUtils.showRightDrawer(
        context: context,
        builder: (_) => drawer,
        width: width,
        handle: handle,
        initialProgress: gestureMode
            ? (_drawerGestureOpenDx / width).clamp(0.0, 1.0)
            : 0,
        sharedController: _drawerController,
      );
      // 路由销毁（退场动画结束）后再清引用：pop 只完成 popped future，
      // 退场期间 _openDrawerSession 仍要拿 dismissed（见该处注释）。
      _drawerRoute = route;
      unawaited(route.dismissed.then((_) {
        if (_drawerRoute == route) _drawerRoute = null;
      }));
      // 打开手势可能在会话加载完成前已抬手：push 后立即按抬手瞬间的速度
      // 与位移收尾（openDx 已在 _drawerGestureOpenDx 累计）。
      final endVelocity = _drawerGestureEndVelocity;
      if (gestureMode && endVelocity != null && handle != null) {
        handle.settle(
          velocityDx: endVelocity,
          openDx: _drawerGestureOpenDx,
        );
      }
      await route.popped;

      // 抽屉子树在退场动画期间仍存活（overlay 条目要等路由销毁才移除）：
      // 若在 popped（pop 瞬间）就 dispose，退场期间新挂载的子组件会对已
      // 销毁的 notifier addListener —— 移动端短滑跟手关闭时（抬手早于会话
      // 加载完成，handle.settle 在 push 后同步 pop）面板首帧才挂载，必现
      // "A ValueNotifier<int> was used after being disposed"。
      // 必须等路由彻底销毁再 dispose。
      await route.dismissed;

      refreshTick.dispose();
      selectionModeRequest.dispose();
    } catch (e) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_loadSessionsFailed('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    } finally {
      _drawerHandle = null;
      _isChatDrawerOpen = false;
    }
  }

  Future<void> _showGroupSessionList({double? gestureDx}) async {
    if (_controller.groupChannel == null) return;
    final gestureMode = gestureDx != null;
    if (_isChatDrawerOpen) return;
    _isChatDrawerOpen = true;
    try {
      final parentGroupId = _controller.groupChannel!.groupFamilyId;
      final sessions = await _sortSessionsByLatestMessage(
        await _controller.chatService
            .getGroupSessions(parentGroupId: parentGroupId),
      );
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      final c = _controller;
      final groupName = c.groupChannel?.name ?? 'Group';

      final header = Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.group, size: 22, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  groupName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.chat_groupMembersCount(c.groupAgents.length),
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ],
      );

      final refreshTick = ValueNotifier<int>(0);
      final selectionModeRequest = ValueNotifier<int>(0);

      final drawer = ChatMoreDrawer(
        header: header,
        headerOnTap: _navigateToGroupDetail,
        headerTrailingIcon: Icons.group_outlined,
        headerTrailingTooltip: l10n.chat_groupMembers,
        onHeaderTrailing: _showGroupMembersPanel,
        searchHint: l10n.chat_searchSessions,
        bodyBuilder: (context, query) {
          if (query.trim().isNotEmpty) {
            return SessionSearchResults(
              query: query.trim(),
              sessions: sessions,
              searchService: c.searchService,
              groupChannel: c.groupChannel,
              onSwitchSession: _openDrawerSession,
              onLocateMessage: _locateSearchMessage,
            );
          }
          return GroupSessionListPanel(
            sessions: sessions,
            currentChannelId: c.currentChannelId,
            controller: c,
            onNewSession: () => c.createNewGroupSession(),
            onSwitchSession: _openDrawerSession,
            onBatchDelete: (ids) => c.batchDeleteSessions(ids, isGroup: true),
            listRefreshTick: refreshTick,
            selectionModeRequest: selectionModeRequest,
            // 「更多」按钮放「新建会话」行右侧，搜索栏只保留输入。
            moreButton: SessionListHeaderMoreButton(
              sessions: sessions,
              databaseService: c.localDatabaseService,
              refreshTick: refreshTick,
              onMarkAll: () => _markAllDrawerSessionsRead(sessions, refreshTick),
              onShowTraces: () {
                Navigator.pop(context);
                _showChannelTraces();
              },
              onEnterSelectionMode:
                  sessions.length > 1 ? () => selectionModeRequest.value++ : null,
            ),
          );
        },
        footerActions: [
          ChatDrawerAction(
            icon: Icons.inventory_2_outlined,
            label: l10n.chat_storageSpace,
            onTap: _navigateToStorageSpace,
          ),
          ChatDrawerAction(
            icon: Icons.account_tree_outlined,
            label: l10n.chat_workflow,
            onTap: _showGroupWorkflow,
          ),
          ChatDrawerAction(
            icon: Icons.edit_outlined,
            label: l10n.chat_editGroupInfo,
            onTap: _editGroupInfo,
          ),
        ],
      );

      final width = _chatDrawerWidth(context);
      final handle = gestureMode
          ? RightDrawerHandle(
              width: width, openThreshold: _chatDrawerOpenSwipeThreshold)
          : null;
      _drawerHandle = handle;
      final route = LayoutUtils.showRightDrawer(
        context: context,
        builder: (_) => drawer,
        width: width,
        handle: handle,
        initialProgress: gestureMode
            ? (_drawerGestureOpenDx / width).clamp(0.0, 1.0)
            : 0,
        sharedController: _drawerController,
      );
      // 路由销毁（退场动画结束）后再清引用：pop 只完成 popped future，
      // 退场期间 _openDrawerSession 仍要拿 dismissed（见该处注释）。
      _drawerRoute = route;
      unawaited(route.dismissed.then((_) {
        if (_drawerRoute == route) _drawerRoute = null;
      }));
      // 打开手势可能在会话加载完成前已抬手：push 后立即按抬手瞬间的速度
      // 与位移收尾（openDx 已在 _drawerGestureOpenDx 累计）。
      final endVelocity = _drawerGestureEndVelocity;
      if (gestureMode && endVelocity != null && handle != null) {
        handle.settle(
          velocityDx: endVelocity,
          openDx: _drawerGestureOpenDx,
        );
      }
      await route.popped;

      // 抽屉子树在退场动画期间仍存活（overlay 条目要等路由销毁才移除）：
      // 若在 popped（pop 瞬间）就 dispose，退场期间新挂载的子组件会对已
      // 销毁的 notifier addListener —— 移动端短滑跟手关闭时（抬手早于会话
      // 加载完成，handle.settle 在 push 后同步 pop）面板首帧才挂载，必现
      // "A ValueNotifier<int> was used after being disposed"。
      // 必须等路由彻底销毁再 dispose。
      await route.dismissed;

      refreshTick.dispose();
      selectionModeRequest.dispose();
    } catch (e) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_loadGroupSessionsFailed('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    } finally {
      _drawerHandle = null;
      _isChatDrawerOpen = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Session drawer search
  // ---------------------------------------------------------------------------

  /// 按最新消息时间排序会话（无消息时回退到会话创建时间）。
  ///
  /// 点击进入会刷新 updated_at（供主页「最近打开」恢复会话用），但列表排序
  /// 不依赖它，因此进入会话不会改变列表位置——顺序只随消息活跃变化。
  Future<List<Channel>> _sortSessionsByLatestMessage(
    List<Channel> sessions,
  ) async {
    final times = <String, DateTime>{};
    await Future.wait(sessions.map((s) async {
      final latest =
          await _controller.localDatabaseService.getLatestChannelMessage(s.id);
      final created = latest?['created_at'] as String?;
      if (created != null) {
        final t = DateTime.tryParse(created);
        if (t != null) times[s.id] = t;
      }
    }));
    final sorted = [...sessions];
    sorted.sort((a, b) {
      final ta =
          times[a.id] ?? DateTime.fromMillisecondsSinceEpoch(a.createdAt);
      final tb =
          times[b.id] ?? DateTime.fromMillisecondsSinceEpoch(b.createdAt);
      return tb.compareTo(ta);
    });
    return sorted;
  }

  /// 关闭右侧抽屉并等待其彻底销毁（退场动画结束、路由 dispose）。
  ///
  /// 任何会销毁当前 ChatScreen 的导航（切换/新建会话）前都必须等待：导航
  /// 会 dispose 本页持有的抽屉共享动画控制器（见 dispose()），若抽屉还在
  /// 退场动画中，退场永远无法完成，抽屉路由永不销毁 —— 冻结在屏幕上并挡
  /// 住一切点击。与 `popped`（pop 瞬间完成）不同，这里必须等 `dismissed`。
  Future<void> _closeDrawerAndWait() async {
    final drawerRoute = _drawerRoute;
    if (drawerRoute == null) return;
    if (drawerRoute.isCurrent) {
      // 防御：入口若未先关抽屉（理论上入口都已 pop），这里兜底关闭。
      Navigator.of(context, rootNavigator: true).pop();
    }
    await drawerRoute.dismissed;
  }

  /// [NavigateToSessionEvent] 处理器：先关抽屉并等它彻底销毁，再原地替换
  /// 聊天页（嵌入模式走 [onSwitchChannel]），避免共享动画控制器被 dispose
  /// 导致抽屉冻结（见 [_closeDrawerAndWait]）。
  Future<void> _handleNavigateToSession({
    required String channelId,
    String? agentId,
    String? agentName,
    String? agentAvatar,
    bool embedded = false,
  }) async {
    await _closeDrawerAndWait();
    if (!mounted) return;
    if (embedded && widget.onSwitchChannel != null) {
      widget.onSwitchChannel!(channelId);
      return;
    }
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => ChatScreen(
          agentId: agentId ?? widget.agentId,
          agentName: agentName ?? _controller.agentName,
          agentAvatar: agentAvatar ?? _controller.agentAvatar,
          channelId: channelId,
          embedded: widget.embedded,
          onClose: widget.onClose,
          onSwitchChannel: widget.onSwitchChannel,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                  parent: animation, curve: Curves.easeOut)),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  /// 抽屉内切换会话：touch updated_at（主页恢复最近打开用），随后原地替换
  /// 聊天页（嵌入模式走 [onSwitchChannel]）。
  ///
  /// 切换前必须等抽屉彻底销毁：嵌入模式切换会重建右栏 Navigator（换 key）、
  /// 非嵌入模式 pushReplacement，两者都会销毁当前 ChatScreen，其持有的
  /// 抽屉共享动画控制器随之 dispose。若抽屉还在退场动画中就切换，退场
  /// 永远无法完成，抽屉路由永不销毁 —— 冻结在屏幕上并挡住一切点击。
  Future<void> _openDrawerSession(
    String channelId, {
    String? highlightMessageId,
  }) async {
    // 离开当前会话：若它是「新建会话」留下的空会话，自动删除，避免误点击
    // 「新建会话」产生空会话。
    await _controller.pruneEmptySessionBeforeSwitch(nextChannelId: channelId);
    await _controller.localDatabaseService.touchChannelUpdatedAt(channelId);
    if (!mounted) return;
    await _closeDrawerAndWait();
    if (!mounted) return;
    if (widget.embedded) {
      widget.onSwitchChannel?.call(
        channelId,
        highlightMessageId: highlightMessageId,
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => _controller.isGroupMode
              ? ChatScreen(
                  channelId: channelId,
                  highlightMessageId: highlightMessageId,
                  showBackButton: highlightMessageId != null,
                )
              : ChatScreen(
                  agentId: widget.agentId,
                  agentName: _controller.agentName,
                  agentAvatar: _controller.agentAvatar,
                  channelId: channelId,
                  highlightMessageId: highlightMessageId,
                  showBackButton: highlightMessageId != null,
                ),
        ),
      );
    }
  }

  /// 抽屉内搜索点击消息结果 → 定位：同会话滚动到该消息；
  /// 跨会话则切换会话并高亮该消息。
  void _locateSearchMessage(Message message, String? channelId) {
    if (channelId == null || channelId == _controller.currentChannelId) {
      _scrollToMessage(message.id);
      return;
    }
    _openDrawerSession(channelId, highlightMessageId: message.id);
  }

  /// 抽屉内「全部已读」：标记后自增 [refreshTick] 刷新列表未读角标，
  /// 并同步主页会话列表与当前聊天的未读状态。
  Future<void> _markAllDrawerSessionsRead(
    List<Channel> sessions,
    ValueNotifier<int> refreshTick,
  ) async {
    for (final s in sessions) {
      await _controller.localDatabaseService.markChannelMessagesAsRead(s.id);
    }
    refreshTick.value++;
    if (!mounted) return;
    unawaited(_refreshOtherSessionsUnread());
    unawaited(_controller.markMessagesAsReadIfAtBottom());
  }

  // ---------------------------------------------------------------------------
  // Group management (UI-bound dialogs)
  // ---------------------------------------------------------------------------

  Future<void> _editGroupInfo() async {
    if (LayoutUtils.isDesktopLayout(context)) {
      _editGroupInfoDesktop();
    } else {
      final channel = _controller.groupChannel;
      if (channel == null) return;
      final result = await Navigator.push<Channel>(
        context,
        MaterialPageRoute(
          builder: (context) => GroupDetailScreen(
            channel: channel,
            startInEditMode: true,
          ),
        ),
      );
      if (result is Channel && mounted) {
        _controller.updateGroupChannelInfo(result);
      }
    }
  }

  void _editGroupInfoDesktop() {
    final channel = _controller.groupChannel;
    final nameController = TextEditingController(text: channel?.name ?? '');
    final descController =
        TextEditingController(text: channel?.description ?? '');
    final systemPromptController =
        TextEditingController(text: channel?.systemPrompt ?? '');
    final maxRoundsController = TextEditingController(
      text: channel?.maxLoopRounds?.toString() ?? '',
    );
    String selectedMentionMode = channel?.effectiveMentionMode ?? 'adminOnly';

    LayoutUtils.showRightDrawer(
      context: context,
      builder: (ctx) {
        final panelL10n = AppLocalizations.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setDrawerState) => Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(panelL10n.chat_editGroupInfo,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold))),
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                          controller: nameController,
                          decoration: InputDecoration(
                              labelText: panelL10n.chat_groupName,
                              border: const OutlineInputBorder()),
                          autofocus: true),
                      const SizedBox(height: 16),
                      TextField(
                          controller: descController,
                          decoration: InputDecoration(
                              labelText:
                                  panelL10n.chat_groupDescriptionOptional,
                              border: const OutlineInputBorder()),
                          maxLines: 2),
                      const SizedBox(height: 16),
                      TextField(
                          controller: systemPromptController,
                          decoration: InputDecoration(
                              labelText: panelL10n.chat_groupSystemPrompt,
                              hintText: panelL10n.chat_groupSystemPromptHint,
                              border: const OutlineInputBorder()),
                          maxLines: 4),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedMentionMode,
                        decoration: InputDecoration(
                          labelText: panelL10n.chat_mentionMode,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.alternate_email),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'adminOnly',
                            child: Text(panelL10n.chat_mentionModeAdminOnly),
                          ),
                          DropdownMenuItem(
                            value: 'allMembers',
                            child: Text(panelL10n.chat_mentionModeAllMembers),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDrawerState(() {
                              selectedMentionMode = value;
                            });
                          }
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 4),
                        child: Text(
                          selectedMentionMode == 'allMembers'
                              ? panelL10n.chat_mentionModeAllMembersDesc
                              : panelL10n.chat_mentionModeAdminOnlyDesc,
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: maxRoundsController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: panelL10n.groupDetail_maxLoopRounds,
                          hintText: panelL10n.createGroup_maxLoopRoundsHint,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.loop),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(panelL10n.common_cancel)),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () async {
                              final newName = nameController.text.trim();
                              if (newName.isEmpty) {
                                showTopToast(
                                  ctx,
                                  panelL10n.chat_groupNameEmpty,
                                  icon: Icons.warning_amber,
                                  color: Colors.orange,
                                );
                                return;
                              }
                              final maxRoundsText =
                                  maxRoundsController.text.trim();
                              int? maxLoopRounds;
                              if (maxRoundsText.isNotEmpty) {
                                maxLoopRounds = int.tryParse(maxRoundsText);
                                if (maxLoopRounds == null ||
                                    maxLoopRounds < 1) {
                                  showTopToast(
                                    ctx,
                                    panelL10n.createGroup_maxLoopRoundsHint,
                                    icon: Icons.warning_amber,
                                    color: Colors.orange,
                                  );
                                  return;
                                }
                              }
                              final old = _controller.groupChannel!;
                              final newSystemPrompt =
                                  systemPromptController.text.trim();
                              final updated = Channel(
                                id: old.id,
                                name: newName,
                                type: old.type,
                                members: old.members,
                                createdBy: old.createdBy,
                                createdAt: old.createdAt,
                                description:
                                    descController.text.trim().isNotEmpty
                                        ? descController.text.trim()
                                        : null,
                                systemPrompt: newSystemPrompt.isNotEmpty
                                    ? newSystemPrompt
                                    : null,
                                avatar: old.avatar,
                                isPrivate: old.isPrivate,
                                maxLoopRounds: maxLoopRounds,
                                mentionMode: selectedMentionMode,
                                parentGroupId: old.parentGroupId,
                              );
                              await _controller.localDatabaseService
                                  .updateChannel(updated);
                              await GroupMemberSessionService(
                                      _controller.localDatabaseService)
                                  .syncTitlesForGroupFamily(
                                parentGroupId: updated.groupFamilyId,
                                groupName: newName,
                              );
                              if (mounted) {
                                _controller.updateGroupChannelInfo(updated);
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                            child: Text(panelL10n.common_save),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showGroupMembersPanel() async {
    final l10n = AppLocalizations.of(context);
    final content = GroupMembersPanel(
      groupAgents: _controller.groupAgents,
      channelId: _controller.currentChannelId!,
      adminAgentId: _controller.groupAdminAgentId,
      channelMembers: _controller.groupChannel?.members ?? [],
      onAddMember: _addGroupMemberFromPanel,
      onBatchRemoveMembers: _batchRemoveGroupMembersFromPanel,
      onSaveGroupBio: (agent, bio) =>
          _controller.saveMemberGroupBio(agent, bio),
      onChangeAdmin: (agent) async {
        if (agent.id == _controller.groupAdminAgentId) return;
        final parentGroupId = _controller.groupChannel?.groupFamilyId ??
            _controller.currentChannelId!;
        final sessions = await _controller.localDatabaseService
            .getGroupSessions(parentGroupId);
        for (final session in sessions) {
          if (_controller.groupAdminAgentId != null) {
            await _controller.localDatabaseService.updateChannelMemberRole(
                session.id, _controller.groupAdminAgentId!, 'member');
          }
          await _controller.localDatabaseService
              .updateChannelMemberRole(session.id, agent.id, 'admin');
        }
        await _controller.refreshGroupMembers();
        if (mounted) {
          showTopToast(
            context,
            AppLocalizations.of(context).chat_adminChanged(agent.name),
            icon: Icons.admin_panel_settings,
            color: Colors.green,
          );
        }
      },
      onMentionAgent: (agent) {
        Navigator.of(context).pop();
        _chatInputKey.currentState?.insertMentionForAgent(agent);
      },
    );

    if (LayoutUtils.isDesktopLayout(context)) {
      await LayoutUtils.showRightDrawer(
          context: context, builder: (_) => content).popped;
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(l10n.chat_groupMembers),
              elevation: 1,
            ),
            body: content,
          ),
        ),
      );
    }
  }

  Future<GroupMembersPanelSnapshot?> _addGroupMemberFromPanel(
    BuildContext panelContext,
  ) async {
    final added = await _addGroupMember(panelContext: panelContext);
    if (!added || !mounted) return null;
    return GroupMembersPanelSnapshot(
      groupAgents: _controller.groupAgents,
      channelMembers: _controller.groupChannel?.members ?? const [],
      adminAgentId: _controller.groupAdminAgentId,
    );
  }

  Future<List<RemoteAgent>?> _showAddGroupMemberPicker(
    List<RemoteAgent> available,
    BuildContext navigationContext,
  ) async {
    final isDesktop = LayoutUtils.isDesktopLayout(navigationContext);

    if (isDesktop) {
      return LayoutUtils.showRightDrawer<List<RemoteAgent>>(
        context: navigationContext,
        builder: (_) => AddGroupMemberPicker(availableAgents: available),
      ).popped;
    }

    return Navigator.push<List<RemoteAgent>>(
      navigationContext,
      MaterialPageRoute(
        builder: (context) => AddGroupMemberPicker(
          availableAgents: available,
          wrappedInScaffold: true,
        ),
      ),
    );
  }

  Future<bool> _addGroupMember({required BuildContext panelContext}) async {
    final l10n = AppLocalizations.of(context);
    final allAgents =
        await _controller.localDatabaseService.getAllRemoteAgents();
    final currentIds = _controller.groupAgents.map((a) => a.id).toSet();
    final available =
        allAgents.where((a) => !currentIds.contains(a.id)).toList();

    if (!mounted) return false;
    if (available.isEmpty) {
      showTopToast(
        context,
        l10n.chat_noMoreAgents,
        icon: Icons.group_off,
        color: Colors.blueGrey,
      );
      return false;
    }

    final selected = await _showAddGroupMemberPicker(available, panelContext);
    if (selected == null || selected.isEmpty || !mounted) return false;

    for (final agent in selected) {
      await _controller.addGroupMember(agent);
    }
    return true;
  }

  Future<GroupMembersPanelSnapshot?> _batchRemoveGroupMembersFromPanel(
    List<RemoteAgent> agents,
  ) async {
    if (agents.isEmpty || !mounted) return null;

    final l10n = AppLocalizations.of(context);
    if (_controller.groupAgents.length - agents.length < 1) {
      showTopToast(
        context,
        l10n.chat_cannotRemoveLast,
        icon: Icons.warning_amber,
        color: Colors.orange,
      );
      return null;
    }

    for (final agent in agents) {
      await _controller.removeGroupMember(agent);
    }

    if (!mounted) return null;
    return GroupMembersPanelSnapshot(
      groupAgents: _controller.groupAgents,
      channelMembers: _controller.groupChannel?.members ?? const [],
      adminAgentId: _controller.groupAdminAgentId,
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  Future<bool> _showHistoryRequestDialog(String reason) async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chat_historyRequestTitle),
        content: Text(reason),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.chat_historyIgnore)),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.chat_historyApprove)),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _showOsToolConfirmation(
      String toolName, Map<String, dynamic> args, dynamic risk) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('OS Tool: $toolName'),
        content: Text('Allow execution?\nArgs: $args'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Deny')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Allow')),
        ],
      ),
    );
    return result ?? false;
  }

  void _showClearingOverlay(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (context) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// 抽屉在移动端的宽度：近全宽（92%），clamp 到 [240, 360]；桌面固定 360。
  double _chatDrawerWidth(BuildContext context) {
    if (LayoutUtils.isDesktopLayout(context)) return 360;
    return (MediaQuery.sizeOf(context).width * 0.92).clamp(240.0, 360.0);
  }

  /// 单聊抽屉 header：头像 + 名称 + 在线/离线状态。
  Widget _buildDmDrawerHeader(AppLocalizations l10n) {
    final c = _controller;
    final displayName = c.agentName == null
        ? null
        : SheService.resolveDisplayName(c.agentName, l10n.she_name);
    final avatar = c.agentAvatar != null && c.agentAvatar!.length > 2
        ? AvatarImage(
            avatar: c.agentAvatar!,
            size: 40,
            borderRadius: 10,
            fallback: Text(
              displayName?.isNotEmpty == true ? displayName![0] : 'A',
              style: const TextStyle(fontSize: 18),
            ),
          )
        : Text(
            c.agentAvatar ??
                (displayName?.isNotEmpty == true ? displayName![0] : 'A'),
            style: const TextStyle(fontSize: 18),
          );

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: avatar,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName ?? 'AI Agent',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                c.isAgentOnline ? l10n.status_online : l10n.status_offline,
                style: TextStyle(
                  fontSize: 12,
                  color:
                      c.isAgentOnline ? const Color(0xFF34C759) : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 「更多」按钮：点击从右侧滑出抽屉，抽屉主体即会话列表。
  /// 未读角标全平台显示（其他会话有未读消息时）。
  Widget _buildChatMoreButton(AppLocalizations l10n) {
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    return IconButton(
      tooltip: l10n.chat_moreActions,
      icon: SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Center(child: Icon(Icons.more_vert)),
            if (_otherSessionsUnreadCount > 0)
              const Positioned(
                right: -3,
                top: -3,
                child: SessionUnreadDot(),
              ),
          ],
        ),
      ),
      iconSize: 22,
      padding: EdgeInsets.zero,
      constraints:
          BoxConstraints.tightFor(width: isDesktop ? 36.0 : 40.0, height: 40),
      onPressed:
          _controller.isGroupMode ? _showGroupSessionList : _showSessionList,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = _controller;
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    final hasCustomLeading = widget.showBackButton && widget.onClose != null;
    final hasLeading = hasCustomLeading ||
        (!widget.embedded && Navigator.of(context).canPop());
    // 抽屉打开期间整个聊天页随抽屉联动左移（含动画与手指拖动），
    // 形成抽屉与聊天页连为一体的效果。animation 与抽屉路由共享同一控制器
    // （showRightDrawer 传的 sharedController），进度严格同源。
    return RightDrawerLinkedPage(
      width: _chatDrawerWidth(context),
      animation: _drawerController,
      child: Scaffold(
      appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0.5,
          automaticallyImplyLeading: !widget.embedded,
          centerTitle: false,
          leadingWidth: hasLeading && !isDesktop ? 48 : null,
          // 有返回键时贴齐箭头；桌面嵌入无 leading 时留 16px，避免头像贴分割线。
          titleSpacing: hasLeading ? 0 : 16,
          leading: hasCustomLeading
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onClose,
                )
              : null,
          title: SizedBox(
            width: double.infinity,
            child: c.isGroupMode
                ? ChatGroupAppBarTitle(
                    groupChannel: c.groupChannel,
                    groupAgents: c.groupAgents,
                    isProcessing: c.isProcessing,
                    respondingAgentNames: c.respondingAgentNames,
                    mentionOnlyMode: c.mentionOnlyMode,
                    currentChannelId: c.currentChannelId,
                    onAvatarTap: _navigateToGroupDetail,
                    onStopGenerating:
                        c.isProcessing ? () => c.stopGroupStreaming() : null,
                  )
                : ChatDMAppBarTitle(
                    agentName: c.agentName,
                    agentAvatar: c.agentAvatar,
                    isProcessing: c.isProcessing,
                    isCheckingHealth: c.isCheckingHealth,
                    isAgentOnline: c.isAgentOnline,
                    currentChannelId: c.currentChannelId,
                    sourceDeviceLabel: c.sourceDeviceLabel,
                    syncingRemote: _syncingPeerHistory,
                    onAvatarTap: _navigateToAgentDetail,
                    onStopGenerating:
                        c.isProcessing ? () => c.stopStreaming() : null,
                  ),
          ),
          actionsPadding: const EdgeInsets.only(right: 8),
          actions: [
            _buildChatMoreButton(l10n),
          ],
        ),
      // 触屏设备全区域左滑（向右边缘滑）打开右侧抽屉，跟手模式：识别成功
        // 后抽屉与聊天页同步跟随手指（见 _onOpenGesture*）；垂直主导的滑动
        // 让位给消息列表滚动，不影响上下滑动（与主页左侧抽屉同款手势逻辑）。
        // 桌面端保留按钮入口，避免鼠标拖选文本误触；emoji 面板打开时禁用，
        // 防止横向滑分类误开抽屉。
        body: DrawerSwipeDetector(
          enabled: !LayoutUtils.isDesktopLayout(context) && !_showEmojiPicker,
          // Android 手势返回 = 右边缘向左滑，与右抽屉打开手势同方向：把
          // 右边缘系统手势区（systemGestureInsets.right，通常 ~34px）让给
          // 系统返回，避免抢事件 —— 用户滑返回时抽屉被误打开。主页左侧
          // 抽屉对应的左边缘由 blockLeadingEdgeDrawerGesture 处理。
          blockTrailingEdgeDrawerGesture: true,
          // 触发阈值 = 30px 的真实横向滑动距离（见
          // _chatDrawerOpenSwipeThreshold）：上下滚动时手指带出的轻微横向
          // 漂移在到达 30px 之前，列表已在 dy ≥ 18px（verticalScrollSlop）
          // 接管竞技场，滚动正常、抽屉不触发；只有刻意左滑超过 30px 才
          // 开始打开（跟手：抽屉只出来手指拖过的距离）。
          // 气泡共存：气泡文本在空闲时不包 SelectionArea（message_bubble.dart
          // 的 _wrapWithTextSelection），选区的横向拖拽识别器（|dx|>18 抢先
          // 接受）不参与竞技场 —— 气泡上的左滑与普通区域一样 30px 打开，
          // 不再被选区抢走；长按选中时 SelectionArea 才挂载（此时选区内拖拽
          // 优先，抽屉让位）。verticalDominance 2.0 保留纵向让位（dy > 2×dx
          // 即拒，约 63° 以上的真实滚动瞬间让给列表）；45°~63° 斜向滑动保持
          // wait，自然输给列表。horizontalDominance 1.0（45° 锥）：真实手指/
          // 模拟器拖动几乎不可能完全水平，旧值 1.5（33.7° 锥）会把 dy/dx
          // 略大的打开手势全部误杀。横向滚动/输入框被识别器在 down 时让位
          //（见 drawer_swipe_detector.dart 的 _hasOwnedHorizontalGestureAt）。
          touchSlop: 8,
          minOpenDistance: _chatDrawerOpenSwipeThreshold,
          horizontalDominance: 1.0,
          verticalDominance: 2.0,
          direction: DrawerSwipeDirection.rightToLeft,
          onOpenGestureStart: _onOpenGestureStart,
          onOpenGestureUpdate: _onOpenGestureUpdate,
          onOpenGestureEnd: _onOpenGestureEnd,
          child: Column(
            children: [
              // She config banner — shown when She has no LLM model configured
              if (_sheNeedsConfig) _buildSheConfigBanner(),
  
              // Message list
              Expanded(
                child: Stack(
                  children: [
                    c.messages.isEmpty && !c.isLoading
                        ? (_sheNeedsConfig
                            ? _buildSheWelcomeState()
                            : _buildEmptyState())
                        : NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is UserScrollNotification) {
                                _onUserScroll(notification.direction);
                              } else if (notification is ScrollEndNotification) {
                                _onScrollEnd(notification.metrics);
                              }
                              return false;
                            },
                            child: ChatMessageList(
                              messages: c.messages,
                              messageIdMap: c.messageIdMap,
                              streamingMessageId: c.streamingMessageId,
                              groupStreamingMessageIds:
                                  c.groupStreamingMessageIds,
                              isGroupMode: c.isGroupMode,
                              channelId: c.currentChannelId,
                              itemScrollController: _itemScrollController,
                              itemPositionsListener: _itemPositionsListener,
                              onStopStreaming: () => c.isGroupMode
                                  ? c.stopCurrentGroupMessageOnly()
                                  : c.stopCurrentMessageOnly(),
                              onActionSelected: (msg, cid, aid, alabel,
                                  {confirmationContext}) {
                                c.handleActionSelected(msg, cid, aid, alabel,
                                    confirmationContext: confirmationContext);
                              },
                              onSingleSelectSubmitted: (msg, sid, oid, olabel) {
                                c.handleSingleSelectSubmitted(
                                    msg, sid, oid, olabel);
                              },
                              onMultiSelectSubmitted: (msg, sid, oids, summary) {
                                c.handleMultiSelectSubmitted(
                                    msg, sid, oids, summary);
                              },
                              onFileUploadSubmitted: (msg, uid, files, summary) {
                                c.handleFileUploadSubmitted(
                                    msg, uid, files, summary);
                              },
                              onFormSubmitted: (msg, fid, values, summary) {
                                c.handleFormSubmitted(msg, fid, values, summary);
                              },
                              onPlanApprovalResponded: (msg, approved,
                                      {feedback, skippedTaskIds}) =>
                                  c.handlePlanApprovalResponded(msg, approved,
                                      feedback: feedback,
                                      skippedTaskIds: skippedTaskIds),
                              onReply: (msg) => c.startReply(msg),
                              onRollback: (msg) => c.rollbackMessage(msg),
                              onRollbackReEdit: (msg, {bool reEdit = false}) =>
                                  c.rollbackMessage(msg, reEdit: reEdit),
                              onDelete: (msg) => c.deleteMessage(msg),
                              onAgentAvatarTap: _navigateToAgentDetailById,
                              onScrollToMessage: _scrollToMessage,
                              highlightedMessageId: c.highlightedMessageId,
                              onViewTrace: (message) {
                                final traceId =
                                    message.metadata?['trace_id'] as String?;
                                if (traceId != null) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          TraceDetailScreen(traceId: traceId),
                                    ),
                                  );
                                }
                              },
                              agentAvatarMap: c.isGroupMode
                                  ? {
                                      for (final a in c.groupAgents)
                                        if (a.avatar.isNotEmpty) a.id: a.avatar,
                                    }
                                  : (c.agentId != null &&
                                          c.agentAvatar != null &&
                                          c.agentAvatar!.isNotEmpty
                                      ? {c.agentId!: c.agentAvatar!}
                                      : const {}),
                              isAgentOffline: !c.isAgentOnline,
                              defaultWorkspaceUris: c.defaultWorkspaceUris,
                              workspaceUrisByAgentId: c.workspaceUrisByAgentId,
                            ),
                          ),
                    if (_isUserScrolledUp)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: _buildScrollToBottomButton(),
                      ),
                    if (_controller.isLoadingOlderMessages)
                      const Positioned(
                        top: 8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
  
              // Workflow progress panel (floating above input)
              if ((c.isGroupMode || c.dmWorkflowEnabled) &&
                  c.workflowNeedsPanelAttention)
                Material(
                  color: Colors.blue.shade50,
                  child: InkWell(
                    onTap: c.reopenWorkflowPanel,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.playlist_play,
                              size: 18, color: Colors.blue.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.workflow_inProgressBanner,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.blue.shade800,
                              ),
                            ),
                          ),
                          Icon(Icons.expand_less,
                              size: 18, color: Colors.blue.shade700),
                        ],
                      ),
                    ),
                  ),
                ),
              if ((c.isGroupMode || c.dmWorkflowEnabled) &&
                  c.showWorkflowProgressPanel)
                WorkflowProgressPanel(
                  workflowId: c.activeWorkflowId!,
                  pendingPeerApproval: c.workflowPeerApprovalPending,
                  onScrollToApproval: _scrollToMessage,
                  onPeerApprovalAction: (confirmationId, actionId, actionLabel) {
                    c.handleWorkflowPeerApprovalAction(
                      confirmationId,
                      actionId,
                      actionLabel,
                    );
                  },
                  onDismiss: () => c.dismissWorkflowPanel(),
                  onApprovalResponse: (approved, {feedback}) {
                    c.handleWorkflowApproval(approved, feedback: feedback);
                  },
                ),
  
              // Voice record overlay
              if (_isRecording)
                VoiceRecordOverlay(
                  elapsed: _recordingElapsed,
                  amplitude: _recordingAmplitude,
                  isCancelZone: _isCancelZone,
                ),
  
              // Reply preview bar
              if (c.replyingToMessage != null &&
                  !c.isViewingGroupBoundMemberSession &&
                  !c.isViewingSheBoundSession)
                ChatReplyPreview(
                  replyingTo: c.replyingToMessage!,
                  onCancel: () => c.cancelReply(),
                ),
  
              // Queue indicator
              if (!c.isViewingGroupBoundMemberSession &&
                  !c.isViewingSheBoundSession)
                _buildQueueIndicator(),
  
              // Bound sessions (group member / She relay): input disabled +
              // jump to the linked source conversation.
              if (c.isViewingGroupBoundMemberSession)
                _buildGroupBoundSessionBar(c)
              else if (c.isViewingSheBoundSession)
                _buildSheBoundSessionBar(c)
              else
                ChatInputArea(
                  key: _chatInputKey,
                  messageController: _messageController,
                  textFieldFocusNode: _textFieldFocusNode,
                  isLoading: c.isLoading,
                  isGroupMode: c.isGroupMode,
                  pendingAttachments: _pendingAttachments,
                  groupAgents: c.groupAgents,
                  audioRecordingService: _audioRecordingService,
                  isRecording: _isRecording,
                  isCancelZone: _isCancelZone,
                  onSend: _sendMessage,
                  onToggleEmojiPicker: _toggleEmojiPicker,
                  onShowAttachmentOptions: _showAttachmentOptions,
                  onPickFile: _pickAndStageFile,
                  onPickFromStorageBag: _pickFromStorageBag,
                  onSendVoice: _sendVoiceMessage,
                  showEmojiPicker: _showEmojiPicker,
                  onRemoveAttachment: _removePendingAttachment,
                  onMentionPickerChanged: () {
                    if (mounted) setState(() {});
                  },
                  onDesktopPaste: _handleDesktopPaste,
                  hasAudioModel: _agentSupportsAudio,
                  slashCommands: c.agentId == null
                      ? const []
                      : (c.chatService
                              .getACPConnection(c.agentId!)
                              ?.slashCommands ??
                          c.chatService.getSlashCommandsSnapshot(c.agentId!)),
                  slashCommandsStream: c.agentId == null
                      ? null
                      : (c.chatService
                              .getACPConnection(c.agentId!)
                              ?.slashCommandsStream ??
                          PeerAgentClientService.instance
                              .slashCommandsStream(c.agentId!)),
                  // Live resolver: read the current snapshot on every keystroke.
                  // Falls back to the process-wide snapshot cache (populated by
                  // any past ACP connection — including the short-lived
                  // health-check connection) when no persistent connection is
                  // active yet. This is what lets the "/" palette work before
                  // the user has sent their first message.
                  slashCommandsResolver: () {
                    if (c.agentId == null) return const [];
                    final conn = c.chatService.getACPConnection(c.agentId!);
                    final live = conn?.slashCommands ?? const [];
                    if (live.isNotEmpty) return live;
                    final snap =
                        c.chatService.getSlashCommandsSnapshot(c.agentId!);
                    if (snap.isNotEmpty) return snap;
                    // Peer agents have no ACP connection — use the prefetched
                    // slash-command cache from PeerAgentClientService.
                    return PeerAgentClientService.instance
                        .getSlashCommands(c.agentId!);
                  },
                ),
  
              // Mobile emoji picker panel (desktop uses a floating popover
              // anchored to the emoji button inside ChatInputArea).
              if (_showEmojiPicker &&
                  !LayoutUtils.isDesktopLayout(context) &&
                  !c.isViewingGroupBoundMemberSession &&
                  !c.isViewingSheBoundSession)
                SizedBox(
                  height: 250,
                  child: EmojiPicker(
                    onEmojiSelected: _onEmojiSelected,
                    onBackspacePressed: _onBackspacePressed,
                    config: Config(
                      height: 250,
                      emojiViewConfig: EmojiViewConfig(
                        emojiSizeMax: 28 * (Platform.isIOS ? 1.30 : 1.0),
                        backgroundColor: Colors.white,
                      ),
                      categoryViewConfig: CategoryViewConfig(
                        indicatorColor: Theme.of(context).primaryColor,
                        iconColorSelected: Theme.of(context).primaryColor,
                        backgroundColor: Colors.white,
                      ),
                      searchViewConfig: const SearchViewConfig(),
                      bottomActionBarConfig:
                          const BottomActionBarConfig(enabled: false),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // She config helpers
  // ---------------------------------------------------------------------------

  Widget _buildGroupBoundSessionBar(ChatController c) {
    final l10n = AppLocalizations.of(context);
    final groupName = c.sourceGroupName?.trim();
    final openLabel = (groupName != null && groupName.isNotEmpty)
        ? l10n.chat_openLinkedGroupNamed(groupName)
        : l10n.chat_openLinkedGroup;

    return Material(
      color: Colors.teal.shade50,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Icon(Icons.groups_outlined,
                  size: 22, color: Colors.teal.shade700),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.chat_groupBoundInputDisabled,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.teal.shade900,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _openLinkedGroupChat(c),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.teal.shade800,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(openLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_forward, size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLinkedGroupChat(ChatController c) async {
    final groupChannelId = c.sourceGroupChannelId;
    if (groupChannelId == null || groupChannelId.isEmpty) return;

    // sourceGroupChannelId is the exact group session this member DM is bound to.
    await c.localDatabaseService.touchChannelUpdatedAt(groupChannelId);
    if (!mounted) return;

    if (widget.embedded) {
      widget.onSwitchChannel?.call(groupChannelId);
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(channelId: groupChannelId),
      ),
    );
  }

  /// She 绑定会话的只读提示条：标识来自 She，提供跳转回 She 会话入口。
  Widget _buildSheBoundSessionBar(ChatController c) {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: Colors.orange.shade50,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Icon(Icons.pets_outlined,
                  size: 22, color: Colors.orange.shade700),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.chat_sheBoundInputDisabled,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.orange.shade900,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _openLinkedSheChat(c),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.orange.shade800,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.chat_openLinkedShe,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_forward, size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLinkedSheChat(ChatController c) async {
    final sheChannelId = c.sourceSheChannelId;
    if (sheChannelId == null || sheChannelId.isEmpty) return;

    // sourceSheChannelId 是本中转会话绑定的 She↔用户 会话。
    await c.localDatabaseService.touchChannelUpdatedAt(sheChannelId);
    if (!mounted) return;

    if (widget.embedded) {
      widget.onSwitchChannel?.call(sheChannelId);
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(channelId: sheChannelId),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // She config helpers
  // ---------------------------------------------------------------------------

  /// Check if She agent exists but has no LLM model configured yet.
  Future<void> _checkSheNeedsConfig() async {
    final agentId = widget.agentId;
    if (agentId == null || agentId != SheService.sheId) return;
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final needsConfig = agent != null && !agent.isLocal;
    if (needsConfig != _sheNeedsConfig) {
      setState(() => _sheNeedsConfig = needsConfig);
    }
  }

  Future<void> _checkAgentImageSupport() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final supportsImage =
        agent != null && agent.supportsModality(ModalityType.image);
    if (supportsImage != _agentSupportsImage) {
      setState(() => _agentSupportsImage = supportsImage);
    }
  }

  /// Check whether the current agent's LLM configuration supports audio input.
  Future<void> _checkAgentAudioSupport() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final supportsAudio =
        agent != null && agent.supportsModality(ModalityType.audio);
    if (supportsAudio != _agentSupportsAudio) {
      setState(() => _agentSupportsAudio = supportsAudio);
    }
  }

  /// 断连期间被判死的 turn 可能已在远端跑完 —— service 重连后发来的
  /// reconcile 通知（'peerId::remoteAgentId'）。匹配当前 agent 时做一次
  /// 增量历史同步把结果补回对话；用户未表态过同步偏好时不弹窗打扰。
  Future<void> _onPeerReconcileRequest(String key) async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final sep = key.indexOf('::');
    if (sep <= 0) return;
    final peerId = key.substring(0, sep);
    final remoteAgentId = key.substring(sep + 2);
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (agent == null || !agent.isPeerAgent) return;
    if (agent.sourcePeerId != peerId || agent.remoteAgentId != remoteAgentId) {
      return;
    }
    if (!mounted) return;
    await _maybeSyncPeerAgent(promptIfUndecided: false);
  }

  /// On entry to a peer agent chat, incrementally sync remote sessions + dirty
  /// history — but only after the user has decided whether to sync.
  ///
  /// Preference key `peer_sync_disabled_$agentId`:
  /// - `null` (undecided): prompt once when there are unsynced remote sessions
  /// - `false` (enabled): auto-sync silently; changeable in agent settings
  /// - `true` (disabled): skip; changeable in agent settings
  ///
  /// [promptIfUndecided] controls the undecided case: chat entry passes true
  /// (the dialog is expected there); background paths (reconnect reconcile)
  /// pass false and simply skip until the user decides on next entry.
  Future<void> _maybeSyncPeerAgent({bool promptIfUndecided = true}) async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (agent == null || !agent.isPeerAgent) return;
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (peerId == null || remoteAgentId == null) return;

    final prefs = await SharedPreferences.getInstance();
    final syncDisabled = prefs.getBool('peer_sync_disabled_$agentId');
    if (syncDisabled == true) return;

    // Need a live connection to enumerate remote sessions; retry on a later
    // open if the peer isn't connected yet.
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId))
      return;

    // Undecided — prompt only when there are remote sessions not yet mirrored.
    var showToastOnFirstLink = false;
    if (syncDisabled == null && !promptIfUndecided) return;
    if (syncDisabled == null) {
      final sessions = await PeerAgentClientService.instance.fetchSessions(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
      );
      if (!mounted || sessions.isEmpty) return;

      final localChannels =
          await _controller.localDatabaseService.getChannelsForAgent(agentId);
      final remoteSessionIds = sessions.map((s) => s.sessionId).toSet();
      final localRemoteIds = collectLocalBoundRemoteSessionIds(
        localChannels.map((c) => c.id),
        remoteSessionIds,
      );
      final missing =
          sessions.where((s) => !localRemoteIds.contains(s.sessionId)).toList();

      if (missing.isNotEmpty) {
        final choice =
            await _showPeerSessionSyncDialog(agent.name, missing.length);
        if (!mounted || choice == null)
          return; // dismissed → ask again next time
        if (choice == _PeerSyncChoice.disable) {
          await prefs.setBool('peer_sync_disabled_$agentId', true);
          return;
        }
        await prefs.setBool('peer_sync_disabled_$agentId', false);
        showToastOnFirstLink = true;
      }
      // Missing empty or user opted in → fall through to incremental sync.
    }

    if (!mounted) return;
    await _runPeerAgentIncrementalSync(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: agentId,
      agentName: agent.name,
      showToastOnFirstLink: showToastOnFirstLink,
    );
  }

  /// Run agent-wide incremental sync; spinner only covers the open channel.
  Future<void> _runPeerAgentIncrementalSync({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String agentName,
    bool showToastOnFirstLink = false,
  }) async {
    final channelId = widget.channelId;
    final prioritizeCurrent = channelId != null;
    if (prioritizeCurrent && mounted) {
      setState(() => _syncingPeerHistory = true);
    }

    late final PeerAgentIncrementalSyncResult result;
    try {
      result = await PeerAgentClientService.instance.syncAgentIncremental(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        localAgentId: localAgentId,
        agentName: agentName,
        userId: _controller.getUserId(),
        userName: _controller.getUserName(),
        prioritizeChannelId: channelId,
        onPrioritizedChannelDone: (written) async {
          if (mounted) setState(() => _syncingPeerHistory = false);
          if (written > 0 &&
              mounted &&
              channelId != null &&
              _controller.currentChannelId == channelId) {
            await _controller.reloadMessagesFromDB();
          }
        },
      );
    } finally {
      if (mounted && _syncingPeerHistory) {
        setState(() => _syncingPeerHistory = false);
      }
    }

    if (!mounted || !showToastOnFirstLink) return;
    if (result.sessionsLinked > 0) {
      final l10n = AppLocalizations.of(context);
      showTopToast(
        context,
        l10n.chat_syncedRemoteSessions(result.sessionsLinked),
        icon: Icons.sync,
        color: Colors.green,
      );
    }
  }

  /// Prefetch slash commands when opening a peer agent chat. The connect-time
  /// prefetch can time out on a cold agent-bridge (ensureCommandsWarm takes a
  /// few seconds), leaving the "/" palette empty until we retry here.
  Future<void> _ensurePeerSlashCommands() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent =
        await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (agent == null || !agent.isPeerAgent) return;
    await PeerAgentClientService.instance.ensureCommandsForLocalAgent(agentId);
  }

  Future<_PeerSyncChoice?> _showPeerSessionSyncDialog(
      String agentName, int count) async {
    return showDialog<_PeerSyncChoice>(
      context: context,
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(l10n.chat_syncRemoteSessionsTitle),
          content: Text(l10n.chat_syncRemoteSessionsBody(agentName, count)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_PeerSyncChoice.disable),
              child: Text(l10n.chat_doNotSync),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(_PeerSyncChoice.sync),
              child: Text(l10n.common_sync),
            ),
          ],
        );
      },
    );
  }

  /// Navigate to She's detail screen so the user can pick a model.
  Future<void> _openSheConfig() async {
    await _navigateToAgentDetail();
    // Re-check after returning from detail screen
    _checkSheNeedsConfig();
    _checkAgentAudioSupport();
    _checkAgentImageSupport();
  }

  Widget _buildSheConfigBanner() {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: Colors.amber.shade50,
      child: InkWell(
        onTap: _openSheConfig,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.settings_suggest_outlined,
                  size: 20, color: Colors.orange),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.chat_sheNoModel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade800,
                      ),
                    ),
                    Text(
                      l10n.chat_sheNoModelTapSettings,
                      style: TextStyle(
                          fontSize: 12, color: Colors.orange.shade700),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 20, color: Colors.orange.shade600),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSheWelcomeState() {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('🌸',
                          style: TextStyle(fontSize: 72),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context).she_name,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.chat_sheTagline,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      FilledButton.icon(
                        onPressed: _openSheConfig,
                        icon: const Icon(Icons.settings_suggest_outlined),
                        label: Text(AppLocalizations.of(context)
                            .chat_sheConfigModelCta),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.pink.shade400,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context).chat_sheNeedModelHint,
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(20),
            ),
            alignment: Alignment.center,
            child: _controller.agentAvatar != null &&
                    _controller.agentAvatar!.length > 2
                ? AvatarImage(
                    avatar: _controller.agentAvatar!,
                    size: 80,
                    borderRadius: 20,
                    fallback: Text(
                      _controller.agentName?.isNotEmpty == true
                          ? _controller.agentName![0]
                          : 'A',
                      style: const TextStyle(fontSize: 56),
                    ),
                  )
                : Text(
                    _controller.agentAvatar ??
                        (_controller.agentName?.isNotEmpty == true
                            ? _controller.agentName![0]
                            : 'A'),
                    style: const TextStyle(fontSize: 56),
                  ),
          ),
          const SizedBox(height: 16),
          Text(_controller.agentName ?? 'AI Agent',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Send a message to start chatting',
              style: TextStyle(color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildScrollToBottomButton() {
    return GestureDetector(
      onTap: _jumpToBottom,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unreadMessageCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(
                  _unreadMessageCount > 99 ? '99+' : '$_unreadMessageCount',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 4),
            ],
            Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.grey[700]),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueIndicator() {
    if (_controller.messageQueue.isEmpty) return const SizedBox.shrink();

    final count = _controller.messageQueue.length;
    final preview = _controller.messageQueue.first.length > 40
        ? '${_controller.messageQueue.first.substring(0, 40)}...'
        : _controller.messageQueue.first;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        border: const Border(
            top: BorderSide(color: AppColors.primaryLight, width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.queue, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  count == 1 ? '1 message queued' : '$count messages queued',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryDark),
                ),
                Text(preview,
                    style:
                        const TextStyle(fontSize: 11, color: AppColors.primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _controller.messageQueue.clear();
              });
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('Clear',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.red[400],
                      fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }
}
