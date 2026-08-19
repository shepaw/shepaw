import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/llm_token_usage.dart';
import '../models/message.dart';
import '../controllers/chat_message_window.dart';
import '../services/store_open_service.dart';
import '../screens/storage_directory_opener.dart';
import '../storage/workspace_link_resolver.dart';
import '../theme/app_theme.dart';
import 'voice_message_bubble.dart';
import 'image_message_bubble.dart';
import 'image_grid_bubble.dart';
import 'file_message_bubble.dart';
import 'action_confirmation_buttons.dart';
import 'single_select_bubble.dart';
import 'multi_select_bubble.dart';
import 'file_upload_bubble.dart';
import 'form_bubble.dart';
import 'collapsible_message_bubble.dart';
import 'permission_audit_bubble.dart';
import 'chat/plan_approval_card.dart';
import 'chat/dispatch_card.dart';
import 'chat/relay_approval_card.dart';
import 'avatar_image.dart';
import 'chat/sticky_in_view_header.dart';
import '../services/she_service.dart';
import '../services/error_handler_service.dart';

class MessageBubble extends StatelessWidget {
  static const double avatarSize = 32;
  static const double avatarGap = 8;

  final Message message;
  final bool isMyMessage;
  final bool isStreaming;
  final VoidCallback? onStop;
  final void Function(String confirmationId, String actionId, String actionLabel)? onActionSelected;
  final void Function(String selectId, String optionId, String optionLabel)? onSingleSelectSubmitted;
  final void Function(String selectId, List<String> optionIds, String summary)? onMultiSelectSubmitted;
  final void Function(String uploadId, List<Map<String, dynamic>> files, String summary)? onFileUploadSubmitted;
  final void Function(String formId, Map<String, dynamic> values, String summary)? onFormSubmitted;
  final void Function(bool approved, {String? feedback, List<String>? skippedTaskIds})? onPlanApprovalResponded;
  final Message? quotedMessage;
  final VoidCallback? onQuoteTap;
  final bool showQuote;
  final List<Message> allImageMessages;
  final int imageIndex;
  final List<Message>? groupedImageMessages;
  final Map<String, int> imageIndexMap;
  final VoidCallback? onAvatarTap;

  /// 发送者的自定义头像（emoji / 本地文件路径 / URL）。
  /// 非空时优先用于渲染头像，覆盖从 [message.from.name] 提取的 emoji 逻辑。
  final String? senderAvatar;

  /// When `true`, the action-confirmation card (if rendered) shows an
  /// "offline — will reconnect on tap" hint. Pass the negation of whatever
  /// `isAgentOnline` signal the screen has. Default `false` keeps the
  /// legacy look when the caller doesn't plumb the value through.
  final bool isAgentOffline;

  /// When `true`, message text can be selected (long-press flow).
  final bool textSelectionEnabled;

  /// Key for the [SelectionArea] wrapping message text.
  final GlobalKey<SelectionAreaState>? selectionAreaKey;

  /// Focus node for the [SelectionArea] selection handles.
  final FocusNode? selectionFocusNode;

  /// When `true`, the context menu is open on this message.
  final bool isContextMenuActive;

  /// Whether to show the sender name above the bubble (group chats only).
  final bool showSenderName;

  /// Whether to show the avatar widget.
  final bool showAvatar;

  /// When avatar is hidden in group consecutive mode, keep a spacer so
  /// bubbles stay indented. Ignored when [showAvatar] is true.
  final bool reserveAvatarSpace;

  /// When `true`, author chrome (avatar + name) sticks to the top of this
  /// message's visible area while scrolling.
  final bool stickySenderName;

  /// Store workspace roots used to resolve relative markdown links
  /// like `[docs/good.md](docs/good.md)`.
  final List<String> workspaceUris;

  /// Group-chat: hide the bubble body (user preference).
  final bool bodyCollapsed;

  /// Group-chat: tap handler for the author-bar collapse control.
  final VoidCallback? onToggleBodyCollapse;

  /// Extra listenables (e.g. item positions) that trigger sticky recalculation.
  final List<Listenable> stickyScrollListenables;

  /// List viewport key for sticky Y measurement.
  final GlobalKey? stickyViewportKey;

