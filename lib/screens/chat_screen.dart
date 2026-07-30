import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../services/local_user_identity.dart';
import '../models/channel.dart';
import '../models/mention_entry.dart';
import '../models/pending_attachment.dart';
import '../models/remote_agent.dart';
import '../models/model_routing_config.dart';
import '../services/audio_recording_service.dart';
import '../services/composer_draft_service.dart';
import '../services/local_database_service.dart';
import '../services/group/group_member_session_service.dart';
import '../utils/layout_utils.dart';
import '../l10n/app_localizations.dart';
import '../controllers/chat_controller.dart';
import '../controllers/chat_attachment_coordinator.dart';
import '../theme/app_theme.dart';
import '../widgets/chat/chat_app_bar.dart';
import '../widgets/chat/chat_menu.dart';
import '../widgets/chat/chat_input_area.dart';
import '../widgets/chat/chat_message_list.dart';
import '../widgets/chat/chat_reply_preview.dart';
import '../widgets/chat/session_list_panel.dart';
import '../widgets/chat/group_session_list_panel.dart';
import '../widgets/chat/chat_mobile_menu_drawer.dart';
import '../widgets/chat/group_members_panel.dart';
import '../widgets/chat/add_group_member_panel.dart';
import '../widgets/chat/system_prompt_panel.dart';
import '../widgets/avatar_image.dart';
import '../widgets/message_search_delegate.dart';
import '../widgets/shepaw_search_page.dart';
import '../widgets/voice_record_overlay.dart';
import 'remote_agent_detail_screen.dart';
import 'group_detail_screen.dart';
import '../services/logger_service.dart';
import '../services/error_handler_service.dart';
import '../services/she_service.dart';
import 'channel_trace_screen.dart';
import 'group_workflow_screen.dart';
import '../widgets/workflow/workflow_progress_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import '../service_locator.dart' show getIt;

/// User's response to the "sync remote sessions" prompt.
/// Both choices are persisted; the dialog is only shown while undecided.
enum _PeerSyncChoice { sync, disable }

class ChatScreen extends StatefulWidget {
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final String? channelId;
  final bool embedded;
  final VoidCallback? onClose;
  final void Function(String channelId, {String? highlightMessageId})? onSwitchChannel;
  final ValueChanged<String?>? onShowTraces;
  final void Function(String channelId, String channelName)? onShowGroupWorkflow;

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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatController _controller;
  StreamSubscription<ChatEvent>? _eventSubscription;

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
  int _unreadMessageCount = 0;

  // Pending highlight from search navigation
  String? _pendingHighlightMessageId;

  // Whether She agent needs LLM model configuration
  bool _sheNeedsConfig = false;

  // Whether the current agent's LLM supports audio/voice input
  bool _agentSupportsAudio = false;

