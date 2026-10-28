import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../form_bubble.dart';

/// 还在等用户回答的主机提问卡（`ask_user` → `agent_form_req`）。
///
/// 只认带 `peer_form` 的独立卡片行：它们整条消息就是这张卡，列表里换成
/// 占位不会藏掉别的正文。答过（`submitted_values`）或作废（`closed`）的不算；
/// deferred 的还能答，算。多张同时开着时取最新的一张，其余留在列表里。
Message? dockedPendingForm(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final form = messages[i].metadata?['form'];
    if (form is! Map || form['peer_form'] is! Map) continue;
    if (form['submitted_values'] != null || form['closed'] != null) continue;
    return messages[i];
  }
  return null;
}

/// 悬浮在输入框上方的提问卡。
///
/// 卡片以前只在消息流里：时间戳排序会把它放到正在输出的回复上面，或者被
/// 后续输出顶出视口，用户看不到主机在等他。停靠在输入框上方之后，答完
/// 才收起；列表里同一张卡只画占位（见 [PendingFormPlaceholder]）。
class PendingFormDock extends StatefulWidget {
  final Message message;
  final void Function(Message message, String formId,
      Map<String, dynamic> values, String summary) onFormSubmitted;
  final void Function(Message message, String formId)? onFormDeclined;

  const PendingFormDock({
    super.key,
    required this.message,
    required this.onFormSubmitted,
    this.onFormDeclined,
  });

  @override
  State<PendingFormDock> createState() => _PendingFormDockState();
}

class _PendingFormDockState extends State<PendingFormDock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final formData = widget.message.metadata?['form'];
    if (formData is! Map<String, dynamic>) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sender = widget.message.from.name.trim();
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
                  Icon(Icons.help_outline,
                      size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sender.isEmpty
                          ? l10n.chat_pendingFormDockTitle
                          : '$sender · ${l10n.chat_pendingFormDockTitle}',
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
                child: FormBubble(
                  // 换了一张卡就换一份填写状态。
                  key: ValueKey(widget.message.id),
                  formData: formData,
                  onFormSubmitted: (formId, values, summary) => widget
                      .onFormSubmitted(widget.message, formId, values, summary),
                  onFormDeclined: widget.onFormDeclined == null
                      ? null
                      : (formId) =>
                          widget.onFormDeclined!(widget.message, formId),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表里被停靠的那张卡：只留一行，说明去哪儿答。
class PendingFormPlaceholder extends StatelessWidget {
  final Message message;

  const PendingFormPlaceholder({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final form = message.metadata?['form'];
    final title = form is Map ? (form['title']?.toString() ?? '').trim() : '';
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
              Icon(Icons.help_outline, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title.isEmpty
                      ? l10n.chat_pendingFormInDock
                      : '$title · ${l10n.chat_pendingFormInDock}',
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