  const MessageBubble({
    Key? key,
    required this.message,
    required this.isMyMessage,
    this.isStreaming = false,
    this.onStop,
    this.onActionSelected,
    this.onSingleSelectSubmitted,
    this.onMultiSelectSubmitted,
    this.onFileUploadSubmitted,
    this.onFormSubmitted,
    this.onPlanApprovalResponded,
    this.quotedMessage,
    this.onQuoteTap,
    this.showQuote = true,
    this.allImageMessages = const [],
    this.imageIndex = 0,
    this.groupedImageMessages,
    this.imageIndexMap = const {},
    this.onAvatarTap,
    this.senderAvatar,
    this.isAgentOffline = false,
    this.textSelectionEnabled = false,
    this.selectionAreaKey,
    this.selectionFocusNode,
    this.isContextMenuActive = false,
    this.showSenderName = true,
    this.showAvatar = true,
    this.reserveAvatarSpace = false,
    this.stickySenderName = false,
    this.workspaceUris = const [],
    this.bodyCollapsed = false,
    this.onToggleBodyCollapse,
    this.stickyScrollListenables = const [],
    this.stickyViewportKey,
  }) : super(key: key);

  static MarkdownStyleSheet? _cachedMyStyleSheet;
  static MarkdownStyleSheet? _cachedOtherStyleSheet;
  static Color? _cachedPrimaryColor;
  // Bump when other-message typography/colors change so hot reload refreshes.
  static const int _styleSheetVersion = 2;
  static int? _cachedStyleSheetVersion;

  static MarkdownStyleSheet _getStyleSheet(bool isMyMessage, Color primaryColor) {
    if (_cachedPrimaryColor != primaryColor ||
        _cachedStyleSheetVersion != _styleSheetVersion) {
      _cachedMyStyleSheet = null;
      _cachedOtherStyleSheet = null;
      _cachedPrimaryColor = primaryColor;
      _cachedStyleSheetVersion = _styleSheetVersion;
    }
    if (isMyMessage) {
      return _cachedMyStyleSheet ??= _buildStyleSheet(true);
    } else {
      return _cachedOtherStyleSheet ??= _buildStyleSheet(false);
    }
  }

