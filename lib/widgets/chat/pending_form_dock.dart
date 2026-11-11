import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../services/she_service.dart';
import '../form_field_shape.dart';
import '../action_confirmation_buttons.dart';
import '../file_upload_bubble.dart';
import '../multi_select_bubble.dart';
import '../single_select_bubble.dart';
import 'cli_approval_card.dart';
import 'paged_form_panel.dart';

enum DockedInteractionKind {
  form('form', 'submitted_values'),
  singleSelect('single_select', 'selected_option_id'),
  multiSelect('multi_select', 'selected_option_ids'),
  fileUpload('file_upload', 'uploaded_files'),
  approval('action_confirmation', 'selected_action_id');

  /// 卡片数据在消息 metadata 里的键。
  final String metadataKey;

  /// 作答后写下的键：有它就是答过了。
  final String answeredKey;

  const DockedInteractionKind(this.metadataKey, this.answeredKey);
}

/// 停靠在输入框上方、等用户处理的那一张卡。
class DockedInteraction {
  final Message message;
  final DockedInteractionKind kind;

  const DockedInteraction(this.message, this.kind);

  bool get isForm => kind == DockedInteractionKind.form;

  /// 等用户回答的提问（表单 / 单选 / 多选 / 上传），不是工具审批。
  bool get isQuestion => kind != DockedInteractionKind.approval;

  Map<String, dynamic>? get card =>
      FormFieldShape.stringKeyMap(message.metadata?[kind.metadataKey]);
}

/// 顺序与 `MessageBubble._buildInteractiveFooter` 一致：一条消息上只画
/// 第一张，停靠的也得是那一张。
const _questionKinds = [
  DockedInteractionKind.singleSelect,
  DockedInteractionKind.multiSelect,
  DockedInteractionKind.fileUpload,
  DockedInteractionKind.form,
];

/// 这条消息上还在等用户回答的提问卡：主机的提问（`ask_user` →
/// `agent_form_req`、hub 交互卡），或 She / 其他 agent 用 `form`、
/// `single_select`、`multi_select`、`file_upload` 工具发的卡。
///
/// 答过或作废（`closed`）的不算；deferred 的还能答，算。
DockedInteractionKind? pendingQuestionKind(Message message) {
  final metadata = message.metadata;
  if (metadata == null) return null;
  for (final kind in _questionKinds) {
    final card = metadata[kind.metadataKey];
    if (card is! Map) continue;
    if (card[kind.answeredKey] == null && card['closed'] == null) return kind;
    return null;
  }
  return null;
}

/// 主机提问卡（带 `peer_form`）是独立的卡片行：整条消息就是这张卡，列表里
/// 整行换成占位。其他提问挂在 agent 的回复气泡上，只换气泡底部的卡片区。
bool isStandaloneFormCard(Message message) {
  final form = message.metadata?['form'];
  return form is Map && form['peer_form'] is Map;
}

/// 主机会给这张卡收场（作答 / 超时 / 回合取消都有帧回来），不会一直悬着。
bool _isHostManagedQuestion(Message message) =>
    isStandaloneFormCard(message) ||
    message.metadata?['hub_interaction'] is Map;

bool _isUserMessage(Message message) =>
    message.from.type == 'user' && message.from.id != SheService.sheId;

/// 还没点的工具审批卡。工作流里的审批由工作流面板处理，不在此列。
bool isDockablePendingApproval(Message message) {
  final card = message.metadata?['action_confirmation'];
  if (card is! Map) return false;
  if (card['_workflowPeerApproval'] == true) return false;
  if (card['selected_action_id'] != null || card['closed'] != null) {
    return false;
  }
  final actions = card['actions'];
  return actions is List && actions.isNotEmpty;
}

