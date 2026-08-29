import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../models/message.dart';
import '../../widgets/message_bubble.dart';
import '../../utils/message_utils.dart';
import '../../services/she_service.dart';
import '../../services/message_collapse_preference.dart';
import '../../service_locator.dart';
import 'message_long_press_handler.dart';

/// The scrollable message list for the chat screen.
///
/// Handles:
/// - Date separators
/// - Image group collapsing
/// - Quote/reply display
/// - Highlight animation
/// - Long-press context menu
/// - Group-chat message body collapse (persisted per channel)
class ChatMessageList extends StatefulWidget {
  final List<Message> messages;
  final Map<String, Message> messageIdMap;
  final String? streamingMessageId;
  final Set<String> groupStreamingMessageIds;
  final bool isGroupMode;

  /// Channel id used to scope persisted body-collapse preferences.
  final String? channelId;

  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  /// 停止按钮回调：传入被停止消息的 id（群聊用于定位到单个 agent）。
  final void Function(String messageId)? onStopStreaming;
  final void Function(Message message, String confirmationId, String actionId, String actionLabel, {String? confirmationContext}) onActionSelected;
  final void Function(Message message, String selectId, String optionId, String optionLabel) onSingleSelectSubmitted;
  final void Function(Message message, String selectId, List<String> optionIds, String summary) onMultiSelectSubmitted;
  final void Function(Message message, String uploadId, List<Map<String, dynamic>> files, String summary) onFileUploadSubmitted;
  final void Function(Message message, String formId, Map<String, dynamic> values, String summary) onFormSubmitted;
  final void Function(Message message, bool approved, {String? feedback, List<String>? skippedTaskIds})? onPlanApprovalResponded;
  final void Function(Message message) onReply;
  final void Function(Message message) onRollback;
  final void Function(Message message, {bool reEdit}) onRollbackReEdit;
  final void Function(Message message) onDelete;
  final void Function(String agentId) onAgentAvatarTap;
  final void Function(String messageId) onScrollToMessage;
  final String? highlightedMessageId;
  final void Function(Message message)? onViewTrace;

  /// sender id → avatar（emoji / 本地路径 / URL）的映射表。
  /// DM 模式传 `{agentId: agentAvatar}`；群组模式传所有成员的头像映射。
  /// 缺失的 sender 退回 [MessageBubble] 内部默认逻辑。
  final Map<String, String> agentAvatarMap;

  /// When `true`, action-confirmation cards render an "offline" hint so
  /// users know tapping Allow/Deny will first need a reconnect. Threaded
  /// down into each [MessageBubble].
  final bool isAgentOffline;

  /// Default workspace roots (DM agent / group fallback) for relative links.
  final List<String> defaultWorkspaceUris;

  /// Per-sender workspace roots so group replies open the right cwd.
  final Map<String, List<String>> workspaceUrisByAgentId;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.messageIdMap,
    this.streamingMessageId,
    this.groupStreamingMessageIds = const {},
    required this.isGroupMode,
    this.channelId,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.onStopStreaming,
    required this.onActionSelected,
    required this.onSingleSelectSubmitted,
    required this.onMultiSelectSubmitted,
    required this.onFileUploadSubmitted,
    required this.onFormSubmitted,
    this.onPlanApprovalResponded,
    required this.onReply,
    required this.onRollback,
    required this.onRollbackReEdit,
    required this.onDelete,
    required this.onAgentAvatarTap,
    required this.onScrollToMessage,
    this.highlightedMessageId,
    this.onViewTrace,
    this.agentAvatarMap = const {},
    this.isAgentOffline = false,
    this.defaultWorkspaceUris = const [],
    this.workspaceUrisByAgentId = const {},
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  final GlobalKey _viewportKey = GlobalKey();
  final MessageCollapsePreference _collapsePreference =
      getIt<MessageCollapsePreference>();