  static MarkdownStyleSheet _buildStyleSheet(bool isMyMessage) {
    final textColor =
        isMyMessage ? Colors.white : AppColors.textPrimary;
    return MarkdownStyleSheet(
      p: TextStyle(color: textColor, fontSize: 15, height: 1.5),
      h1: TextStyle(color: textColor, fontSize: 22, fontWeight: FontWeight.bold),
      h2: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold),
      h3: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold),
      h4: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
      h5: TextStyle(color: textColor, fontSize: 15, fontWeight: FontWeight.bold),
      h6: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.bold),
      em: TextStyle(color: textColor, fontStyle: FontStyle.italic),
      strong: TextStyle(color: textColor, fontWeight: FontWeight.bold),
      a: TextStyle(color: isMyMessage ? Colors.lightBlueAccent : Colors.blue, decoration: TextDecoration.underline),
      code: TextStyle(
        color: isMyMessage ? Colors.white : AppColors.textPrimary,
        backgroundColor: isMyMessage
            ? Colors.white24
            : AppColors.outline.withValues(alpha: 0.45),
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      codeblockDecoration: BoxDecoration(
        color: isMyMessage ? Colors.white12 : AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isMyMessage ? Colors.white54 : AppColors.outline,
            width: 3,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 10, top: 4, bottom: 4),
      listBullet: TextStyle(color: textColor, fontSize: 15),
      tableHead: TextStyle(color: textColor, fontWeight: FontWeight.bold),
      tableBody: TextStyle(color: textColor),
      tableBorder: TableBorder.all(
        color: isMyMessage ? Colors.white38 : AppColors.outline,
        width: 1,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isMyMessage ? Colors.white38 : AppColors.outline,
            width: 1,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 审核消息卡片 - 全宽居中显示
    if (message.type == MessageType.permissionAudit) {
      return PermissionAuditBubble(message: message);
    }

    // 系统消息
    if (message.isSystemMessage) {
      // She 派发卡片：以系统消息落库，按 metadata 渲染为卡片
      final dispatchMeta = message.metadata;
      if (dispatchMeta?['dispatch_status'] == true) {
        return DispatchStatusCard(message: message);
      }
      if (dispatchMeta?['dispatch_confirm'] != null) {
        return DispatchConfirmCard(message: message);
      }
      if (dispatchMeta?['group_approval_bridge'] != null) {
        return GroupApprovalBridgeCard(message: message);
      }
      if (dispatchMeta?['relay_approval'] != null) {
        return RelayApprovalCard(message: message);
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.content,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      );
    }

    // 普通消息
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: _buildNormalMessage(context),
    );
  }

  Widget _buildNormalMessage(BuildContext context) {
    // Group non-my: sticky header carries avatar + name above the bubble
    // (no left indent under the chrome; bubble width follows content).
    if (stickySenderName) {
      // Collapsed: conversation-list style row; tap anywhere to expand.
      if (bodyCollapsed) {
        return _buildCollapsedListTile(context);
      }

      final canToggle = onToggleBodyCollapse != null;
      final showFullChrome = showSenderName || showAvatar;
      final showChromeInFlow = showFullChrome || canToggle;
      return StickyInViewHeader(
        enabled: true,
        showHeaderInFlow: showChromeInFlow,
        stuckBackground: Theme.of(context).scaffoldBackgroundColor,
        scrollListenables: stickyScrollListenables,
        viewportKey: stickyViewportKey,
        bubbleTopRadius: 16,
        header: showFullChrome
            ? _buildStickyAuthorChrome(context)
            : _buildCollapseOnlyChrome(context),
        child: _buildBubbleBody(context),
      );
    }

    // DM / my messages / group without sticky: classic row layout.
    // DM: no avatar. Group my-messages may still show trailing avatar.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment:
          isMyMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!isMyMessage && (showAvatar || reserveAvatarSpace)) ...[
          _buildLeadingAvatarSlot(context),
          const SizedBox(width: avatarGap),
        ],
        Flexible(child: _buildBubbleBody(context)),
        if (isMyMessage && showAvatar) ...[
          const SizedBox(width: avatarGap),
          _buildTrailingAvatarSlot(context),
        ],
      ],
    );
  }

  String _senderDisplayName(BuildContext context) {
    if (message.from.id == SheService.sheId) {
      return SheService.resolveDisplayName(
        message.from.name,
        AppLocalizations.of(context).she_name,
      );
    }
    return message.from.name;
  }

  /// Collapsed body: home conversation-list style; tap row to expand.
  Widget _buildCollapsedListTile(BuildContext context) {
    final onToggle = onToggleBodyCollapse;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              _buildLeadingAvatarSlot(context, forceVisible: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _senderDisplayName(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildTimestampLabel(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _collapsedPreviewText(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
              if (onToggle != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more,
                  size: 20,
                  color: Colors.grey[600],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _collapsedPreviewText(BuildContext context) {
    switch (message.type) {
      case MessageType.image:
        final name = message.metadata?['name'] as String?;
        return (name != null && name.isNotEmpty) ? name : '🖼';
      case MessageType.file:
        final name = message.metadata?['name'] as String?;
        return (name != null && name.isNotEmpty)
            ? name
            : AppLocalizations.of(context).chat_file;
      case MessageType.audio:
        return '🎤';
      default:
        final text =
            message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
        return text.isEmpty ? '…' : text;
    }
  }

  /// Compact left-side collapse control for consecutive messages without
  /// full author chrome (expanded state only).
  Widget _buildCollapseOnlyChrome(BuildContext context) {
    final onToggle = onToggleBodyCollapse;
    if (onToggle == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          icon: Icon(
            Icons.expand_less,
            size: 20,
            color: Colors.grey[600],
          ),
          tooltip: l10n.widget_collapseMessage,
          onPressed: onToggle,
          splashRadius: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  /// Avatar + name row used as the sticky / in-flow author chrome.
  Widget _buildStickyAuthorChrome(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canToggle = onToggleBodyCollapse != null;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildLeadingAvatarSlot(context, forceVisible: true),
        const SizedBox(width: avatarGap),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  _senderDisplayName(context),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),
              if (isStreaming) ...[
                const SizedBox(width: 4),
                Text(
                  l10n.widget_typing,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.primary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        _buildTimestampLabel(
          fontSize: 12,
          color: Colors.grey[500],
        ),
        if (canToggle) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.expand_less,
            size: 20,
            color: Colors.grey[600],
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: canToggle
          ? Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onToggleBodyCollapse,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  // Keep hit target comfortable without shifting layout much.
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: row,
                ),
              ),
            )
          : row,
    );
  }

  Widget _buildLeadingAvatarSlot(BuildContext context,
      {bool forceVisible = false}) {
    final visible = forceVisible || showAvatar;
    if (!visible) {
      return const SizedBox(width: avatarSize, height: avatarSize);
    }
    return GestureDetector(
      onTap: onAvatarTap,
      child: Container(
        width: avatarSize,
        height: avatarSize,
        decoration: BoxDecoration(
          color: isStreaming ? AppColors.primaryContainer : null,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: isStreaming
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).primaryColor,
                  ),
                ),
              )
            : _buildAvatarWidget(),
      ),
    );
  }

  Widget _buildTrailingAvatarSlot(BuildContext context) {
    if (!showAvatar) {
      return const SizedBox(width: avatarSize, height: avatarSize);
    }
    return Container(
      width: avatarSize,
      height: avatarSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: _buildAvatarWidget(),
    );
  }

  Widget _buildBubbleBody(BuildContext context) {
    return Align(
      alignment: isMyMessage ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMyMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                // Width follows content (capped by parent Align/Flexible).
                // Do not force full row width — short messages stay compact.
                padding: message.type == MessageType.image
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                decoration: BoxDecoration(
                  color: isMyMessage
                      ? Theme.of(context).primaryColor
                      : (isStreaming
                          ? AppColors.primaryContainer
                          : AppColors.surfaceMuted),
                  borderRadius: BorderRadius.circular(16),
                  border: isStreaming
                      ? Border.all(
                          color: AppColors.primaryLight,
                          width: 1,
                        )
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showQuote && quotedMessage != null)
                      _buildQuoteBlock(context)
                    else if (showQuote && message.replyTo != null)
                      _buildDeletedQuoteBlock(context),
                    _buildMessageContent(context),
                  ],
                ),
              ),
              if (isContextMenuActive)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: isMyMessage
                            ? Colors.black.withValues(alpha: 0.18)
                            : Theme.of(context)
                                .primaryColor
                                .withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (isStreaming && onStop != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GestureDetector(
                onTap: onStop,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red[300]!, width: 1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop, size: 14, color: Colors.red[400]),
                      const SizedBox(width: 4),
                      Text(
                        AppLocalizations.of(context).widget_stop,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red[400],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _buildTimestampLabel(
              fontSize: 10,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  /// Time label, optionally followed by compact token usage for agent messages.
  Widget _buildTimestampLabel({required double fontSize, Color? color}) {
    final style = TextStyle(fontSize: fontSize, color: color);
    final usageLabel = message.from.isAgent
        ? LlmTokenUsage.fromMetadata(message.metadata)?.compactLabel
        : null;
    if (usageLabel == null) {
      return Text(message.timeString, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: message.timeString),
          TextSpan(
            text: '  $usageLabel',
            style: TextStyle(
              fontSize: fontSize,
              color: color?.withValues(alpha: 0.85) ?? Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapWithTextSelection(Widget child, {bool useSharedSelectionKey = true}) {
    final content = textSelectionEnabled
        ? child
        : SelectionContainer.disabled(child: child);
    return SelectionArea(
      key: useSharedSelectionKey ? selectionAreaKey : null,
      focusNode: useSharedSelectionKey ? selectionFocusNode : null,
      contextMenuBuilder: (context, selectableRegionState) {
        return const SizedBox.shrink();
      },
      child: content,
    );
  }

  /// Replace cc-only mention tokens with an annotated form.
  /// For mentions with notify:false, appends "(cc)" so readers can
  /// tell at a glance that the mentioned agent was not triggered.
  /// Open store:// files (preview) or folders (storage browser).
  Future<void> _openStoreLink(BuildContext context, String uriString) async {
    registerStorageDirectoryOpener();
    await StoreOpenService.instance.openStoreUri(context, uriString);
  }

  Future<void> _handleTapLink(BuildContext context, String href) async {
    final resolved = resolveWorkspaceHref(href, workspaceUris) ??
        (href.startsWith('store://') ? href : null);
    if (resolved != null && resolved.startsWith('store://')) {
      await _openStoreLink(context, resolved);
      return;
    }
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        showTopToast(
          context,
          AppLocalizations.of(context).widget_cannotOpenLink(href),
          icon: Icons.error_outline,
          color: Colors.red.shade400,
        );
      }
    }
  }

  /// Annotate mention tokens in [content] from persisted mention metadata:
  /// `@名字` is bolded for readability; cc-only mentions (notify: false) get
  /// an explicit "(cc)" suffix so readers can tell the target was not
  /// activated. Boundary-aware: "@Tommy" is never treated as a mention of
  /// member "Tom".
  String _processContentWithMentions(String content, Map<String, dynamic>? metadata) {
    final mentionsRaw = metadata?['mentions'] as List<dynamic>? ?? [];
    if (mentionsRaw.isEmpty) return content;

    final notifyByName = <String, bool>{};
    final names = <String>[];
    for (final raw in mentionsRaw) {
      final m = raw as Map<String, dynamic>;
      final name = m['name'] as String? ?? '';
      if (name.isEmpty) continue;
      notifyByName[name] = m['notify'] as bool? ?? true;
      if (!names.contains(name)) names.add(name);
    }
    if (names.isEmpty) return content;

    final pattern = RegExp(
      '@(${names.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}·-])',
      unicode: true,
    );
    return content.replaceAllMapped(pattern, (match) {
      final name = match.group(1)!;
      final notify = notifyByName[name] ?? true;
      return notify ? '**@$name**' : '**@$name(cc)**';
    });
  }

  Widget _buildMessageContent(BuildContext context) {
    switch (message.type) {
      case MessageType.audio:
        return VoiceMessageBubble(
          message: message,
          isMyMessage: isMyMessage,
        );
      case MessageType.image:
        if (groupedImageMessages != null && groupedImageMessages!.length > 1) {
          return ImageGridBubble(
            imageMessages: groupedImageMessages!,
            isMyMessage: isMyMessage,
            allImageMessages: allImageMessages,
            imageIndexMap: imageIndexMap,
          );
        }
        return ImageMessageBubble(
          message: message,
          isMyMessage: isMyMessage,
          allImageMessages: allImageMessages,
          imageIndex: imageIndex,
        );
      case MessageType.file:
        return FileMessageBubble(
          message: message,
          isMyMessage: isMyMessage,
        );
      default:
        final rawContent = message.content.isEmpty ? '...' : message.content;
        final content = _processContentWithMentions(rawContent, message.metadata);
        final styleSheet = _getStyleSheet(isMyMessage, Theme.of(context).primaryColor);
        final markdownBody = MarkdownBody(
          data: content,
          selectable: false,
          extensionSet: md.ExtensionSet.gitHubWeb,
          onTapLink: (text, href, title) async {
            if (href == null) return;
            await _handleTapLink(context, href);
          },
          styleSheet: styleSheet,
        );
        final markdownWidget = _wrapWithTextSelection(markdownBody);
        final hasAnswer = message.content.trim().isNotEmpty;

        final progressSection = _buildProgressCollapsibleSection(
          context,
          styleSheet: styleSheet,
          hasAnswer: hasAnswer,
        );
        final interactiveFooter = _buildInteractiveFooter(context);

        if (progressSection != null || interactiveFooter != null) {
          final children = <Widget>[];
          if (progressSection != null) {
            children.add(progressSection);
            if (hasAnswer) {
              children.add(const SizedBox(height: 8));
              children.add(markdownWidget);
            }
          } else if (hasAnswer) {
            children.add(markdownWidget);
          }
          if (interactiveFooter != null) {
            if (children.isNotEmpty) {
              children.add(const SizedBox(height: 10));
            }
            children.add(interactiveFooter);
          }
          if (children.length == 1) return children.first;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          );
        }

        // Check for collapsible config (whole-message collapse, legacy)
        final isCollapsible = message.metadata?['collapsible'] == true;
        if (isCollapsible) {
          final collapsibleTitle = message.metadata?['collapsible_title'] as String?;
          final autoCollapse = message.metadata?['auto_collapse'] == true;
          return CollapsibleMessageBubble(
            title: collapsibleTitle ?? AppLocalizations.of(context).widget_details,
            initiallyCollapsed: !isStreaming && autoCollapse,
            autoCollapseOnComplete: autoCollapse,
            isStreaming: isStreaming,
            isMyMessage: isMyMessage,
            child: markdownWidget,
          );
        }

        // Long finished replies: collapse by default to bound layout cost.
        if (!isStreaming &&
            message.content.length >= ChatMessageWindow.longContentChars) {
          return CollapsibleMessageBubble(
            title: AppLocalizations.of(context).widget_details,
            initiallyCollapsed: true,
            autoCollapseOnComplete: false,
            isStreaming: false,
            isMyMessage: isMyMessage,
            child: markdownWidget,
          );
        }

        return markdownWidget;
    }
  }

  /// Collapsible progress/thinking block from [metadata.progress_content].
  Widget? _buildProgressCollapsibleSection(
    BuildContext context, {
    required MarkdownStyleSheet styleSheet,
    required bool hasAnswer,
  }) {
    final progressContent =
        message.metadata?['progress_content'] as String?;
    if (progressContent == null || progressContent.isEmpty) {
      return null;
    }

    final progressTitle = message.metadata?['collapsible_title'] as String?;
    final autoCollapse = message.metadata?['auto_collapse'] != false;
    final progressBody = MarkdownBody(
      data: progressContent,
      selectable: false,
      extensionSet: md.ExtensionSet.gitHubWeb,
      onTapLink: (text, href, title) async {
        if (href == null) return;
        await _handleTapLink(context, href);
      },
      styleSheet: styleSheet,
    );
    return CollapsibleMessageBubble(
      title: progressTitle ?? AppLocalizations.of(context).widget_details,
      initiallyCollapsed: hasAnswer || (!isStreaming && autoCollapse),
      autoCollapseOnComplete: autoCollapse && hasAnswer,
      isStreaming: isStreaming && !hasAnswer,
      isMyMessage: isMyMessage,
      child: _wrapWithTextSelection(
        progressBody,
        useSharedSelectionKey: !hasAnswer,
      ),
    );
  }

  /// Interactive cards/buttons appended below message text (approval, forms, etc.).
  Widget? _buildInteractiveFooter(BuildContext context) {
    final planApproval =
        message.metadata?['plan_approval'] as Map<String, dynamic>?;
    if (planApproval != null && onPlanApprovalResponded != null) {
      final planResponded =
          message.metadata?['plan_approval_responded'] as Map<String, dynamic>?;
      final isPlanResponded =
          planResponded != null || planApproval['_approved'] != null;
      return PlanApprovalCard(
        planData: planApproval,
        isResponded: isPlanResponded,
        onRespond: onPlanApprovalResponded!,
      );
    }

    final actionConfirmation =
        message.metadata?['action_confirmation'] as Map<String, dynamic>?;
    if (actionConfirmation != null) {
      final isWorkflowPeerApproval =
          actionConfirmation['_workflowPeerApproval'] == true &&
          actionConfirmation['selected_action_id'] == null;
      if (isWorkflowPeerApproval) {
        return _workflowPeerApprovalHint(context);
      }
      return ActionConfirmationButtons(
        actionData: actionConfirmation,
        onActionSelected: onActionSelected,
        isAgentOffline: isAgentOffline,
      );
    }

    final singleSelect =
        message.metadata?['single_select'] as Map<String, dynamic>?;
    if (singleSelect != null) {
      return SingleSelectBubble(
        selectData: singleSelect,
        onSelectSubmitted: onSingleSelectSubmitted,
      );
    }

    final multiSelect =
        message.metadata?['multi_select'] as Map<String, dynamic>?;
    if (multiSelect != null) {
      return MultiSelectBubble(
        selectData: multiSelect,
        onSelectSubmitted: onMultiSelectSubmitted,
      );
    }

    final fileUpload =
        message.metadata?['file_upload'] as Map<String, dynamic>?;
    if (fileUpload != null) {
      return FileUploadBubble(
        uploadData: fileUpload,
        onUploadSubmitted: onFileUploadSubmitted,
      );
    }

    final formData = message.metadata?['form'] as Map<String, dynamic>?;
    if (formData != null) {
      return FormBubble(
        formData: formData,
        onFormSubmitted: onFormSubmitted,
      );
    }

    return null;
  }

  Widget _buildQuoteBlock(BuildContext context) {
    final quoted = quotedMessage!;
    final accentColor = isMyMessage ? Colors.white70 : Theme.of(context).primaryColor;
    final nameColor = isMyMessage ? Colors.white : Theme.of(context).primaryColor;
    final contentColor = isMyMessage ? Colors.white70 : Colors.black54;
    final bgColor = isMyMessage ? Colors.white.withOpacity(0.15) : Theme.of(context).primaryColor.withOpacity(0.08);

    final previewText = quoted.content.length > 60
        ? '${quoted.content.substring(0, 60)}...'
        : quoted.content;

    return GestureDetector(
      onTap: onQuoteTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(
            left: BorderSide(color: accentColor, width: 3),
          ),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              quoted.from.id == SheService.sheId
                  ? SheService.resolveDisplayName(
                      quoted.from.name,
                      AppLocalizations.of(context).she_name,
                    )
                  : quoted.from.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: nameColor,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              previewText,
              style: TextStyle(
                fontSize: 12,
                color: contentColor,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeletedQuoteBlock(BuildContext context) {
    final accentColor = isMyMessage ? Colors.white38 : Colors.grey[400]!;
    final textColor = isMyMessage ? Colors.white54 : Colors.grey;
    final bgColor = isMyMessage ? Colors.white.withOpacity(0.08) : Colors.grey.withOpacity(0.08);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          left: BorderSide(color: accentColor, width: 3),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Text(
        AppLocalizations.of(context).widget_originalMessageUnavailable,
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: textColor,
        ),
      ),
    );
  }

  Widget _workflowPeerApprovalHint(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.deepOrange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.deepOrange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined,
              size: 18, color: Colors.deepOrange.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.chat_toolPendingInPanel,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withOpacity(0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getAvatar() {
    // She 专属头像（灵宠形象，由 _buildAvatarWidget 渲染为图片）
    if (message.from.id == SheService.sheId) {
      return '🐱';
    }

    // senderAvatar 有值时：若是纯 emoji，直接返回；图片路径交由 _buildAvatarWidget
    if (senderAvatar != null && senderAvatar!.isNotEmpty) {
      final isImagePath = AvatarImage.isLocalFile(senderAvatar!) ||
          AvatarImage.isNetworkUrl(senderAvatar!) ||
          AvatarImage.isAsset(senderAvatar!);
      if (!isImagePath) return senderAvatar!;
      // 图片路径/URL 交由 _buildAvatarWidget 处理，此处返回 fallback
      return message.from.isAgent ? '🤖' : '👤';
    }

    // 尝试从 from.name 中提取 emoji
    if (message.from.name.isNotEmpty) {
      final firstChar = message.from.name.runes.first;
      if (firstChar >= 0x1F300 && firstChar <= 0x1F9FF) {
        return String.fromCharCode(firstChar);
      }
    }

    // 默认头像
    return message.from.isAgent ? '🤖' : '👤';
  }

  /// 根据 [senderAvatar] 决定渲染图片还是 emoji 文字。
  Widget _buildAvatarWidget() {
    // She 专属头像：橘猫灵宠形象
    if (message.from.id == SheService.sheId) {
      return AvatarImage(
        avatar: SheService.sheAvatar,
        size: 32,
        borderRadius: 8,
        fallback: const Text('🐱', style: TextStyle(fontSize: 24)),
      );
    }

    if (senderAvatar != null && senderAvatar!.isNotEmpty) {
      final isImage = AvatarImage.isLocalFile(senderAvatar!) ||
          AvatarImage.isNetworkUrl(senderAvatar!) ||
          AvatarImage.isAsset(senderAvatar!);

      if (isImage) {
        final fallback = Text(
          message.from.isAgent ? '🤖' : '👤',
          style: const TextStyle(fontSize: 24),
        );

        return AvatarImage(
          avatar: senderAvatar!,
          size: 32,
          borderRadius: 8,
          fallback: fallback,
        );
      }
      // 纯 emoji 或普通字符串
      return AvatarImage(
        avatar: senderAvatar!,
        size: 32,
        borderRadius: 8,
        fallback: Text(
          message.from.isAgent ? '🤖' : '👤',
          style: const TextStyle(fontSize: 24),
        ),
      );
    }

    return AvatarImage(
      avatar: _getAvatar(),
      size: 32,
      borderRadius: 8,
      fallback: Text(
        message.from.isAgent ? '🤖' : '👤',
        style: const TextStyle(fontSize: 24),
      ),
    );
  }
}
