import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/acp_protocol.dart';
import '../../models/mention_entry.dart';
import '../../models/pending_attachment.dart';
import '../../models/remote_agent.dart';
import '../../services/audio_recording_service.dart';
import '../../utils/layout_utils.dart';
import '../../l10n/app_localizations.dart';
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
    this.onSendVoice,
    required this.showEmojiPicker,
    required this.onRemoveAttachment,
    this.onMentionPickerChanged,
    this.onDesktopPaste,
    this.hasAudioModel = false,
    this.slashCommands = const [],
    this.slashCommandsStream,
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

  @override
  void initState() {
    super.initState();
    _hasText = widget.messageController.text.isNotEmpty;
    widget.messageController.addListener(_onTextChanged);
    _slashCommands = widget.slashCommands;
    _slashCommandsSub = widget.slashCommandsStream?.listen((next) {
      if (!mounted) return;
      setState(() {
        _slashCommands = next;
      });
    });
  }

  @override
  void dispose() {
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
      _slashCommands = widget.slashCommands;
    }
    if (!identical(oldWidget.slashCommandsStream, widget.slashCommandsStream)) {
      _slashCommandsSub?.cancel();
      _slashCommandsSub = widget.slashCommandsStream?.listen((next) {
        if (!mounted) return;
        setState(() {
          _slashCommands = next;
        });
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
    if (!showMention && !showSlash) return inputArea;
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

    return Container(
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
    );
  }

  Widget _buildMentionAllTile(bool isSelected, bool showSubMenu) {
    return InkWell(
      onTap: () {
        setState(() {
          _mentionSelectedIndex = 0;
          _mentionSubMenuIndex = 0;
          _mentionSubMenuSelectedIndex = 0;
        });
        widget.textFieldFocusNode.requestFocus();
      },
      child: Container(
        color: isSelected ? Colors.blue.withOpacity(0.08) : null,
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
              ? Icon(Icons.chevron_right, size: 16, color: Colors.blue[400])
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
      onTap: () {
        setState(() {
          _mentionSelectedIndex = index;
          _mentionSubMenuIndex = index;
          _mentionSubMenuSelectedIndex = 0;
        });
        widget.textFieldFocusNode.requestFocus();
      },
      child: Container(
        color: isSelected ? Colors.blue.withOpacity(0.08) : null,
        child: ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isSelected ? Colors.blue[200] : Colors.blue[100],
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              agent.name.isNotEmpty ? agent.name[0].toUpperCase() : '?',
              style: TextStyle(
                color: Colors.blue[700],
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
              ? Icon(Icons.chevron_right, size: 16, color: Colors.blue[400])
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
    return Container(
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey[200]!, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    widget.showEmojiPicker
                        ? Icons.keyboard
                        : Icons.emoji_emotions_outlined,
                    size: 22,
                  ),
                  color: Colors.grey[600],
                  onPressed: widget.onToggleEmojiPicker,
                  tooltip: 'Emoji',
                  splashRadius: 18,
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file, size: 22),
                  color: Colors.grey[600],
                  onPressed: widget.onShowAttachmentOptions,
                  tooltip: 'Attachment',
                  splashRadius: 18,
                ),
              ],
            ),
          ),
          _buildPendingAttachmentsPreview(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Actions(
                    actions: widget.onDesktopPaste != null
                        ? {
                            PasteTextIntent: CallbackAction<PasteTextIntent>(
                              onInvoke: (intent) async {
                                final handled = await widget.onDesktopPaste!();
                                if (!handled) {
                                  // Not a file/image — paste plain text into the controller
                                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                                  final text = data?.text;
                                  if (text != null && text.isNotEmpty) {
                                    final ctrl = widget.messageController;
                                    final sel = ctrl.selection;
                                    final newText = ctrl.text.replaceRange(
                                      sel.start < 0 ? ctrl.text.length : sel.start,
                                      sel.end < 0 ? ctrl.text.length : sel.end,
                                      text,
                                    );
                                    final newOffset = (sel.start < 0 ? ctrl.text.length : sel.start) + text.length;
                                    ctrl.value = ctrl.value.copyWith(
                                      text: newText,
                                      selection: TextSelection.collapsed(offset: newOffset),
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
                          minHeight: 80,
                          maxHeight: 200,
                        ),
                        child: TextField(
                          controller: widget.messageController,
                          focusNode: widget.textFieldFocusNode,
                          decoration: InputDecoration(
                            hintText: AppLocalizations.of(context).chat_messageHint,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: widget.isLoading
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
                      : IconButton(
                              icon: const Icon(Icons.send),
                              color: _canSend
                                  ? Theme.of(context).primaryColor
                                  : Colors.grey[400],
                              onPressed: _canSend ? widget.onSend : null,
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.of(context).chat_micNotAvailable),
              ),
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
              Icon(Icons.insert_drive_file, size: 32, color: Colors.blue[400]),
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
          widget.textFieldFocusNode.requestFocus();
        }
        return KeyEventResult.handled;
      }
      widget.onSend();
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
  }

  /// Public hook for the parent chat screen to route keyboard events to
  /// the slash palette (↑/↓ to move selection, Enter to commit, Esc to
  /// dismiss). Returns true if the event was handled.
  bool handleSlashKeyEvent(KeyEvent event) {
    if (!_showSlashPicker) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final filtered = SlashCommandPicker.filter(_slashCommands, _slashQuery);
    if (filtered.isEmpty) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _slashSelectedIndex = (_slashSelectedIndex + 1) % filtered.length;
      });
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _slashSelectedIndex =
            (_slashSelectedIndex - 1 + filtered.length) % filtered.length;
      });
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _applySlashCommand(filtered[_slashSelectedIndex]);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _showSlashPicker = false;
        _slashTriggerOffset = -1;
      });
      return true;
    }
    return false;
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
      if (mounted) widget.textFieldFocusNode.requestFocus();
    });
    // Extra delay for mobile: touch-up events can unfocus after requestFocus
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) widget.textFieldFocusNode.requestFocus();
    });
  }

  /// Public method to insert a mention for a specific agent (called from parent).
  void insertMentionForAgent(RemoteAgent agent) {
    _insertMentionAtCursor(agent);
    // Focus will be requested after the async menu completes inside _insertMentionAtCursor
  }
}