  // Whether the current agent supports image input routing
  bool _agentSupportsImage = false;

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Last draft key used for migrate-from-agent → channel.
  String? _lastDraftKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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

    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    }

    _controller.init();
    _audioRecordingService.requestPermission();
    _pendingHighlightMessageId = widget.highlightMessageId;
    _checkSheNeedsConfig();
    _checkAgentAudioSupport();
    _checkAgentImageSupport();
    _maybeSyncPeerAgent();
    _ensurePeerSlashCommands();
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
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
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
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _recordingSubscription?.cancel();
    _audioRecordingService.dispose();
    _messageController.dispose();
    _textFieldFocusNode.dispose();
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
    // During active streaming, if user is scrolled up, skip expensive
    // full rebuilds — the message list content updates in the controller
    // and will render when the user scrolls back to bottom.
    if (_isUserScrolledUp &&
        (_controller.streamingMessageId != null ||
         _controller.groupStreamingMessageIds.isNotEmpty)) {
      return;
    }
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
      case NavigateToSessionEvent(:final channelId, :final agentId, :final agentName, :final agentAvatar, :final embedded):
        if (embedded && widget.onSwitchChannel != null) {
          widget.onSwitchChannel!(channelId);
        } else {
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
                    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
                    child: child,
                  ),
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            ),
          );
        }
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
          _scrollToBottom(force: force);
        }
      case ShowHistoryRequestDialogEvent(:final reason, :final result):
        _showHistoryRequestDialog(reason).then((approved) {
          if (!result.isCompleted) result.complete(approved);
        });
      case ShowOsToolConfirmationEvent(:final toolName, :final args, :final risk, :final result):
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
      setState(() { _showEmojiPicker = false; });
    }
  }

  void _onUserScroll(ScrollDirection direction) {
    // Only react to user-initiated scroll gestures (not programmatic scrolls).
    // In a reverse list, ScrollDirection.forward means scrolling toward older
    // messages (upward visually), and ScrollDirection.reverse means scrolling
    // toward newer messages (downward visually).
    if (direction == ScrollDirection.forward) {
      if (!_isUserScrolledUp) {
        // Update the flag synchronously before setState so that
        // _onControllerChanged can read the correct value immediately in the
        // same frame and skip the rebuild that would interrupt the gesture.
        _isUserScrolledUp = true;
        _controller.isUserScrolledUp = true;
        setState(() {});
      }
    } else if (direction == ScrollDirection.reverse) {
      // User is scrolling toward the bottom — handled in _onScrollEnd.
    }
  }

  void _onScrollEnd(ScrollMetrics metrics) {
    // When the user finishes scrolling and the list is at the very bottom
    // (atEdge && pixels == 0 in a reverse list), clear the scrolled-up state.
    // minScrollExtent == 0 corresponds to the bottom in a reverse list.
    if (metrics.atEdge && metrics.pixels == metrics.minScrollExtent) {
      if (_isUserScrolledUp) {
        _isUserScrolledUp = false;
        _unreadMessageCount = 0;
        _controller.isUserScrolledUp = false;
        _controller.markMessagesAsReadIfAtBottom();
        setState(() {});
      }
    }
  }

  void _scrollToBottom({bool force = false, bool isNewMessage = false}) {
    if (_controller.messages.isEmpty) return;
    if (!force && _isUserScrolledUp) {
      if (isNewMessage) {
        setState(() { _unreadMessageCount++; });
      }
      return;
    }
    if (isNewMessage) {
      _controller.markMessagesAsReadIfAtBottom();
    }
    // In reverse mode, index 0 is the newest (bottom) message.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.messages.isEmpty) return;
      if (force) {
        _itemScrollController.jumpTo(index: 0, alignment: 0.0);
      } else {
        _itemScrollController.scrollTo(
          index: 0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _jumpToBottom() {
    _isUserScrolledUp = false;
    _unreadMessageCount = 0;
    _controller.isUserScrolledUp = false;
    _controller.markMessagesAsReadIfAtBottom();
    setState(() {});
    if (_controller.messages.isNotEmpty) {
      // In reverse mode, index 0 is the newest (bottom) message.
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

    setState(() { _controller.highlightedMessageId = messageId; });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() { _controller.highlightedMessageId = null; });
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
      setState(() { _showEmojiPicker = false; });
      _textFieldFocusNode.requestFocus();
    } else {
      _textFieldFocusNode.unfocus();
      setState(() { _showEmojiPicker = true; });
    }
  }

  void _onEmojiSelected(Category? category, Emoji emoji) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final cursorPos = selection.baseOffset;
    if (cursorPos < 0) {
      _messageController.text = text + emoji.emoji;
      _messageController.selection = TextSelection.collapsed(offset: _messageController.text.length);
    } else {
      final newText = text.substring(0, cursorPos) + emoji.emoji + text.substring(cursorPos);
      _messageController.text = newText;
      _messageController.selection = TextSelection.collapsed(offset: cursorPos + emoji.emoji.length);
    }
  }

  void _onBackspacePressed() {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final cursorPos = selection.baseOffset;
    if (cursorPos > 0 && text.isNotEmpty) {
      final newText = text.substring(0, cursorPos - 1) + text.substring(cursorPos);
      _messageController.text = newText;
      _messageController.selection = TextSelection.collapsed(offset: cursorPos - 1);
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
        final tempFile = File('${tempDir.path}/paste_${DateTime.now().millisecondsSinceEpoch}.png');
        await tempFile.writeAsBytes(imageBytes);
        await _addPendingAttachment(tempFile, isFromClipboard: true);
        return true;
      }
    } catch (e) {
      LoggerService().error('Error handling clipboard paste', tag: 'ChatScreen', error: e);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Attachments
  // ---------------------------------------------------------------------------

  Future<void> _addPendingAttachment(File file, {bool isFromClipboard = false}) async {
    if (_pendingQueue.isFull) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_maxAttachments(_pendingQueue.maxItems),
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
      LoggerService().error('Error staging attachment', tag: 'ChatScreen', error: e);
    }
  }

  void _removePendingAttachment(PendingAttachment att) {
    setState(() {
      _pendingQueue.remove(att);
    });
  }

  void _showAttachmentOptions() {
    LoggerService().debug('_showAttachmentOptions called, isDesktop=${LayoutUtils.isDesktopLayout(context)}', tag: 'ChatScreen');
    if (LayoutUtils.isDesktopLayout(context)) {
      _pickAndStageFile();
      return;
    }
    final l10n = AppLocalizations.of(context);
    LayoutUtils.showAdaptivePanel(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(l10n.chat_photoLibrary),
            onTap: () { Navigator.pop(context); _pickAndStageImage(); },
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: Text(l10n.chat_camera),
            onTap: () { Navigator.pop(context); _pickAndStageImage(); },
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: Text(l10n.chat_file),
            onTap: () { Navigator.pop(context); _pickAndStageFile(); },
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndStageFile() async {
    LoggerService().debug('_pickAndStageFile called', tag: 'ChatScreen');
    try {
      final file = await _controller.attachmentService.pickFile();
      LoggerService().debug('pickFile returned: $file', tag: 'ChatScreen');
      if (file == null) return;
      await _addPendingAttachment(file);
    } catch (e) {
      LoggerService().error('_pickAndStageFile error', tag: 'ChatScreen', error: e);
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
      try { await File(result.filePath).delete(); } catch (_) {}
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
        setState(() { _pendingQueue.clear(); });
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
    final remoteAgent = await _controller.localDatabaseService.getRemoteAgentById(widget.agentId!);
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
        final updated = await _controller.localDatabaseService.getRemoteAgentById(widget.agentId!);
        if (updated != null) {
          _controller.updateAgentInfo(updated.name, updated.avatar);
        }
        _checkAgentAudioSupport();
        _checkAgentImageSupport();
      }
    }
  }

  Future<void> _navigateToAgentDetailById(String agentId) async {
    final remoteAgent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
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
        final updated = await _controller.localDatabaseService.getRemoteAgentById(agentId);
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

  // ---------------------------------------------------------------------------
  // Session list
  // ---------------------------------------------------------------------------

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

  Future<void> _showSessionList() async {
    if (widget.agentId == null) return;
    try {
      final sessions = await _controller.chatService.getAgentSessions(agentId: widget.agentId!);
      if (!mounted) return;

      final content = SessionListPanel(
        sessions: sessions,
        currentChannelId: _controller.currentChannelId,
        controller: _controller,
        onNewSession: () => _controller.createNewSession(),
        onSwitchSession: (channelId) async {
          // Stay in the agent DM chat — group-bound sessions are view-only here.
          await _controller.localDatabaseService.touchChannelUpdatedAt(channelId);
          if (!mounted) return;
          if (widget.embedded) {
            widget.onSwitchChannel?.call(channelId);
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => ChatScreen(
                  agentId: widget.agentId,
                  agentName: _controller.agentName,
                  agentAvatar: _controller.agentAvatar,
                  channelId: channelId,
                ),
              ),
            );
          }
        },
        onBatchDelete: (ids) => _controller.batchDeleteSessions(ids, isGroup: false),
        onShowTraces: () {
          Navigator.pop(context);
          _showChannelTraces();
        },
      );

      if (LayoutUtils.isDesktopLayout(context)) {
        LayoutUtils.showRightDrawer(context: context, builder: (_) => content);
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: AppBar(title: Text(AppLocalizations.of(context).chat_sessionList), elevation: 1),
              body: content,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_loadSessionsFailed('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  Future<void> _showGroupSessionList() async {
    if (_controller.groupChannel == null) return;
    try {
      final parentGroupId = _controller.groupChannel!.groupFamilyId;
      final sessions = await _controller.chatService.getGroupSessions(parentGroupId: parentGroupId);
      if (!mounted) return;

      final content = GroupSessionListPanel(
        sessions: sessions,
        currentChannelId: _controller.currentChannelId,
        controller: _controller,
        onNewSession: () => _controller.createNewGroupSession(),
        onSwitchSession: (channelId) async {
          await _controller.localDatabaseService.touchChannelUpdatedAt(channelId);
          if (!mounted) return;
          if (widget.embedded) {
            widget.onSwitchChannel?.call(channelId);
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => ChatScreen(channelId: channelId),
              ),
            );
          }
        },
        onBatchDelete: (ids) => _controller.batchDeleteSessions(ids, isGroup: true),
        onShowTraces: () {
          Navigator.pop(context);
          _showChannelTraces();
        },
      );

      if (LayoutUtils.isDesktopLayout(context)) {
        LayoutUtils.showRightDrawer(context: context, builder: (_) => content);
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: AppBar(title: Text(AppLocalizations.of(context).chat_sessionList), elevation: 1),
              body: content,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).chat_loadGroupSessionsFailed('$e'),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // DM system prompt
  // ---------------------------------------------------------------------------

  Future<void> _showDmSystemPromptPanel() async {
    final l10n = AppLocalizations.of(context);
    final content = SystemPromptPanel(
      initialPrompt: _controller.dmSystemPrompt ?? '',
      onSave: (prompt) async {
        await _controller.updateDmSystemPrompt(prompt);
        if (mounted) {
          showTopToast(
            context,
            l10n.chat_systemPromptSaved,
            icon: Icons.check_circle,
            color: Colors.green,
          );
        }
      },
    );

    // Same presentation as session list: right drawer on desktop, full route on mobile.
    if (LayoutUtils.isDesktopLayout(context)) {
      await LayoutUtils.showRightDrawer(context: context, builder: (_) => content);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(AppLocalizations.of(context).chat_systemPromptTitle),
              elevation: 1,
            ),
            body: content,
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _showSearchDialog() async {
    List<String>? agentChannelIds;
    if (_controller.isGroupMode && _controller.currentChannelId != null) {
      agentChannelIds = [_controller.currentChannelId!];
    } else if (widget.agentId != null) {
      try {
        final channels = await _controller.localDatabaseService.getChannelsForAgent(widget.agentId!);
        agentChannelIds = channels.map((c) => c.id).toList();
      } catch (_) {}
    }

    if (!mounted) return;

    showShepawSearch(
      context: context,
      delegate: MessageSearchDelegate(
        searchService: _controller.searchService,
        channelIds: agentChannelIds,
        onResultTap: (message, channelId) {
          if (channelId != null && channelId != _controller.currentChannelId) {
            if (widget.embedded) {
              widget.onSwitchChannel?.call(
                channelId,
                highlightMessageId: message.id,
              );
            } else {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => ChatScreen(
                    agentId: widget.agentId,
                    agentName: _controller.agentName,
                    agentAvatar: _controller.agentAvatar,
                    channelId: channelId,
                    highlightMessageId: message.id,
                    showBackButton: true,
                  ),
                ),
              );
            }
          } else {
            _scrollToMessage(message.id);
          }
        },
      ),
    );
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
    final descController = TextEditingController(text: channel?.description ?? '');
    final systemPromptController = TextEditingController(text: channel?.systemPrompt ?? '');
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Expanded(child: Text(panelL10n.chat_editGroupInfo, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
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
                    TextField(controller: nameController, decoration: InputDecoration(labelText: panelL10n.chat_groupName, border: const OutlineInputBorder()), autofocus: true),
                    const SizedBox(height: 16),
                    TextField(controller: descController, decoration: InputDecoration(labelText: panelL10n.chat_groupDescriptionOptional, border: const OutlineInputBorder()), maxLines: 2),
                    const SizedBox(height: 16),
                    TextField(controller: systemPromptController, decoration: InputDecoration(labelText: panelL10n.chat_groupSystemPrompt, hintText: panelL10n.chat_groupSystemPromptHint, border: const OutlineInputBorder()), maxLines: 4),
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
                          setDrawerState(() { selectedMentionMode = value; });
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        selectedMentionMode == 'allMembers'
                            ? panelL10n.chat_mentionModeAllMembersDesc
                            : panelL10n.chat_mentionModeAdminOnlyDesc,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
                        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(panelL10n.common_cancel)),
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
                            final maxRoundsText = maxRoundsController.text.trim();
                            int? maxLoopRounds;
                            if (maxRoundsText.isNotEmpty) {
                              maxLoopRounds = int.tryParse(maxRoundsText);
                              if (maxLoopRounds == null || maxLoopRounds < 1) {
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
                            final newSystemPrompt = systemPromptController.text.trim();
                            final updated = Channel(
                              id: old.id, name: newName, type: old.type, members: old.members,
                              createdBy: old.createdBy, createdAt: old.createdAt,
                              description: descController.text.trim().isNotEmpty ? descController.text.trim() : null,
                              systemPrompt: newSystemPrompt.isNotEmpty ? newSystemPrompt : null,
                              avatar: old.avatar, isPrivate: old.isPrivate,
                              maxLoopRounds: maxLoopRounds,
                              mentionMode: selectedMentionMode,
                              parentGroupId: old.parentGroupId,
                            );
                            await _controller.localDatabaseService.updateChannel(updated);
                            await GroupMemberSessionService(_controller.localDatabaseService)
                                .syncTitlesForGroupFamily(
                              parentGroupId: updated.groupFamilyId,
                              groupName: newName,
                            );
                            if (mounted) { _controller.updateGroupChannelInfo(updated); }
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
      onSaveGroupBio: (agent, bio) => _controller.saveMemberGroupBio(agent, bio),
      onChangeAdmin: (agent) async {
        if (agent.id == _controller.groupAdminAgentId) return;
        final parentGroupId = _controller.groupChannel?.groupFamilyId ?? _controller.currentChannelId!;
        final sessions = await _controller.localDatabaseService.getGroupSessions(parentGroupId);
        for (final session in sessions) {
          if (_controller.groupAdminAgentId != null) {
            await _controller.localDatabaseService.updateChannelMemberRole(session.id, _controller.groupAdminAgentId!, 'member');
          }
          await _controller.localDatabaseService.updateChannelMemberRole(session.id, agent.id, 'admin');
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
      await LayoutUtils.showRightDrawer(context: context, builder: (_) => content);
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
      );
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
    final allAgents = await _controller.localDatabaseService.getAllRemoteAgents();
    final currentIds = _controller.groupAgents.map((a) => a.id).toSet();
    final available = allAgents.where((a) => !currentIds.contains(a.id)).toList();

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
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.chat_historyIgnore)),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.chat_historyApprove)),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _showOsToolConfirmation(String toolName, Map<String, dynamic> args, dynamic risk) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('OS Tool: $toolName'),
        content: Text('Allow execution?\nArgs: $args'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Deny')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Allow')),
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

  void _showChatMenu({BuildContext? anchorContext}) {
    final c = _controller;
    if (!LayoutUtils.isDesktopLayout(context) && !widget.embedded) {
      _scaffoldKey.currentState?.openEndDrawer();
      return;
    }
    if (c.isGroupMode) {
      ChatMenuHelper.showGroupMenu(
        context,
        anchorContext: anchorContext,
        onEditGroup: _editGroupInfo,
        onShowMembers: _showGroupMembersPanel,
        onSearch: _showSearchDialog,
        onWorkflow: _showGroupWorkflow,
      );
    } else {
      ChatMenuHelper.showAgentMenu(
        context,
        anchorContext: anchorContext,
        onReset: () {
          _messageController.text = '/reset';
          _sendMessage();
        },
        onViewDetails: _navigateToAgentDetail,
        onEdit: _navigateToAgentDetailForEdit,
        onSearch: _showSearchDialog,
        onCustomSystemPrompt:
            c.isPeerAgent ? null : _showDmSystemPromptPanel,
        onWorkflow: c.dmWorkflowEnabled ? _showGroupWorkflow : null,
      );
    }
  }

  Widget? _buildMobileEndDrawer(BuildContext context) {
    final c = _controller;
    final l10n = AppLocalizations.of(context);
    final title = c.isGroupMode
        ? (c.groupChannel?.name ?? l10n.chat_editGroupInfo)
        : (SheService.isSheIdentity(c.agentId)
            ? SheService.resolveDisplayName(c.agentName, l10n.she_name)
            : (c.agentName ?? 'AI Agent'));

    return ChatMobileMenuDrawer(
      isGroupMode: c.isGroupMode,
      title: title,
      onResetSession: () {
        _messageController.text = '/reset';
        _sendMessage();
      },
      onViewDetails: _navigateToAgentDetail,
      onEditAgent: _navigateToAgentDetailForEdit,
      onSearch: _showSearchDialog,
      onCustomSystemPrompt:
          c.isPeerAgent ? null : _showDmSystemPromptPanel,
      onEditGroup: _editGroupInfo,
      onShowMembers: _showGroupMembersPanel,
      onWorkflow: (c.isGroupMode || c.dmWorkflowEnabled) ? _showGroupWorkflow : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = _controller;
    final isMobileLayout = !LayoutUtils.isDesktopLayout(context) && !widget.embedded;

    return Scaffold(
        key: _scaffoldKey,
        endDrawerEnableOpenDragGesture: false,
        endDrawer: isMobileLayout ? _buildMobileEndDrawer(context) : null,
        appBar: AppBar(
        elevation: 1,
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.showBackButton && widget.onClose != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onClose,
              )
            : null,
        title: c.isGroupMode
            ? ChatGroupAppBarTitle(
                groupChannel: c.groupChannel,
                groupAgents: c.groupAgents,
                isProcessing: c.isProcessing,
                respondingAgentNames: c.respondingAgentNames,
                mentionOnlyMode: c.mentionOnlyMode,
                currentChannelId: c.currentChannelId,
                onAvatarTap: _navigateToGroupDetail,
                onStopGenerating: c.isProcessing
                    ? () => c.stopGroupStreaming()
                    : null,
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
                onStopGenerating: c.isProcessing
                    ? () => c.stopStreaming()
                    : null,
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            tooltip: AppLocalizations.of(context).chat_sessionList,
            onPressed: c.isGroupMode ? _showGroupSessionList : _showSessionList,
          ),
          Builder(
            builder: (moreButtonContext) => IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showChatMenu(anchorContext: moreButtonContext),
            ),
          ),
        ],
        ),
        body: Column(
          children: [
            // She config banner — shown when She has no LLM model configured
            if (_sheNeedsConfig) _buildSheConfigBanner(),

            // Message list
          Expanded(
            child: Stack(
              children: [
                c.messages.isEmpty && !c.isLoading
                    ? (_sheNeedsConfig ? _buildSheWelcomeState() : _buildEmptyState())
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
                          groupStreamingMessageIds: c.groupStreamingMessageIds,
                          isGroupMode: c.isGroupMode,
                          channelId: c.currentChannelId,
                          itemScrollController: _itemScrollController,
                          itemPositionsListener: _itemPositionsListener,
                          onStopStreaming: () => c.isGroupMode
                              ? c.stopCurrentGroupMessageOnly()
                              : c.stopCurrentMessageOnly(),
                          onActionSelected: (msg, cid, aid, alabel, {confirmationContext}) {
                            c.handleActionSelected(msg, cid, aid, alabel, confirmationContext: confirmationContext);
                          },
                          onSingleSelectSubmitted: (msg, sid, oid, olabel) {
                            c.handleSingleSelectSubmitted(msg, sid, oid, olabel);
                          },
                          onMultiSelectSubmitted: (msg, sid, oids, summary) {
                            c.handleMultiSelectSubmitted(msg, sid, oids, summary);
                          },
                          onFileUploadSubmitted: (msg, uid, files, summary) {
                            c.handleFileUploadSubmitted(msg, uid, files, summary);
                          },
                          onFormSubmitted: (msg, fid, values, summary) {
                            c.handleFormSubmitted(msg, fid, values, summary);
                          },
                          onPlanApprovalResponded: (msg, approved, {feedback, skippedTaskIds}) =>
                              c.handlePlanApprovalResponded(msg, approved,
                                  feedback: feedback, skippedTaskIds: skippedTaskIds),
                          onReply: (msg) => c.startReply(msg),
                          onRollback: (msg) => c.rollbackMessage(msg),
                          onRollbackReEdit: (msg, {bool reEdit = false}) => c.rollbackMessage(msg, reEdit: reEdit),
                          onDelete: (msg) => c.deleteMessage(msg),
                          onAgentAvatarTap: _navigateToAgentDetailById,
                          onScrollToMessage: _scrollToMessage,
                          highlightedMessageId: c.highlightedMessageId,
                          onViewTrace: (message) {
                            final traceId = message.metadata?['trace_id'] as String?;
                            if (traceId != null) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TraceDetailScreen(traceId: traceId),
                                ),
                              );
                            }
                          },
                          agentAvatarMap: c.isGroupMode
                              ? {
                                  for (final a in c.groupAgents)
                                    if (a.avatar.isNotEmpty)
                                      a.id: a.avatar,
                                }
                              : (c.agentId != null && c.agentAvatar != null && c.agentAvatar!.isNotEmpty
                                  ? {c.agentId!: c.agentAvatar!}
                                  : const {}),
                          isAgentOffline: !c.isAgentOnline,
                        ),
                      ),
                if (_isUserScrolledUp)
                  Positioned(
                    right: 16,
                    bottom: 12,
                    child: _buildScrollToBottomButton(),
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
                : (c.chatService.getACPConnection(c.agentId!)?.slashCommands ??
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
              final snap = c.chatService.getSlashCommandsSnapshot(c.agentId!);
              if (snap.isNotEmpty) return snap;
              // Peer agents have no ACP connection — use the prefetched
              // slash-command cache from PeerAgentClientService.
              return PeerAgentClientService.instance.getSlashCommands(c.agentId!);
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
                  bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
                ),
              ),
            ),
          ],
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
              Icon(Icons.groups_outlined, size: 22, color: Colors.teal.shade700),
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
                    Text(openLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
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
              Icon(Icons.pets_outlined, size: 22, color: Colors.orange.shade700),
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
    final agent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final needsConfig = agent != null && !agent.isLocal;
    if (needsConfig != _sheNeedsConfig) {
      setState(() => _sheNeedsConfig = needsConfig);
    }
  }

  Future<void> _checkAgentImageSupport() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final supportsImage = agent != null && agent.supportsModality(ModalityType.image);
    if (supportsImage != _agentSupportsImage) {
      setState(() => _agentSupportsImage = supportsImage);
    }
  }

  /// Check whether the current agent's LLM configuration supports audio input.
  Future<void> _checkAgentAudioSupport() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (!mounted) return;
    final supportsAudio = agent != null && agent.supportsModality(ModalityType.audio);
    if (supportsAudio != _agentSupportsAudio) {
      setState(() => _agentSupportsAudio = supportsAudio);
    }
  }

  /// On entry to a peer agent chat, incrementally sync remote sessions + dirty
  /// history — but only after the user has decided whether to sync.
  ///
  /// Preference key `peer_sync_disabled_$agentId`:
  /// - `null` (undecided): prompt once when there are unsynced remote sessions
  /// - `false` (enabled): auto-sync silently; changeable in agent settings
  /// - `true` (disabled): skip; changeable in agent settings
  Future<void> _maybeSyncPeerAgent() async {
    final agentId = widget.agentId;
    if (agentId == null) return;
    final agent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (agent == null || !agent.isPeerAgent) return;
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (peerId == null || remoteAgentId == null) return;

    final prefs = await SharedPreferences.getInstance();
    final syncDisabled = prefs.getBool('peer_sync_disabled_$agentId');
    if (syncDisabled == true) return;

    // Need a live connection to enumerate remote sessions; retry on a later
    // open if the peer isn't connected yet.
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) return;

    // Undecided — prompt only when there are remote sessions not yet mirrored.
    var showToastOnFirstLink = false;
    if (syncDisabled == null) {
      final sessions = await PeerAgentClientService.instance.fetchSessions(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
      );
      if (!mounted || sessions.isEmpty) return;

      final localChannels =
          await _controller.localDatabaseService.getChannelsForAgent(agentId);
      final localRemoteIds = localChannels
          .map((c) => remoteSessionIdFromChannelId(c.id))
          .whereType<String>()
          .toSet();
      final missing =
          sessions.where((s) => !localRemoteIds.contains(s.sessionId)).toList();

      if (missing.isNotEmpty) {
        final choice =
            await _showPeerSessionSyncDialog(agent.name, missing.length);
        if (!mounted || choice == null) return; // dismissed → ask again next time
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
    final prioritizeCurrent =
        channelId != null && channelId.startsWith(kSyncedPeerSessionPrefix);
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
        prioritizeChannelId: prioritizeCurrent ? channelId : null,
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
    final agent = await _controller.localDatabaseService.getRemoteAgentById(agentId);
    if (agent == null || !agent.isPeerAgent) return;
    await PeerAgentClientService.instance.ensureCommandsForLocalAgent(agentId);
  }

  Future<_PeerSyncChoice?> _showPeerSessionSyncDialog(String agentName, int count) async {
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
              const Icon(Icons.settings_suggest_outlined, size: 20, color: Colors.orange),
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
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: Colors.orange.shade600),
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
                      const Text('🌸', style: TextStyle(fontSize: 72), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context).she_name,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
                        label: Text(AppLocalizations.of(context).chat_sheConfigModelCta),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.pink.shade400,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
            child: _controller.agentAvatar != null && _controller.agentAvatar!.length > 2
                ? AvatarImage(
                    avatar: _controller.agentAvatar!,
                    size: 80,
                    borderRadius: 20,
                    fallback: Text(
                      _controller.agentName?.isNotEmpty == true ? _controller.agentName![0] : 'A',
                      style: const TextStyle(fontSize: 56),
                    ),
                  )
                : Text(
                    _controller.agentAvatar ??
                    (_controller.agentName?.isNotEmpty == true ? _controller.agentName![0] : 'A'),
                    style: const TextStyle(fontSize: 56),
                  ),
          ),
          const SizedBox(height: 16),
          Text(_controller.agentName ?? 'AI Agent', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Send a message to start chatting', style: TextStyle(color: Colors.grey[600])),
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
            BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unreadMessageCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Theme.of(context).primaryColor, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  _unreadMessageCount > 99 ? '99+' : '$_unreadMessageCount',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
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
        border: const Border(top: BorderSide(color: AppColors.primaryLight, width: 1)),
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
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.primaryDark),
                ),
                Text(preview, style: const TextStyle(fontSize: 11, color: AppColors.primary), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          GestureDetector(
            onTap: () { setState(() { _controller.messageQueue.clear(); }); },
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('Clear', style: TextStyle(fontSize: 12, color: Colors.red[400], fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }
}
