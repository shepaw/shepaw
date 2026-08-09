import 'dart:async';
import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/acp_protocol.dart';
import '../../models/mention_entry.dart';
import '../../models/pending_attachment.dart';
import '../../models/remote_agent.dart';
import '../../services/audio_recording_service.dart';
import '../../utils/layout_utils.dart';
import '../../l10n/app_localizations.dart';
import '../../services/error_handler_service.dart';
import '../../theme/app_theme.dart';
import 'slash_command_picker.dart';

/// The chat input area widget (supports both desktop and mobile layouts).
///
/// Handles:
/// - Text input with desktop/mobile layouts
/// - Voice recording (mobile: hold to talk)
/// - Pending attachment previews
/// - @mention picker for group mode
/// - Emoji picker toggle
/// - Enter key handling (send / mention confirm)
class ChatInputArea extends StatefulWidget {
  final TextEditingController messageController;
  final FocusNode textFieldFocusNode;
  final bool isLoading;
  final bool isGroupMode;
  final List<PendingAttachment> pendingAttachments;
  final List<RemoteAgent> groupAgents;
  final AudioRecordingService audioRecordingService;
  final bool isRecording;
  final bool isCancelZone;
  final VoidCallback onSend;
  final VoidCallback onToggleEmojiPicker;
  final VoidCallback onShowAttachmentOptions;
  /// Desktop attachment popover actions (mobile still uses
  /// [onShowAttachmentOptions] bottom sheet).
  final VoidCallback onPickFile;
  final VoidCallback onPickFromStorageBag;
  final VoidCallback? onSendVoice;
  final bool showEmojiPicker;
  final ValueChanged<PendingAttachment> onRemoveAttachment;
  final VoidCallback? onMentionPickerChanged;
  /// Desktop-only: called when user pastes from clipboard and it contains
  /// image bytes or file paths. Return true if the paste was handled
  /// (so TextField's default paste is suppressed).
  final Future<bool> Function()? onDesktopPaste;

  /// Whether the configured LLM supports audio/voice input.
  /// When false, the voice mode toggle button is hidden.
  final bool hasAudioModel;

  /// Available slash commands for the "/" palette. When empty, the palette
  /// never appears. Combined with [slashCommandsStream] — the stream fires
  /// whenever the agent pushes `agent.commands.changed` so the list can
  /// update without a reconnect.
  final List<SlashCommandInfo> slashCommands;
  final Stream<List<SlashCommandInfo>>? slashCommandsStream;

  /// On-demand resolver for the live slash-command list. If set, this is
  /// called every time the user types `/`, so the palette sees the current
  /// snapshot even if the parent widget's build didn't happen to coincide
  /// with the agent's `agent.commands.changed` notification. This is the
  /// robust path for the "first launch" race where the ACP connection is
  /// created lazily after screen entry and the parent doesn't immediately
  /// rebuild when it becomes available.
  final List<SlashCommandInfo> Function()? slashCommandsResolver;

  const ChatInputArea({
    super.key,
    required this.messageController,
    required this.textFieldFocusNode,
    required this.isLoading,
    required this.isGroupMode,
    required this.pendingAttachments,
    required this.groupAgents,
    required this.audioRecordingService,
    required this.isRecording,
    required this.isCancelZone,
    required this.onSend,
    required this.onToggleEmojiPicker,
    required this.onShowAttachmentOptions,
    required this.onPickFile,
    required this.onPickFromStorageBag,
    this.onSendVoice,
    required this.showEmojiPicker,
    required this.onRemoveAttachment,
    this.onMentionPickerChanged,
    this.onDesktopPaste,
    this.hasAudioModel = false,
    this.slashCommands = const [],
    this.slashCommandsStream,
    this.slashCommandsResolver,
  });

  @override
  State<ChatInputArea> createState() => ChatInputAreaState();
}

class ChatInputAreaState extends State<ChatInputArea> {
  bool _isVoiceMode = false;
  bool _hasText = false;

  // Mention picker state
  bool _showMentionPicker = false;
  String _mentionQuery = '';
  int _mentionTriggerOffset = -1;
  int _mentionSelectedIndex = 0;
  // Sub-menu state: null = first-level, non-null = showing sub-menu for that index
  int? _mentionSubMenuIndex;
  int _mentionSubMenuSelectedIndex = 0; // 0 = Notify, 1 = CC Only
  final ScrollController _mentionScrollController = ScrollController();
  // Guard to suppress _detectMentionTrigger while inserting mention text
  bool _insertingMention = false;

  // Structured mention state
  final List<MentionEntry> _pendingMentions = [];
  List<MentionEntry> get currentMentions => List.unmodifiable(_pendingMentions);

  bool get showMentionPicker => _showMentionPicker;

  // Slash command palette state (mirrors the mention picker).
  bool _showSlashPicker = false;
  String _slashQuery = '';
  int _slashTriggerOffset = -1;
  int _slashSelectedIndex = 0;
  final ScrollController _slashScrollController = ScrollController();
  late List<SlashCommandInfo> _slashCommands;
  StreamSubscription<List<SlashCommandInfo>>? _slashCommandsSub;

  // Desktop WeChat-style floating emoji / attachment popovers.
  // Anchored via the toolbar button's global rect on the root Overlay so the
  // panel isn't clipped / buried by the desktop conversation list (the chat
  // lives inside a nested Navigator Overlay on the right panel).
  final GlobalKey _emojiButtonKey = GlobalKey();
  final Object _emojiTapGroup = Object();
  OverlayEntry? _emojiOverlay;
  bool _desktopEmojiOpen = false;

