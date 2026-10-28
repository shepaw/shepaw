import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../action_confirmation_buttons.dart';
import 'cli_approval_card.dart';
import 'paged_form_panel.dart';

enum DockedInteractionKind { form, approval }

/// 停靠在输入框上方、等用户处理的那一张卡。
class DockedInteraction {
  final Message message;
  final DockedInteractionKind kind;

  const DockedInteraction(this.message, this.kind);

  bool get isForm => kind == DockedInteractionKind.form;
}

/// 还在等用户回答的主机提问卡（`ask_user` → `agent_form_req`）。
///
/// 只认带 `peer_form` 的独立卡片行：它们整条消息就是这张卡，列表里换成
/// 占位不会藏掉别的正文。答过（`submitted_values`）或作废（`closed`）的不算；
/// deferred 的还能答，算。
bool isDockablePendingForm(Message message) {
  final form = message.metadata?['form'];
  if (form is! Map || form['peer_form'] is! Map) return false;
  return form['submitted_values'] == null && form['closed'] == null;
}

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

/// 取最新的一张待处理卡；其余留在消息流里照常显示。
///
/// [approvalIsLive] 判断审批卡此刻还有没有人在等（见
/// `ChatController.isApprovalCardLive`）；不传时不停靠任何审批卡。
DockedInteraction? dockedPendingInteraction(
  List<Message> messages, {
  bool Function(Message message)? approvalIsLive,
}) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (isDockablePendingForm(message)) {
      return DockedInteraction(message, DockedInteractionKind.form);
    }
    if (isDockablePendingApproval(message) &&
        (approvalIsLive?.call(message) ?? false)) {
      return DockedInteraction(message, DockedInteractionKind.approval);
    }
  }
  return null;
}

/// 悬浮在输入框上方的待处理卡（提问表单 / 工具审批）。
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
  final void Function(Message message, String confirmationId,
      String actionId, String actionLabel) onActionSelected;
  final bool isAgentOffline;

  const PendingInteractionDock({
    super.key,
    required this.interaction,
    required this.onFormSubmitted,
    this.onFormDeclined,
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
    if (widget.interaction.isForm) {
      final formData = message.metadata?['form'];
      if (formData is! Map<String, dynamic>) return null;
      return DockedFormBody(
        // 换了一张卡就换一份填写状态。
        key: ValueKey(message.id),
        formData: formData,
        onFormSubmitted: (formId, values, summary) =>
            widget.onFormSubmitted(message, formId, values, summary),
        onFormDeclined: widget.onFormDeclined == null
            ? null
            : (formId) => widget.onFormDeclined!(message, formId),
      );
    }
    final card = message.metadata?['action_confirmation'];
    if (card is! Map<String, dynamic>) return null;
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
    final title = widget.interaction.isForm
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
                    widget.interaction.isForm
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

  /// 提问卡的占位：整条消息就是这张卡。
  factory DockedInteractionPlaceholder.form(
    BuildContext context,
    Message message,
  ) {
    final form = message.metadata?['form'];
    return DockedInteractionPlaceholder(
      title: form is Map ? (form['title']?.toString() ?? '').trim() : '',
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