/// 卡片落库时留下的会话归属（`card_channel_id`，主机会话 id 口径）。
/// 旧行没有这个字段，保持原来的停靠行为；带归属但不匹配当前会话的一律跳过。
bool _cardBelongsToChannel(Message message, String hostChannel) {
  if (hostChannel.isEmpty) return true;
  final cardChannel =
      message.metadata?['card_channel_id']?.toString().trim() ?? '';
  return cardChannel.isEmpty || cardChannel == hostChannel;
}

/// 取最新的一张待处理卡；其余留在消息流里照常显示。
///
/// [approvalIsLive] 判断审批卡此刻还有没有人在等（见
/// `ChatController.isApprovalCardLive`）；不传时不停靠任何审批卡。
///
/// agent 用工具发的提问没有主机侧的收场帧：用户没答、直接接着说话，它就
/// 一直是「未作答」。之后用户说过话的就不再停靠，留在消息流里还能补答。
DockedInteraction? dockedPendingInteraction(
  List<Message> messages, {
  bool Function(Message message)? approvalIsLive,
  String? channelId,
}) {
  final hostChannel =
      channelId == null ? '' : hostSessionIdForChannel(channelId);
  var userSpokeAfter = false;
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    // 多会话并发时列表里可能混着别的会话残留的卡（尤其是重开页面从 DB
    // 载入的行）。带归属但不匹配的一律不停靠，避免「在 A 会话答 B 的卡」。
    if (_cardBelongsToChannel(message, hostChannel) == false) continue;
    final question = pendingQuestionKind(message);
    if (question != null &&
        (!userSpokeAfter || _isHostManagedQuestion(message))) {
      return DockedInteraction(message, question);
    }
    if (_isUserMessage(message)) userSpokeAfter = true;
    if (isDockablePendingApproval(message) &&
        (approvalIsLive?.call(message) ?? false)) {
      return DockedInteraction(message, DockedInteractionKind.approval);
    }
  }
  return null;
}

/// 悬浮在输入框上方的待处理卡（提问 / 工具审批）。
///
/// 卡片以前只在消息流里：时间戳排序会把它放到正在输出的回复上面，或者被
/// 后续输出顶出视口，用户看不到主机在等他。停靠在输入框上方之后，处理完
/// 才收起；列表里同一张卡只画占位（见 [DockedInteractionPlaceholder]）。
class PendingInteractionDock extends StatefulWidget {
  final DockedInteraction interaction;
  /// 返回的 Future 完成之前，提交按钮保持忙碌态，防止重复提交。
  final Future<void> Function(Message message, String formId,
      Map<String, dynamic> values, String summary) onFormSubmitted;
  final void Function(Message message, String formId)? onFormDeclined;
  final void Function(Message message, String selectId, String optionId,
      String optionLabel)? onSingleSelectSubmitted;
  final void Function(Message message, String selectId,
      List<String> optionIds, String summary)? onMultiSelectSubmitted;
  final void Function(Message message, String uploadId,
      List<Map<String, dynamic>> files, String summary)? onFileUploadSubmitted;
  final void Function(Message message, String confirmationId,
      String actionId, String actionLabel) onActionSelected;
  final bool isAgentOffline;

  const PendingInteractionDock({
    super.key,
    required this.interaction,
    required this.onFormSubmitted,
    this.onFormDeclined,
    this.onSingleSelectSubmitted,
    this.onMultiSelectSubmitted,
    this.onFileUploadSubmitted,
    required this.onActionSelected,
    this.isAgentOffline = false,
  });

  @override
  State<PendingInteractionDock> createState() => _PendingInteractionDockState();
}

class _PendingInteractionDockState extends State<PendingInteractionDock> {
  bool _expanded = true;