  final GlobalKey _attachmentButtonKey = GlobalKey();
  final Object _attachmentTapGroup = Object();
  OverlayEntry? _attachmentOverlay;
  bool _desktopAttachmentOpen = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.messageController.text.isNotEmpty;
    widget.messageController.addListener(_onTextChanged);
    _slashCommands = widget.slashCommands;
    _slashCommandsSub = widget.slashCommandsStream?.listen((next) {
      if (!mounted) return;
      final wasEmpty = _slashCommands.isEmpty;
      setState(() {
        _slashCommands = next;
      });
      // First-launch race fix: if the user already typed "/" before the
      // agent's command list arrived, `_detectSlashTrigger` bailed out on
      // an empty list and left the picker dismissed. Re-run it now so
      // the palette opens against the text the user already has in the
      // input, instead of forcing them to type another key.
      if (wasEmpty && next.isNotEmpty && !_showSlashPicker) {
        _detectSlashTrigger();
      }
    });
  }

  @override
  void dispose() {
    _removeDesktopEmojiOverlay(updateState: false);
    _removeDesktopAttachmentOverlay(updateState: false);
    widget.messageController.removeListener(_onTextChanged);
    _mentionScrollController.dispose();
    _slashScrollController.dispose();
    _slashCommandsSub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatInputArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If audio support was removed, exit voice mode automatically.
    if (!widget.hasAudioModel && _isVoiceMode) {
      setState(() => _isVoiceMode = false);
    }
    if (!identical(oldWidget.slashCommands, widget.slashCommands)) {
      final wasEmpty = _slashCommands.isEmpty;
      _slashCommands = widget.slashCommands;
      if (wasEmpty && _slashCommands.isNotEmpty && !_showSlashPicker) {
        _detectSlashTrigger();
      }
    }
    if (!identical(oldWidget.slashCommandsStream, widget.slashCommandsStream)) {
      _slashCommandsSub?.cancel();
      _slashCommandsSub = widget.slashCommandsStream?.listen((next) {
        if (!mounted) return;
        final wasEmpty = _slashCommands.isEmpty;
        setState(() {
          _slashCommands = next;
        });
        if (wasEmpty && next.isNotEmpty && !_showSlashPicker) {
          _detectSlashTrigger();
        }
      });
    }
  }

  void _onTextChanged() {
    final newHasText = widget.messageController.text.isNotEmpty;
    if (newHasText != _hasText) {
      setState(() {
        _hasText = newHasText;
      });
    }
    if (!newHasText) {
      _pendingMentions.clear();
    } else {
      _syncMentionsWithText();
    }
    if (widget.isGroupMode && !_insertingMention) {
      _detectMentionTrigger();
    }
    if (!_insertingMention) {
      _detectSlashTrigger();
    }
  }

  void _syncMentionsWithText() {
    final text = widget.messageController.text;
    _pendingMentions.removeWhere((m) =>
        m.id == 'all' ? !text.contains('@all') : !text.contains('@${m.name}'));
  }

  bool get _canSend => _hasText || widget.pendingAttachments.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final isDesktop = LayoutUtils.isDesktopLayout(context);
    final inputArea = isDesktop ? _buildDesktopInputArea() : _buildMobileInputArea();
    final showMention = widget.isGroupMode && _showMentionPicker;
    final showSlash = _showSlashPicker;
    // Always wrap in a Column so toggling picker visibility doesn't
    // re-parent the input area — re-parenting would tear down the
    // TextField's internal state and drop the keyboard focus.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showMention) _buildMentionPickerWidget(),
        if (showSlash) _buildSlashPickerWidget(),
        inputArea,
      ],
    );
  }

  Widget _buildSlashPickerWidget() {
    return SlashCommandPicker(
      commands: _slashCommands,
      query: _slashQuery,
      selectedIndex: _slashSelectedIndex,
      scrollController: _slashScrollController,
      onHover: (index) {
        if (index != _slashSelectedIndex) {
          setState(() => _slashSelectedIndex = index);
        }
      },
      onSelect: _applySlashCommand,
    );
  }

  /// Build the mention picker overlay widget (called from external parent for backward compat).
  Widget buildMentionPicker() => _buildMentionPickerWidget();

  Widget _buildMentionPickerWidget() {
    final showAll = _mentionAllMatches(_mentionQuery.toLowerCase());
    final filtered = _getFilteredMentionAgents();
    final totalCount = (showAll ? 1 : 0) + filtered.length;

    // Each item is ~52px tall (dense ListTile); sub-menu row adds ~40px
    const itemHeight = 52.0;
    const subMenuHeight = 40.0;
    final extraHeight = _mentionSubMenuIndex != null ? subMenuHeight : 0.0;
    final maxHeight = (totalCount * itemHeight + extraHeight).clamp(0.0, 220.0);

    return FocusScope(
      canRequestFocus: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: ListView.builder(
          controller: _mentionScrollController,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: totalCount,
          itemBuilder: (context, index) {
          final isSelected = index == _mentionSelectedIndex;
          final showSubMenu = _mentionSubMenuIndex == index;

          Widget itemTile;
          if (showAll && index == 0) {
            itemTile = _buildMentionAllTile(isSelected, showSubMenu);
          } else {
            final agentIndex = showAll ? index - 1 : index;
            final agent = filtered[agentIndex];
            itemTile = _buildMentionAgentTile(agent, isSelected, showSubMenu, index);
          }

          if (showSubMenu) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                itemTile,
                _buildInlineSubMenu(),
              ],
            );
          }
          return itemTile;
        },
      ),
      ),
    );
  }

  Widget _buildMentionAllTile(bool isSelected, bool showSubMenu) {
    return InkWell(
      canRequestFocus: false,
      onTap: () {
        setState(() {
          _mentionSelectedIndex = 0;
          _mentionSubMenuIndex = 0;
          _mentionSubMenuSelectedIndex = 0;
        });
        widget.textFieldFocusNode.requestFocus();
      },
      child: Container(
        color: isSelected ? AppColors.primary.withOpacity(0.08) : null,
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isSelected ? Colors.orange[200] : Colors.orange[100],
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.group, size: 16, color: Colors.orange[800]),
          ),
          title: Text(
            AppLocalizations.of(context).chat_mentionAll,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            AppLocalizations.of(context).chat_mentionAllSub(widget.groupAgents.length),
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
          trailing: isSelected
              ? const Icon(Icons.chevron_right, size: 16, color: AppColors.primary)
              : null,
        ),
      ),
    );
  }

  Widget _buildMentionAgentTile(
    dynamic agent,
    bool isSelected,
    bool showSubMenu,
    int index,
  ) {
    return InkWell(
      canRequestFocus: false,
      onTap: () {
        setState(() {
          _mentionSelectedIndex = index;
          _mentionSubMenuIndex = index;
          _mentionSubMenuSelectedIndex = 0;
        });
        widget.textFieldFocusNode.requestFocus();
      },
      child: Container(
        color: isSelected ? AppColors.primary.withOpacity(0.08) : null,
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primaryLight : AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          title: Text(
            agent.name,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          trailing: isSelected
              ? const Icon(Icons.chevron_right, size: 16, color: AppColors.primary)
              : null,
        ),
      ),
    );
  }

  Widget _buildInlineSubMenu() {
    final notifySelected = _mentionSubMenuSelectedIndex == 0;
    final ccSelected = _mentionSubMenuSelectedIndex == 1;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(
          top: BorderSide(color: Colors.grey[200]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              canRequestFocus: false,
              onTap: () => _confirmSubMenuSelection(0),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: notifySelected
                      ? Theme.of(context).primaryColor.withOpacity(0.12)
                      : null,
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 14,
                      color: notifySelected
                          ? Theme.of(context).primaryColor
                          : Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      AppLocalizations.of(context).chat_mentionNotify,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: notifySelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: notifySelected
                            ? Theme.of(context).primaryColor
                            : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(width: 0.5, color: Colors.grey[300]),
          Expanded(
            child: InkWell(
              canRequestFocus: false,
              onTap: () => _confirmSubMenuSelection(1),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ccSelected
                      ? Colors.orange.withOpacity(0.12)
                      : null,
                  borderRadius: const BorderRadius.only(
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.push_pin_outlined,
                      size: 14,
                      color: ccSelected ? Colors.orange[700] : Colors.grey[600],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      AppLocalizations.of(context).chat_mentionCcOnly,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            ccSelected ? FontWeight.w600 : FontWeight.normal,
                        color: ccSelected
                            ? Colors.orange[700]
                            : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmSubMenuSelection(int subIndex) {
    final subMenuIdx = _mentionSubMenuIndex;
    if (subMenuIdx == null) return;
    final notify = subIndex == 0;

    final showAll = _mentionAllMatches(_mentionQuery.toLowerCase());
    if (showAll && subMenuIdx == 0) {
      _insertMentionAllDirect(notify);
    } else {
      final filtered = _getFilteredMentionAgents();
      final agentIndex = showAll ? subMenuIdx - 1 : subMenuIdx;
      if (agentIndex >= 0 && agentIndex < filtered.length) {
        _insertMentionDirect(filtered[agentIndex], notify);
      }
    }
    // Ensure focus returns to text field after mention insertion
    _refocusTextField();
  }

  void _scrollToSelectedItem() {
    if (!_mentionScrollController.hasClients) return;
    const itemHeight = 52.0;
    const subMenuHeight = 40.0;
    final index = _mentionSelectedIndex;
    final subMenuIdx = _mentionSubMenuIndex;
    // Calculate offset including sub-menu expansion
    double offset = 0;
    for (int i = 0; i < index; i++) {
      offset += itemHeight;
      if (subMenuIdx != null && subMenuIdx == i) offset += subMenuHeight;
    }
    final viewportHeight = _mentionScrollController.position.viewportDimension;
    final currentOffset = _mentionScrollController.offset;
    final itemBottom = offset + itemHeight;
    if (offset < currentOffset) {
      _mentionScrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    } else if (itemBottom > currentOffset + viewportHeight) {
      _mentionScrollController.animateTo(
        itemBottom - viewportHeight,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Desktop input area
  // ---------------------------------------------------------------------------

  Widget _buildDesktopInputArea() {
    // WeChat-style desktop composer:
    // text area on top; attachment icons + Send share one bottom toolbar.
    final l10n = AppLocalizations.of(context);
    const iconColor = Color(0xFF4C4C4C);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        border: Border(
          top: BorderSide(color: Color(0xFFE7E7E7), width: 1),
        ),
      ),
      child: TapRegion(
        groupId: _emojiTapGroup,
        child: TapRegion(
          groupId: _attachmentTapGroup,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPendingAttachmentsPreview(),
              // Multi-line text area
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Actions(
                  actions: widget.onDesktopPaste != null
                      ? {
                          PasteTextIntent: CallbackAction<PasteTextIntent>(
                            onInvoke: (intent) async {
                              final handled = await widget.onDesktopPaste!();
                              if (!handled) {
                                // Not a file/image — paste plain text into the controller
                                final data =
                                    await Clipboard.getData(Clipboard.kTextPlain);
                                final text = data?.text;
                                if (text != null && text.isNotEmpty) {
                                  final ctrl = widget.messageController;
                                  final sel = ctrl.selection;
                                  final newText = ctrl.text.replaceRange(
                                    sel.start < 0 ? ctrl.text.length : sel.start,
                                    sel.end < 0 ? ctrl.text.length : sel.end,
                                    text,
                                  );
                                  final newOffset = (sel.start < 0
                                          ? ctrl.text.length
                                          : sel.start) +
                                      text.length;
                                  ctrl.value = ctrl.value.copyWith(
                                    text: newText,
                                    selection: TextSelection.collapsed(
                                        offset: newOffset),
                                  );
                                }
                              }
                              return null;
                            },
                          ),
                        }
                      : const {},
                  child: Focus(
                    onKeyEvent: _handleInputKeyEvent,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 100,
                        maxHeight: 220,
                      ),
                      child: TextField(
                        controller: widget.messageController,
                        focusNode: widget.textFieldFocusNode,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: l10n.chat_messageHint,
                          hintStyle: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[400],
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 8),
                        ),
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        enabled: !widget.isLoading,
                      ),
                    ),
                  ),
                ),
              ),
              // Bottom toolbar: icons left, Send right
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 10),
                child: Row(
                  children: [
                    _buildDesktopToolbarIcon(
                      key: _emojiButtonKey,
                      icon: Icons.sentiment_satisfied_alt_outlined,
                      color: iconColor,
                      tooltip: 'Emoji',
                      onPressed: _toggleDesktopEmojiPopover,
                    ),
                    _buildDesktopToolbarIcon(
                      key: _attachmentButtonKey,
                      icon: Icons.folder_open_outlined,
                      color: iconColor,
                      tooltip: 'Attachment',
                      onPressed: _toggleDesktopAttachmentPopover,
                    ),
                    const Spacer(),
                    if (widget.isLoading)
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).primaryColor,
                        ),
                      )
                    else
                      _buildDesktopSendButton(l10n.chat_send),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopToolbarIcon({
    Key? key,
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      icon: Icon(icon, size: 22),
      color: color,
      onPressed: onPressed,
      tooltip: tooltip,
      splashRadius: 18,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildDesktopSendButton(String label) {
    final enabled = _canSend;
    final primary = Theme.of(context).primaryColor;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: enabled
            ? () {
                _removeDesktopEmojiOverlay();
                _removeDesktopAttachmentOverlay();
                widget.onSend();
              }
            : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          constraints: const BoxConstraints(minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color(0xFFE0E0E0),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: enabled ? primary : Colors.grey[400],
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleDesktopEmojiPopover() {
    if (_desktopEmojiOpen) {
      _removeDesktopEmojiOverlay();
      return;
    }
    _removeDesktopAttachmentOverlay();
    _showDesktopEmojiOverlay();
  }

  void _showDesktopEmojiOverlay() {
    _removeDesktopEmojiOverlay(updateState: false);

    final overlay = Overlay.of(context, rootOverlay: true);
    final buttonBox =
        _emojiButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (buttonBox == null || overlayBox == null || !buttonBox.hasSize) {
      return;
    }

    const popoverWidth = 360.0;
    const popoverHeight = 320.0;
    const caretSize = Size(14, 8);
    const gap = 6.0;
    const edgePadding = 8.0;

    final buttonTopLeft =
        overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero));
    final buttonCenterX = buttonTopLeft.dx + buttonBox.size.width / 2;
    final buttonTop = buttonTopLeft.dy;

    var left = buttonCenterX - popoverWidth / 2;
    left = left.clamp(
      edgePadding,
      math.max(edgePadding, overlayBox.size.width - popoverWidth - edgePadding),
    );
    final panelHeight = popoverHeight + caretSize.height;
    var top = buttonTop - gap - panelHeight;
    top = top.clamp(
      edgePadding,
      math.max(edgePadding, overlayBox.size.height - panelHeight - edgePadding),
    );
    // Keep the caret aimed at the emoji button even when the panel is
    // shifted horizontally to stay on-screen.
    final caretLeft =
        (buttonCenterX - left - caretSize.width / 2).clamp(8.0, popoverWidth - 22.0);

    final primary = Theme.of(context).primaryColor;

    _emojiOverlay = OverlayEntry(
      builder: (context) {
        return Positioned(
          left: left,
          top: top,
          width: popoverWidth,
          child: TapRegion(
            groupId: _emojiTapGroup,
            onTapOutside: (_) => _removeDesktopEmojiOverlay(),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: popoverWidth,
                    height: popoverHeight,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: EmojiPicker(
                      onEmojiSelected: (_, emoji) =>
                          _insertDesktopEmoji(emoji.emoji),
                      onBackspacePressed: _desktopEmojiBackspace,
                      config: Config(
                        height: popoverHeight,
                        checkPlatformCompatibility: true,
                        emojiViewConfig: const EmojiViewConfig(
                          emojiSizeMax: 28,
                          backgroundColor: Colors.white,
                          columns: 8,
                        ),
                        categoryViewConfig: CategoryViewConfig(
                          indicatorColor: primary,
                          iconColorSelected: primary,
                          backgroundColor: Colors.white,
                          dividerColor: const Color(0xFFE7E7E7),
                        ),
                        bottomActionBarConfig: const BottomActionBarConfig(
                          enabled: false,
                        ),
                        searchViewConfig: const SearchViewConfig(
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  // Caret pointing down to the emoji button
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: caretLeft),
                      child: CustomPaint(
                        size: caretSize,
                        painter: _PopoverCaretPainter(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(_emojiOverlay!);
    setState(() => _desktopEmojiOpen = true);
  }

  void _removeDesktopEmojiOverlay({bool updateState = true}) {
    _emojiOverlay?.remove();
    _emojiOverlay = null;
    if (_desktopEmojiOpen) {
      _desktopEmojiOpen = false;
      if (updateState && mounted) setState(() {});
    }
  }

  void _insertDesktopEmoji(String emoji) {
    final ctrl = widget.messageController;
    final text = ctrl.text;
    final selection = ctrl.selection;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final newText = text.replaceRange(start, end, emoji);
    final newOffset = start + emoji.length;
    ctrl.value = ctrl.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _removeDesktopEmojiOverlay();
    // Keep focus in the composer so the user can keep typing.
    widget.textFieldFocusNode.requestFocus();
  }

  void _desktopEmojiBackspace() {
    final ctrl = widget.messageController;
    final text = ctrl.text;
    final selection = ctrl.selection;
    final cursorPos = selection.baseOffset;
    if (cursorPos > 0 && text.isNotEmpty) {
      final newText =
          text.substring(0, cursorPos - 1) + text.substring(cursorPos);
      ctrl.value = ctrl.value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: cursorPos - 1),
      );
    }
    widget.textFieldFocusNode.requestFocus();
  }

  void _toggleDesktopAttachmentPopover() {
    if (_desktopAttachmentOpen) {
      _removeDesktopAttachmentOverlay();
      return;
    }
    _removeDesktopEmojiOverlay();
    _showDesktopAttachmentOverlay();
  }

  void _showDesktopAttachmentOverlay() {
    _removeDesktopAttachmentOverlay(updateState: false);

    final overlay = Overlay.of(context, rootOverlay: true);
    final buttonBox =
        _attachmentButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (buttonBox == null || overlayBox == null || !buttonBox.hasSize) {
      return;
    }

    const popoverWidth = 200.0;
    const caretSize = Size(14, 8);
    const gap = 6.0;
    const edgePadding = 8.0;

    final buttonTopLeft =
        overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero));
    final buttonCenterX = buttonTopLeft.dx + buttonBox.size.width / 2;
    final buttonTop = buttonTopLeft.dy;

    var left = buttonCenterX - popoverWidth / 2;
    left = left.clamp(
      edgePadding,
      math.max(edgePadding, overlayBox.size.width - popoverWidth - edgePadding),
    );

    final l10n = AppLocalizations.of(context);
    final iconColor = Colors.grey[700]!;

    // Fixed height matching two menu rows (+ padding).
    const itemHeight = 44.0;
    const verticalPadding = 8.0;
    const itemCount = 2;
    const popoverHeight = itemCount * itemHeight + verticalPadding * 2;
    const panelHeight = popoverHeight + caretSize.height;
    var top = buttonTop - gap - panelHeight;
    top = top.clamp(
      edgePadding,
      math.max(edgePadding, overlayBox.size.height - panelHeight - edgePadding),
    );
    final caretLeft =
        (buttonCenterX - left - caretSize.width / 2).clamp(8.0, popoverWidth - 22.0);

    void select(VoidCallback action) {
      _removeDesktopAttachmentOverlay();
      action();
    }

    _attachmentOverlay = OverlayEntry(
      builder: (context) {
        return Positioned(
          left: left,
          top: top,
          width: popoverWidth,
          child: TapRegion(
            groupId: _attachmentTapGroup,
            onTapOutside: (_) => _removeDesktopAttachmentOverlay(),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: popoverWidth,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: verticalPadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildDesktopAttachmentMenuItem(
                            icon: Icons.insert_drive_file_outlined,
                            iconColor: iconColor,
                            label: l10n.chat_file,
                            onTap: () => select(widget.onPickFile),
                          ),
                          _buildDesktopAttachmentMenuItem(
                            icon: Icons.inventory_2_outlined,
                            iconColor: iconColor,
                            label: l10n.chat_storageBag,
                            onTap: () => select(widget.onPickFromStorageBag),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: caretLeft),
                      child: CustomPaint(
                        size: caretSize,
                        painter: _PopoverCaretPainter(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(_attachmentOverlay!);
    setState(() => _desktopAttachmentOpen = true);
  }

  Widget _buildDesktopAttachmentMenuItem({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _removeDesktopAttachmentOverlay({bool updateState = true}) {
    _attachmentOverlay?.remove();
    _attachmentOverlay = null;
    if (_desktopAttachmentOpen) {
      _desktopAttachmentOpen = false;
      if (updateState && mounted) setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Mobile input area
  // ---------------------------------------------------------------------------

  Widget _buildMobileInputArea() {
    final hasPendingAttachments = widget.pendingAttachments.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPendingAttachmentsPreview(),
            Row(
              children: [
                if (widget.hasAudioModel)
                  IconButton(
                    icon: Icon(
                      _isVoiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none,
                    ),
                    color: Colors.grey[600],
                    onPressed: () {
                      setState(() {
                        _isVoiceMode = !_isVoiceMode;
                      });
                      if (!_isVoiceMode) {
                        widget.textFieldFocusNode.requestFocus();
                      }
                    },
                  ),
                IconButton(
                  icon: Icon(
                    widget.showEmojiPicker
                        ? Icons.keyboard
                        : Icons.emoji_emotions_outlined,
                  ),
                  color: Colors.grey[600],
                  onPressed: widget.onToggleEmojiPicker,
                ),
                Expanded(
                  child: _isVoiceMode
                      ? _buildHoldToTalkButton()
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Focus(
                            onKeyEvent: _handleInputKeyEvent,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 150),
                              child: TextField(
                                controller: widget.messageController,
                                focusNode: widget.textFieldFocusNode,
                                decoration: InputDecoration(
                                  hintText: AppLocalizations.of(context).chat_messageHint,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                                maxLines: null,
                                textInputAction: TextInputAction.newline,
                                enabled: !widget.isLoading,
                              ),
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  color: Colors.grey[600],
                  onPressed: widget.onShowAttachmentOptions,
                ),
                if (!_isVoiceMode)
                  widget.isLoading
                      ? Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        )
                      : (_hasText || hasPendingAttachments)
                              ? IconButton(
                                  icon: const Icon(Icons.send),
                                  color: Theme.of(context).primaryColor,
                                  onPressed: widget.onSend,
                                )
                              : const SizedBox.shrink(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hold to talk button
  // ---------------------------------------------------------------------------

  Widget _buildHoldToTalkButton() {
    return GestureDetector(
      onLongPressStart: (_) {
        widget.audioRecordingService.startRecording().then((success) {
          if (!success && mounted) {
            showTopToast(
              context,
              AppLocalizations.of(context).chat_micNotAvailable,
              icon: Icons.mic_off,
              color: Colors.orange,
            );
          }
        });
      },
      onLongPressMoveUpdate: (details) {
        // Cancel zone is handled by parent widget
      },
      onLongPressEnd: (_) async {
        if (widget.isCancelZone) {
          await widget.audioRecordingService.cancelRecording();
        } else {
          widget.onSendVoice?.call();
        }
      },
      onLongPressCancel: () async {
        // On Samsung devices, edge panel gestures can steal focus and cancel
        // the long press without triggering onLongPressEnd. Stop/cancel the
        // recording so it doesn't keep running in the background.
        if (widget.audioRecordingService.currentState.isRecording) {
          await widget.audioRecordingService.cancelRecording();
        }
      },
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: widget.isRecording ? Colors.grey[300] : Colors.grey[100],
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.grey[300]!,
            width: 0.5,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          widget.isRecording
              ? (widget.isCancelZone
                  ? AppLocalizations.of(context).chat_releaseToCancel
                  : AppLocalizations.of(context).chat_releaseToSend)
              : AppLocalizations.of(context).chat_holdToTalk,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Colors.grey[700],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pending attachments preview
  // ---------------------------------------------------------------------------

  Widget _buildPendingAttachmentsPreview() {
    if (widget.pendingAttachments.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey[200]!, width: 0.5),
        ),
      ),
      child: SizedBox(
        height: 88,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: widget.pendingAttachments.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final att = widget.pendingAttachments[index];
            if (att.type == PendingAttachmentType.image) {
              return _buildImagePreviewItem(att);
            } else {
              return _buildFilePreviewItem(att);
            }
          },
        ),
      ),
    );
  }

  Widget _buildImagePreviewItem(PendingAttachment att) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: att.thumbnailBytes != null
              ? Image.memory(
                  att.thumbnailBytes!,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                )
              : Container(
                  width: 80,
                  height: 80,
                  color: Colors.grey[200],
                  child: const Icon(Icons.image, color: Colors.grey),
                ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => widget.onRemoveAttachment(att),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilePreviewItem(PendingAttachment att) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 160,
          height: 80,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[300]!),
          ),
          child: Row(
            children: [
              const Icon(Icons.insert_drive_file, size: 32, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      att.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      PendingAttachment.formatFileSize(att.fileSize),
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => widget.onRemoveAttachment(att),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Key event handling
  // ---------------------------------------------------------------------------

  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Slash palette takes precedence over mention picker when active: if
    // the user just typed "/", they want slash-command completion, not
    // message send or @mention submenus.
    if (_showSlashPicker) {
      final filtered =
          SlashCommandPicker.filter(_slashCommands, _slashQuery);
      if (filtered.isNotEmpty) {
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          setState(() {
            _slashSelectedIndex = (_slashSelectedIndex + 1) % filtered.length;
          });
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(() {
            _slashSelectedIndex =
                (_slashSelectedIndex - 1 + filtered.length) % filtered.length;
          });
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) {
          // Pick the highlighted command and insert it — do NOT send.
          if (widget.messageController.value.composing == TextRange.empty &&
              !HardwareKeyboard.instance.isShiftPressed) {
            _applySlashCommand(filtered[_slashSelectedIndex]);
            return KeyEventResult.handled;
          }
        }
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          _applySlashCommand(filtered[_slashSelectedIndex]);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          setState(() {
            _showSlashPicker = false;
            _slashTriggerOffset = -1;
            _slashQuery = '';
          });
          return KeyEventResult.handled;
        }
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (widget.messageController.value.composing != TextRange.empty) {
        return KeyEventResult.ignored;
      }
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      if (_showMentionPicker) {
        if (_mentionSubMenuIndex != null) {
          // Confirm sub-menu selection with Enter
          _confirmSubMenuSelection(_mentionSubMenuSelectedIndex);
        } else {
          // Open sub-menu for the selected item
          setState(() {
            _mentionSubMenuIndex = _mentionSelectedIndex;
            _mentionSubMenuSelectedIndex = 0;
          });
          _refocusTextField();
        }
        return KeyEventResult.handled;
      }
      widget.onSend();
      _removeDesktopEmojiOverlay();
      _removeDesktopAttachmentOverlay();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (_desktopEmojiOpen || _desktopAttachmentOpen)) {
      _removeDesktopEmojiOverlay();
      _removeDesktopAttachmentOverlay();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape && _showMentionPicker) {
      if (_mentionSubMenuIndex != null) {
        setState(() { _mentionSubMenuIndex = null; });
      } else {
        setState(() { _showMentionPicker = false; });
        widget.onMentionPickerChanged?.call();
      }
      return KeyEventResult.handled;
    }

    // Left/Right switch sub-menu option when sub-menu is open
    if (_showMentionPicker && _mentionSubMenuIndex != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        setState(() { _mentionSubMenuSelectedIndex = 0; });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        setState(() { _mentionSubMenuSelectedIndex = 1; });
        return KeyEventResult.handled;
      }
    }

    // Up/Down always move through members (sub-menu follows the selected item)
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && _showMentionPicker) {
      final totalCount = _getMentionPickerItemCount(_mentionQuery);
      if (totalCount > 0) {
        final newIndex = (_mentionSelectedIndex - 1).clamp(0, totalCount - 1);
        setState(() {
          _mentionSelectedIndex = newIndex;
          // Keep sub-menu open and follow the new selected item
          if (_mentionSubMenuIndex != null) {
            _mentionSubMenuIndex = newIndex;
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelectedItem());
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && _showMentionPicker) {
      final totalCount = _getMentionPickerItemCount(_mentionQuery);
      if (totalCount > 0) {
        final newIndex = (_mentionSelectedIndex + 1).clamp(0, totalCount - 1);
        setState(() {
          _mentionSelectedIndex = newIndex;
          // Keep sub-menu open and follow the new selected item
          if (_mentionSubMenuIndex != null) {
            _mentionSubMenuIndex = newIndex;
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelectedItem());
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // Mention picker logic
  // ---------------------------------------------------------------------------

  void _detectMentionTrigger() {
    final text = widget.messageController.text;
    final selection = widget.messageController.selection;
    final cursorPos = selection.baseOffset;

    if (cursorPos < 0 || cursorPos > text.length) {
      if (_showMentionPicker) {
        setState(() { _showMentionPicker = false; });
        widget.onMentionPickerChanged?.call();
      }
      return;
    }

    int atPos = -1;
    for (int i = cursorPos - 1; i >= 0; i--) {
      final char = text[i];
      if (char == '@') {
        if (i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n') {
          atPos = i;
        }
        break;
      }
      if (char == ' ' || char == '\n') break;
    }

    if (atPos >= 0) {
      final query = text.substring(atPos + 1, cursorPos).toLowerCase();
      final totalCount = _getMentionPickerItemCount(query);

      if (totalCount > 0) {
        final wasShowing = _showMentionPicker;
        final queryChanged = query != _mentionQuery;
        setState(() {
          _showMentionPicker = true;
          _mentionQuery = query;
          _mentionTriggerOffset = atPos;
          if (queryChanged) {
            _mentionSelectedIndex = 0;
            _mentionSubMenuIndex = null;
          }
          if (_mentionSelectedIndex >= totalCount) {
            _mentionSelectedIndex = totalCount - 1;
            _mentionSubMenuIndex = null;
          }
        });
        if (!wasShowing) {
          widget.onMentionPickerChanged?.call();
        }
        return;
      }
    }

    if (_showMentionPicker) {
      setState(() { _showMentionPicker = false; });
      widget.onMentionPickerChanged?.call();
    }
  }

  /// Detect a `/` trigger at a word boundary (line start or preceded by
  /// whitespace), populate the slash palette query from the text between
  /// `/` and the caret. Mirrors [_detectMentionTrigger].
  void _detectSlashTrigger() {
    // Live-resolve the current command list on every call. This sidesteps
    // the race between ACP connection creation and widget subscription:
    // even if [slashCommandsStream] was null when this widget first
    // mounted, the resolver reads directly from the connection on each
    // keystroke, so the palette fires as soon as the agent has pushed or
    // responded with the command list.
    if (widget.slashCommandsResolver != null) {
      _slashCommands = widget.slashCommandsResolver!();
    }
    if (_slashCommands.isEmpty) {
      if (_showSlashPicker) {
        setState(() {
          _showSlashPicker = false;
          _slashTriggerOffset = -1;
          _slashQuery = '';
        });
      }
      return;
    }

    final text = widget.messageController.text;
    final selection = widget.messageController.selection;
    final cursorPos = selection.baseOffset;

    if (cursorPos < 0 || cursorPos > text.length) {
      if (_showSlashPicker) {
        setState(() => _showSlashPicker = false);
      }
      return;
    }

    int slashPos = -1;
    for (int i = cursorPos - 1; i >= 0; i--) {
      final char = text[i];
      if (char == '/') {
        if (i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n') {
          slashPos = i;
        }
        break;
      }
      // Only allow [a-zA-Z0-9_-:] inside a slash-command token, break on
      // anything else so "path/to/file" doesn't accidentally trigger.
      final code = char.codeUnitAt(0);
      final isAlnum = (code >= 48 && code <= 57) ||
          (code >= 65 && code <= 90) ||
          (code >= 97 && code <= 122);
      if (!isAlnum && char != '_' && char != '-' && char != ':') break;
    }

    if (slashPos >= 0) {
      final query = text.substring(slashPos + 1, cursorPos);
      final filtered = SlashCommandPicker.filter(_slashCommands, query);
      if (filtered.isNotEmpty) {
        final queryChanged = query != _slashQuery;
        setState(() {
          _showSlashPicker = true;
          _slashQuery = query;
          _slashTriggerOffset = slashPos;
          if (queryChanged) _slashSelectedIndex = 0;
          if (_slashSelectedIndex >= filtered.length) {
            _slashSelectedIndex = filtered.length - 1;
          }
        });
        return;
      }
    }

    if (_showSlashPicker) {
      setState(() {
        _showSlashPicker = false;
        _slashTriggerOffset = -1;
        _slashQuery = '';
      });
    }
  }

  /// Replace the `/<query>` range with `/<cmd.name> ` and dismiss the
  /// palette. Guarded by [_insertingMention] so the resulting text-change
  /// doesn't re-trigger detection in a loop.
  void _applySlashCommand(SlashCommandInfo cmd) {
    if (_slashTriggerOffset < 0) return;
    final text = widget.messageController.text;
    final cursorPos = widget.messageController.selection.baseOffset;
    if (cursorPos < _slashTriggerOffset) return;

    final insert = '/${cmd.name} ';
    final newText =
        text.substring(0, _slashTriggerOffset) + insert + text.substring(cursorPos);
    final newCursor = _slashTriggerOffset + insert.length;

    _insertingMention = true;
    widget.messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _insertingMention = false;

    setState(() {
      _showSlashPicker = false;
      _slashTriggerOffset = -1;
      _slashQuery = '';
    });

    // Keep focus in the TextField so the user can keep typing arguments
    // (e.g. `/plan <ticket>`) without having to click back in.
    widget.textFieldFocusNode.requestFocus();
  }

  bool get showSlashPicker => _showSlashPicker;

  bool _mentionAllMatches(String query) {
    return 'all'.contains(query);
  }

  int _getMentionPickerItemCount(String query) {
    final q = query.toLowerCase();
    final agentCount = widget.groupAgents.where(
      (a) => a.name.toLowerCase().contains(q),
    ).length;
    final allCount = _mentionAllMatches(q) ? 1 : 0;
    return allCount + agentCount;
  }

  List<RemoteAgent> _getFilteredMentionAgents() {
    return widget.groupAgents.where(
      (a) => a.name.toLowerCase().contains(_mentionQuery.toLowerCase()),
    ).toList();
  }

  void _insertMentionAtCursor(RemoteAgent agent) async {
    final notify = await _showMentionNotifyMenu(agent.name);
    if (notify == null) return;
    _insertMentionDirect(agent, notify);
    // showMenu dismiss animation takes time; use a longer delay to ensure focus
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) widget.textFieldFocusNode.requestFocus();
    });
  }

  void _insertMentionDirect(RemoteAgent agent, bool notify) {
    _insertMentionText('@${agent.name} ');
    _pendingMentions.removeWhere((m) => m.id == agent.id);
    _pendingMentions.add(MentionEntry(id: agent.id, name: agent.name, notify: notify));
  }

  void _insertMentionAllDirect(bool notify) {
    _insertMentionText('@all ');
    _pendingMentions.removeWhere((m) => m.id == 'all');
    _pendingMentions.add(MentionEntry(id: 'all', name: 'all', notify: notify));
  }

  Future<bool?> _showMentionNotifyMenu(String name) async {
    final RenderBox? overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return true;
    final overlaySize = overlayBox.size;
    // Position menu near bottom-center of the screen
    final rect = Rect.fromLTWH(
      overlaySize.width / 2 - 80,
      overlaySize.height - 200,
      160,
      0,
    );
    return showMenu<bool>(
      context: context,
      position: RelativeRect.fromSize(rect, overlaySize),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: [
              const Icon(Icons.notifications_active_outlined, size: 18),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context).chat_mentionNotify),
            ],
          ),
        ),
        PopupMenuItem<bool>(
          value: false,
          child: Row(
            children: [
              const Icon(Icons.push_pin_outlined, size: 18),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context).chat_mentionCcOnly),
            ],
          ),
        ),
      ],
    );
  }

  void _insertMentionText(String mentionText) {
    _insertingMention = true;

    final text = widget.messageController.text;
    final selection = widget.messageController.selection;
    final cursorPos = selection.baseOffset;

    if (_mentionTriggerOffset >= 0 && cursorPos >= 0) {
      final newText = text.substring(0, _mentionTriggerOffset) +
          mentionText +
          text.substring(cursorPos);
      final newCursorPos = _mentionTriggerOffset + mentionText.length;
      widget.messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newCursorPos),
      );
    } else {
      final newText = text + mentionText;
      widget.messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }

    setState(() {
      _showMentionPicker = false;
      _mentionTriggerOffset = -1;
      _mentionQuery = '';
      _mentionSelectedIndex = 0;
      _mentionSubMenuIndex = null;
    });
    widget.onMentionPickerChanged?.call();

    _insertingMention = false;
    _refocusTextField();
  }

  void _refocusTextField() {
    widget.textFieldFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.textFieldFocusNode.requestFocus();
        // After the next frame (layout fully settled after widget removal)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.textFieldFocusNode.requestFocus();
        });
      }
    });
    // Fallback for mobile: touch-up or keyboard events can unfocus after frame callbacks
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted && !widget.textFieldFocusNode.hasFocus) {
        widget.textFieldFocusNode.requestFocus();
      }
    });
  }

  /// Public method to insert a mention for a specific agent (called from parent).
  void insertMentionForAgent(RemoteAgent agent) {
    _insertMentionAtCursor(agent);
    // Focus will be requested after the async menu completes inside _insertMentionAtCursor
  }
}

/// Downward-pointing caret under desktop toolbar popovers (WeChat style).
class _PopoverCaretPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    // Soft shadow under caret
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.18), 2, true);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