  @override
  void initState() {
    super.initState();
    _collapsePreference.addListener(_onCollapsePreferenceChanged);
    _loadCollapsePreference();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId ||
        oldWidget.isGroupMode != widget.isGroupMode) {
      _loadCollapsePreference();
    } else if (widget.isGroupMode &&
        oldWidget.messages.length != widget.messages.length) {
      _pruneCollapsedIds();
    }
  }

  @override
  void dispose() {
    _collapsePreference.removeListener(_onCollapsePreferenceChanged);
    super.dispose();
  }

  void _onCollapsePreferenceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCollapsePreference() async {
    final channelId = widget.channelId;
    if (!widget.isGroupMode || channelId == null || channelId.isEmpty) {
      return;
    }
    await _collapsePreference.loadForChannel(channelId);
    await _pruneCollapsedIds();
  }

  Future<void> _pruneCollapsedIds() async {
    if (!widget.isGroupMode) return;
    await _collapsePreference.pruneTo(widget.messages.map((m) => m.id));
  }

  // --- 图片分组缓存 -----------------------------------------------------------
  // 每次 build（流式期间即每帧）都重算两趟 O(n) 的图片索引/分组。结果只
  // 依赖 messages 的"结构"，流式 chunk 只原地改最后一条的 content，不影
  // 响分组，因此以 (身份, 长度, 首尾消息签名) 为键缓存，失配才重算。

  List<Message>? _cachedGroupMessages;
  List<Message>? _cachedAllImageMessages;
  Map<String, int>? _cachedImageIndexMap;
  Map<int, List<Message>>? _cachedImageGroupMap;
  Set<int>? _cachedMergedIndices;

  String? _messageGroupKey(List<Message> messages) {
    if (messages.isEmpty) return '';
    final first = messages.first;
    final last = messages.last;
    return '${identityHashCode(messages)}|${messages.length}'
        '|${first.id}|${first.type.index}'
        '|${last.id}|${last.type.index}';
  }

  void _invalidateImageGroupCacheIfNeeded(List<Message> messages) {
    final key = _messageGroupKey(messages);
    if (_cachedGroupMessages != null &&
        _cachedAllImageMessages != null &&
        _cachedImageIndexMap != null &&
        _cachedImageGroupMap != null &&
        _cachedMergedIndices != null &&
        key == _messageGroupKey(_cachedGroupMessages!)) {
      return;
    }
    final allImageMessages = <Message>[];
    final imageIndexMap = <String, int>{};
    for (final msg in messages) {
      if (msg.type == MessageType.image) {
        imageIndexMap[msg.id] = allImageMessages.length;
        allImageMessages.add(msg);
      }
    }

    // Pre-compute consecutive image groups from the same sender
    final imageGroupMap = <int, List<Message>>{};
    final mergedIndices = <int>{};

    int i = 0;
    while (i < messages.length) {
      final msg = messages[i];
      if (msg.type == MessageType.image) {
        final group = <Message>[msg];
        int j = i + 1;
        while (j < messages.length &&
            messages[j].type == MessageType.image &&
            messages[j].from.id == msg.from.id) {
          group.add(messages[j]);
          j++;
        }
        if (group.length > 1) {
          imageGroupMap[i] = group;
          for (int k = i + 1; k < j; k++) {
            mergedIndices.add(k);
          }
        }
        i = j;
      } else {
        i++;
      }
    }

    _cachedGroupMessages = List.unmodifiable(messages);
    _cachedAllImageMessages = allImageMessages;
    _cachedImageIndexMap = imageIndexMap;
    _cachedImageGroupMap = imageGroupMap;
    _cachedMergedIndices = mergedIndices;
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final isGroupMode = widget.isGroupMode;
    final messageIdMap = widget.messageIdMap;
    final streamingMessageId = widget.streamingMessageId;
    final groupStreamingMessageIds = widget.groupStreamingMessageIds;
    final agentAvatarMap = widget.agentAvatarMap;
    final isAgentOffline = widget.isAgentOffline;
    final highlightedMessageId = widget.highlightedMessageId;

    _invalidateImageGroupCacheIfNeeded(messages);
    final allImageMessages = _cachedAllImageMessages!;
    final imageIndexMap = _cachedImageIndexMap!;
    final imageGroupMap = _cachedImageGroupMap!;
    final mergedIndices = _cachedMergedIndices!;

    return KeyedSubtree(
      key: _viewportKey,
      child: ScrollablePositionedList.builder(
        reverse: true,
        itemScrollController: widget.itemScrollController,
        itemPositionsListener: widget.itemPositionsListener,
        padding: const EdgeInsets.all(16),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          // In reverse mode, index 0 is the newest (last) message.
          // Map back to the chronological index.
          final originalIndex = messages.length - 1 - index;
          final message = messages[originalIndex];
          // She 以 userId 身份发送的消息，sender_type 虽为 'user' 但不应视为"我的消息"
          final isMyMessage = message.from.type == 'user'
              && message.from.id != SheService.sheId;

          final previousMessage =
              originalIndex > 0 ? messages[originalIndex - 1] : null;
          final showDateSeparator = MessageUtils.shouldShowDateSeparator(
            previousMessage,
            message,
          );

          if (mergedIndices.contains(originalIndex)) {
            if (showDateSeparator) {
              return _buildDateSeparator(context, message.dateTime);
            }
            return const SizedBox.shrink();
          }

          Message? quotedMessage;
          final isReplyToPrevious = message.replyTo != null &&
              previousMessage != null &&
              previousMessage.id == message.replyTo;
          if (message.replyTo != null && !isReplyToPrevious) {
            quotedMessage = messageIdMap[message.replyTo];
          }

          final isHighlighted = highlightedMessageId == message.id;
          final isStreaming = message.id == streamingMessageId ||
              groupStreamingMessageIds.contains(message.id);

          final collapseSenderChrome = MessageUtils.shouldCollapseSenderChrome(
            isGroupMode: isGroupMode,
            previousMessage: previousMessage,
            currentMessage: message,
            showDateSeparator: showDateSeparator,
          );
          final showSenderName = MessageUtils.shouldShowSenderName(
            isGroupMode: isGroupMode,
            isMyMessage: isMyMessage,
            collapseSenderChrome: collapseSenderChrome,
          );
          final showAvatar = MessageUtils.shouldShowAvatar(
            isGroupMode: isGroupMode,
            collapseSenderChrome: collapseSenderChrome,
          );
          final reserveAvatarSpace = MessageUtils.shouldReserveAvatarSpace(
            isGroupMode: isGroupMode,
            collapseSenderChrome: collapseSenderChrome,
          );
          // Sticky for every non-my group message (each message shows its own
          // author chrome — consecutive same-author collapse is disabled).
          final stickySenderName = isGroupMode && !isMyMessage;

          return RepaintBoundary(
            key: ValueKey(message.id),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showDateSeparator)
                  _buildDateSeparator(context, message.dateTime),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: isHighlighted
                        ? Theme.of(context).primaryColor.withOpacity(0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: MessageLongPressHandler(
                    message: message,
                    isGroupMode: isGroupMode,
                    hasSelectableText: message.type == MessageType.text &&
                        !message.isSystemMessage,
                    onReply: () => widget.onReply(message),
                    onRollback: () => widget.onRollback(message),
                    onReEdit: () =>
                        widget.onRollbackReEdit(message, reEdit: true),
                    onDelete: () => widget.onDelete(message),
                    onViewTrace: (message.from.isAgent &&
                            message.metadata?['trace_id'] != null)
                        ? () => widget.onViewTrace?.call(message)
                        : null,
                    builder: ({
                      required textSelectionEnabled,
                      required menuActive,
                      required selectionAreaKey,
                      required selectionFocusNode,
                      required onSelectionChanged,
                    }) =>
                        MessageBubble(
                      message: message,
                      isMyMessage: isMyMessage,
                      isStreaming: isStreaming,
                      textSelectionEnabled: textSelectionEnabled,
                      isContextMenuActive: menuActive,
                      selectionAreaKey: selectionAreaKey,
                      selectionFocusNode: selectionFocusNode,
                      onSelectionChanged: onSelectionChanged,
                      showSenderName: showSenderName,
                      showAvatar: showAvatar,
                      reserveAvatarSpace: reserveAvatarSpace,
                      stickySenderName: stickySenderName,
                      // sticky 偏移信号由组件内部的 ScrollPosition 监听提
                      // 供（带 0.5px 阈值去重），不再挂全局 itemPositions
                      // ——之前两份信号叠加，滚动时每个可见气泡每帧
                      // markNeedsPaint。
                      stickyViewportKey: _viewportKey,
                      bodyCollapsed: isGroupMode &&
                          !isMyMessage &&
                          _collapsePreference.isCollapsed(message.id),
                      onToggleBodyCollapse: isGroupMode && !isMyMessage
                          ? () => _collapsePreference.toggle(message.id)
                          : null,
                      onStop: (message.id == streamingMessageId ||
                              groupStreamingMessageIds.contains(message.id))
                          ? () => widget.onStopStreaming?.call(message.id)
                          : null,
                      onActionSelected:
                          (confirmationId, actionId, actionLabel) {
                        final confirmationContext = (message.metadata?[
                                    'action_confirmation']
                                as Map<String, dynamic>?)?[
                            'confirmation_context'] as String?;
                        widget.onActionSelected(
                            message, confirmationId, actionId, actionLabel,
                            confirmationContext: confirmationContext);
                      },
                      onSingleSelectSubmitted:
                          (selectId, optionId, optionLabel) {
                        widget.onSingleSelectSubmitted(
                            message, selectId, optionId, optionLabel);
                      },
                      onMultiSelectSubmitted: (selectId, optionIds, summary) {
                        widget.onMultiSelectSubmitted(
                            message, selectId, optionIds, summary);
                      },
                      onFileUploadSubmitted: (uploadId, files, summary) {
                        widget.onFileUploadSubmitted(
                            message, uploadId, files, summary);
                      },
                      onFormSubmitted: (formId, values, summary) {
                        widget.onFormSubmitted(
                            message, formId, values, summary);
                      },
                      onPlanApprovalResponded:
                          widget.onPlanApprovalResponded != null
                              ? (approved, {feedback, skippedTaskIds}) =>
                                  widget.onPlanApprovalResponded!(
                                      message, approved,
                                      feedback: feedback,
                                      skippedTaskIds: skippedTaskIds)
                              : null,
                      quotedMessage: quotedMessage,
                      showQuote: !isReplyToPrevious,
                      onQuoteTap: message.replyTo != null
                          ? () => widget.onScrollToMessage(message.replyTo!)
                          : null,
                      allImageMessages: allImageMessages,
                      imageIndex: imageIndexMap[message.id] ?? 0,
                      imageIndexMap: imageIndexMap,
                      groupedImageMessages: imageGroupMap[originalIndex],
                      onAvatarTap: message.from.isAgent
                          ? () => widget.onAgentAvatarTap(message.from.id)
                          : null,
                      senderAvatar: agentAvatarMap[message.from.id],
                      isAgentOffline: isAgentOffline,
                      workspaceUris: message.from.isAgent
                          ? (widget.workspaceUrisByAgentId[message.from.id] ??
                              widget.defaultWorkspaceUris)
                          : widget.defaultWorkspaceUris,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDateSeparator(BuildContext context, DateTime date) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          MessageUtils.getDateDisplayText(date),
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