  Widget? _buildBody() {
    final message = widget.interaction.message;
    final card = widget.interaction.card;
    if (card == null) return null;
    // 换了一张卡就换一份填写状态。
    final key = ValueKey(message.id);
    switch (widget.interaction.kind) {
      case DockedInteractionKind.form:
        return DockedFormBody(
          key: key,
          formData: card,
          onFormSubmitted: (formId, values, summary) =>
              widget.onFormSubmitted(message, formId, values, summary),
          onFormDeclined: widget.onFormDeclined == null
              ? null
              : (formId) => widget.onFormDeclined!(message, formId),
        );
      case DockedInteractionKind.singleSelect:
        final onSubmitted = widget.onSingleSelectSubmitted;
        return SingleSelectBubble(
          key: key,
          selectData: card,
          onSelectSubmitted: onSubmitted == null
              ? null
              : (selectId, optionId, label) =>
                  onSubmitted(message, selectId, optionId, label),
        );
      case DockedInteractionKind.multiSelect:
        final onSubmitted = widget.onMultiSelectSubmitted;
        return MultiSelectBubble(
          key: key,
          selectData: card,
          onSelectSubmitted: onSubmitted == null
              ? null
              : (selectId, optionIds, summary) =>
                  onSubmitted(message, selectId, optionIds, summary),
        );
      case DockedInteractionKind.fileUpload:
        final onSubmitted = widget.onFileUploadSubmitted;
        return FileUploadBubble(
          key: key,
          uploadData: card,
          onUploadSubmitted: onSubmitted == null
              ? null
              : (uploadId, files, summary) =>
                  onSubmitted(message, uploadId, files, summary),
        );
      case DockedInteractionKind.approval:
        break;
    }
    void onSelected(String confirmationId, String actionId, String label) =>
        widget.onActionSelected(message, confirmationId, actionId, label);
    if (card['confirmation_context'] == 'cli') {
      return CliApprovalCard(
        key: ValueKey(card['confirmation_id']),
        actionData: card,
        onActionSelected: onSelected,
      );
    }
    return ActionConfirmationButtons(
      key: ValueKey(card['confirmation_id']),
      actionData: card,
      onActionSelected: onSelected,
      isAgentOffline: widget.isAgentOffline,
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    if (body == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sender = widget.interaction.message.from.name.trim();
    final title = widget.interaction.isQuestion
        ? l10n.chat_pendingFormDockTitle
        : l10n.chat_pendingApprovalDockTitle;
    final maxBodyHeight = MediaQuery.sizeOf(context).height * 0.45;

    return Material(
      color: colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              child: Row(
                children: [
                  Icon(
                    widget.interaction.isQuestion
                        ? Icons.help_outline
                        : Icons.verified_user_outlined,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sender.isEmpty ? title : '$sender · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.expand_less,
                    size: 20,
                    semanticLabel: _expanded
                        ? l10n.chat_queueCollapse
                        : l10n.chat_queueExpand,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBodyHeight),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: body,
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表里被停靠的那张卡：只留一行，说明去哪儿处理。
class DockedInteractionPlaceholder extends StatelessWidget {
  final String title;
  final String hint;
  final IconData icon;

  const DockedInteractionPlaceholder({
    super.key,
    required this.title,
    required this.hint,
    this.icon = Icons.help_outline,
  });

  /// 提问卡的占位：独立卡片行整行替换，挂在气泡上的只替换表单区。
  factory DockedInteractionPlaceholder.question(
    BuildContext context,
    Map<String, dynamic> card,
  ) {
    final title = card['title'] ?? card['prompt'];
    return DockedInteractionPlaceholder(
      title: (title?.toString() ?? '').trim(),
      hint: AppLocalizations.of(context).chat_pendingFormInDock,
    );
  }

  /// 审批卡的占位：只替换气泡底部的按钮区，回复正文照常显示。
  factory DockedInteractionPlaceholder.approval(
    BuildContext context,
    Map<String, dynamic> card,
  ) {
    return DockedInteractionPlaceholder(
      title: (card['prompt']?.toString() ?? '').trim(),
      hint: AppLocalizations.of(context).chat_pendingApprovalInDock,
      icon: Icons.verified_user_outlined,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title.isEmpty ? hint : '$title · $hint',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.south, size: 14, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
