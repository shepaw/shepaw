import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../models/message.dart';
import '../../widgets/message_bubble.dart';
import '../../utils/message_utils.dart';
import '../../services/she_service.dart';
import '../../services/messaging/chat_history_content.dart';
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
  final void Function(Message message, String? selectedText) onReply;
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

  /// 流式 chunk 只通知正在输出的气泡，不重建整列。
  final Listenable streamingListenable;

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
    required this.streamingListenable,
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
  // 流式期间列表每帧重建，但分组只依赖消息结构。结构键与展示顺序缓存
  // 相同：内容增长不改 id / 类型，失配才重算。

  final DisplayOrderMemo _displayOrder = DisplayOrderMemo();
  String? _imageGroupKey;
  List<Message>? _cachedAllImageMessages;
  Map<String, int>? _cachedImageIndexMap;
  Map<int, List<Message>>? _cachedImageGroupMap;
  Set<int>? _cachedMergedIndices;

  void _invalidateImageGroupCacheIfNeeded(
    List<Message> messages,
    String structuralKey,
  ) {
    if (_imageGroupKey == structuralKey &&
        _cachedAllImageMessages != null &&
        _cachedImageIndexMap != null &&
        _cachedImageGroupMap != null &&
        _cachedMergedIndices != null) {
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

    _imageGroupKey = structuralKey;
    _cachedAllImageMessages = allImageMessages;
    _cachedImageIndexMap = imageIndexMap;
    _cachedImageGroupMap = imageGroupMap;
    _cachedMergedIndices = mergedIndices;
  }

  @override
  Widget build(BuildContext context) {
    final streamingMessageId = widget.streamingMessageId;
    final groupStreamingMessageIds = widget.groupStreamingMessageIds;
    // 时间戳异常（重连续传占位、peer 历史回灌）会把「正在回复」的气泡排到
    // 被回复消息之前甚至整列最上方——展示前先按因果关系修正顺序。
    // 流式 chunk 不改结构，命中缓存时不再重走回复链。
    final messages = _displayOrder.apply(
      widget.messages,
      streamingIds: <String>{
        if (streamingMessageId != null) streamingMessageId,
        ...groupStreamingMessageIds,
      },
    );
    final isGroupMode = widget.isGroupMode;
    final messageIdMap = widget.messageIdMap;
    final agentAvatarMap = widget.agentAvatarMap;
    final isAgentOffline = widget.isAgentOffline;
    final highlightedMessageId = widget.highlightedMessageId;

    _invalidateImageGroupCacheIfNeeded(
      messages,
      _displayOrder.structuralKey ?? '',
    );
    final allImageMessages = _cachedAllImageMessages!;
    final imageIndexMap = _cachedImageIndexMap!;
    final imageGroupMap = _cachedImageGroupMap!;
    final mergedIndices = _cachedMergedIndices!;
    final defaultExpandedMessageId = isGroupMode
        ? MessageUtils.defaultExpandedGroupMessageId(messages)
        : null;

    return KeyedSubtree(
      key: _viewportKey,
      child: ScrollablePositionedList.builder(
        reverse: true,
        itemScrollController: widget.itemScrollController,
        itemPositionsListener: widget.itemPositionsListener,
        padding: const EdgeInsets.all(16),
        // 大约一屏。滑出视口的气泡保留已解析的 Markdown，翻历史时不用重解析。
        minCacheExtent: MediaQuery.sizeOf(context).height,
        itemCount: messages.length,
        itemBuilder: (context, index) {
          // In reverse mode, index 0 is the newest (last) message.
          // Map back to the chronological index.
          final originalIndex = messages.length - 1 - index;
          final message = messages[originalIndex];
          if (!ChatHistoryContent.shouldDisplayInChat(message)) {
            return const SizedBox.shrink();
          }
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
          final bodyCollapsed = isGroupMode &&
              !isMyMessage &&
              _collapsePreference.isCollapsed(
                message.id,
                defaultExpandedMessageId: defaultExpandedMessageId,
              );
          final groupedImages = imageGroupMap[originalIndex];
          final senderAvatar = agentAvatarMap[message.from.id];
          final workspaceUris = message.from.isAgent
              ? (widget.workspaceUrisByAgentId[message.from.id] ??
                  widget.defaultWorkspaceUris)
              : widget.defaultWorkspaceUris;
          // 已结束的气泡在整列重建时复用子树。流式 chunk 不重建整列，
          // 正在输出的那条另走 [_LiveMessageTile]。
          final stamp = (
            message,
            isStreaming,
            isHighlighted,
            bodyCollapsed,
            showDateSeparator,
            isAgentOffline,
            quotedMessage,
            showSenderName,
            showAvatar,
            reserveAvatarSpace,
            stickySenderName,
            senderAvatar,
            allImageMessages,
            groupedImages,
            imageIndexMap,
            workspaceUris,
          );
          Widget buildTile(BuildContext context, Message live) {
            return RepaintBoundary(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showDateSeparator)
                  _buildDateSeparator(context, live.dateTime),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: isHighlighted
                        ? Theme.of(context).primaryColor.withOpacity(0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: MessageLongPressHandler(
                    message: live,
                    isGroupMode: isGroupMode,
                    hasSelectableText: live.type == MessageType.text &&
                        !live.isSystemMessage,
                    onReply: (selectedText) =>
                        widget.onReply(live, selectedText),
                    onRollback: () => widget.onRollback(live),
                    onReEdit: () =>
                        widget.onRollbackReEdit(live, reEdit: true),
                    onDelete: () => widget.onDelete(live),
                    onViewTrace: (live.from.isAgent &&
                            live.metadata?['trace_id'] != null)
                        ? () => widget.onViewTrace?.call(live)
                        : null,
                    builder: ({
                      required textSelectionEnabled,
                      required menuActive,
                      required selectionAreaKey,
                      required selectionFocusNode,
                      required onSelectionChanged,
                    }) =>
                        MessageBubble(
                      message: live,
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
                      // sticky 偏移由组件内部的 ScrollPosition 在同帧 paint
                      // 中计算；不要再挂全局 itemPositions，避免双信号。
                      stickyViewportKey: _viewportKey,
                      bodyCollapsed: bodyCollapsed,
                      onToggleBodyCollapse: isGroupMode && !isMyMessage
                          ? () => _collapsePreference.toggle(
                                live.id,
                                defaultExpandedMessageId:
                                    defaultExpandedMessageId,
                              )
                          : null,
                      onStop: (live.id == streamingMessageId ||
                              groupStreamingMessageIds.contains(live.id))
                          ? () => widget.onStopStreaming?.call(live.id)
                          : null,
                      onActionSelected:
                          (confirmationId, actionId, actionLabel) {
                        final confirmationContext = (live.metadata?[
                                    'action_confirmation']
                                as Map<String, dynamic>?)?[
                            'confirmation_context'] as String?;
                        widget.onActionSelected(
                            live, confirmationId, actionId, actionLabel,
                            confirmationContext: confirmationContext);
                      },
                      onSingleSelectSubmitted:
                          (selectId, optionId, optionLabel) {
                        widget.onSingleSelectSubmitted(
                            live, selectId, optionId, optionLabel);
                      },
                      onMultiSelectSubmitted: (selectId, optionIds, summary) {
                        widget.onMultiSelectSubmitted(
                            live, selectId, optionIds, summary);
                      },
                      onFileUploadSubmitted: (uploadId, files, summary) {
                        widget.onFileUploadSubmitted(
                            live, uploadId, files, summary);
                      },
                      onFormSubmitted: (formId, values, summary) {
                        widget.onFormSubmitted(
                            live, formId, values, summary);
                      },
                      onPlanApprovalResponded:
                          widget.onPlanApprovalResponded != null
                              ? (approved, {feedback, skippedTaskIds}) =>
                                  widget.onPlanApprovalResponded!(
                                      live, approved,
                                      feedback: feedback,
                                      skippedTaskIds: skippedTaskIds)
                              : null,
                      quotedMessage: quotedMessage,
                      showQuote: !isReplyToPrevious,
                      onQuoteTap: live.replyTo != null
                          ? () => widget.onScrollToMessage(live.replyTo!)
                          : null,
                      allImageMessages: allImageMessages,
                      imageIndex: imageIndexMap[live.id] ?? 0,
                      imageIndexMap: imageIndexMap,
                      groupedImageMessages: groupedImages,
                      onAvatarTap: live.from.isAgent
                          ? () => widget.onAgentAvatarTap(live.from.id)
                          : null,
                      senderAvatar: senderAvatar,
                      isAgentOffline: isAgentOffline,
                      workspaceUris: workspaceUris,
                    ),
                  ),
                ),
              ],
            ),
          );
          }

          final tile = isStreaming
              ? _LiveMessageTile(
                  listenable: widget.streamingListenable,
                  messagesById: widget.messageIdMap,
                  messageId: message.id,
                  fallback: message,
                  builder: buildTile,
                )
              : _StableMessageTile(
                  stamp: stamp,
                  builder: (context) => buildTile(context, message),
                );
          if (!isStreaming) {
            return KeyedSubtree(key: ValueKey(message.id), child: tile);
          }
          // 只在正在输出的气泡外包一层：高度变化才通知外层贴底，
          // 不再每个 chunk 都 jumpTo。
          return SizeChangedLayoutNotifier(
            key: ValueKey(message.id),
            child: tile,
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

/// 流式 chunk 期间只重建这一条。消息对象在 [messagesById] 里被替换，
/// 整列不重建。
class _LiveMessageTile extends StatefulWidget {
  final Listenable listenable;
  final Map<String, Message> messagesById;
  final String messageId;
  final Message fallback;
  final Widget Function(BuildContext context, Message message) builder;

  const _LiveMessageTile({
    required this.listenable,
    required this.messagesById,
    required this.messageId,
    required this.fallback,
    required this.builder,
  });

  @override
  State<_LiveMessageTile> createState() => _LiveMessageTileState();
}

class _LiveMessageTileState extends State<_LiveMessageTile> {
  Message? _shown;
  Widget? _child;
  ThemeData? _theme;
  TextScaler? _scaler;
  Locale? _locale;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onStream);
  }

  @override
  void didUpdateWidget(covariant _LiveMessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 整列重建时高亮、折叠等闭包输入可能变了，丢掉缓存。
    // chunk 只走 listener 的 setState，不会进这里。
    _child = null;
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onStream);
      widget.listenable.addListener(_onStream);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onStream);
    super.dispose();
  }

  void _onStream() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final message =
        widget.messagesById[widget.messageId] ?? widget.fallback;
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);
    // 群聊里多条同时在输出时，一次通知会打到每一条。对象没换就复用子树。
    if (_child != null &&
        identical(_shown, message) &&
        theme == _theme &&
        scaler == _scaler &&
        locale == _locale) {
      return _child!;
    }
    _shown = message;
    _theme = theme;
    _scaler = scaler;
    _locale = locale;
    return _child = widget.builder(context, message);
  }
}

/// 展示输入没变时复用已建好的气泡子树。
///
/// 列表在流式 chunk 上整表重建，但 [builder] 只在 [stamp] 变化时重跑。
/// 返回同一个 widget 实例时，子 Element 不会 update，Markdown 不会重解析。
class _StableMessageTile extends StatefulWidget {
  final Object stamp;
  final WidgetBuilder builder;

  const _StableMessageTile({
    required this.stamp,
    required this.builder,
  });

  @override
  State<_StableMessageTile> createState() => _StableMessageTileState();
}

class _StableMessageTileState extends State<_StableMessageTile> {
  Widget? _child;
  ThemeData? _theme;
  TextScaler? _scaler;
  Locale? _locale;

  @override
  void didUpdateWidget(covariant _StableMessageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stamp != widget.stamp) {
      _child = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 主题、字号、语言变了也要重做气泡。这些依赖在 build 里读取，
    // 流式期间值不变，子树继续复用。
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.localeOf(context);
    if (_child == null ||
        theme != _theme ||
        scaler != _scaler ||
        locale != _locale) {
      _theme = theme;
      _scaler = scaler;
      _locale = locale;
      _child = widget.builder(context);
    }
    return _child!;
  }
}
