import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/queued_message.dart';
import '../../theme/app_theme.dart';

/// 待发送队列面板：折叠态显示条数与首条预览，展开态逐条列出，
/// 支持逐条上移/下移/编辑/删除以及一键清空。
///
/// UI 局部状态（展开/折叠）用本地 `setState`，符合状态管理约定。
class ChatQueuePanel extends StatefulWidget {
  final List<QueuedMessage> items;
  final void Function(String id, String newContent) onEdit;
  final void Function(String id) onDelete;
  final void Function(String id, int delta) onMove;
  final VoidCallback onClearAll;

  const ChatQueuePanel({
    super.key,
    required this.items,
    required this.onEdit,
    required this.onDelete,
    required this.onMove,
    required this.onClearAll,
  });

  @override
  State<ChatQueuePanel> createState() => _ChatQueuePanelState();
}

class _ChatQueuePanelState extends State<ChatQueuePanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final items = widget.items;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        border: const Border(
            top: BorderSide(color: AppColors.primaryLight, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- 折叠态/标题行 ----
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.queue, size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.chat_sendQueueCount(items.length),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    tooltip: _expanded
                        ? l10n.chat_queueCollapse
                        : l10n.chat_queueExpand,
                    onPressed: () =>
                        setState(() => _expanded = !_expanded),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => _confirmClear(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 4),
                      child: Text(
                        l10n.chat_queueClearAll,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red[400],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ---- 折叠态：首条预览 ----
          if (!_expanded && items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 36, right: 12, bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  items.first.content,
                  style: const TextStyle(fontSize: 11, color: AppColors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          // ---- 展开态：逐条列表 ----
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 4),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isFirst = index == 0;
                  final isLast = index == items.length - 1;
                  return _QueueRow(
                    item: item,
                    canMoveUp: !isFirst,
                    canMoveDown: !isLast,
                    onMoveUp: () => widget.onMove(item.id, -1),
                    onMoveDown: () => widget.onMove(item.id, 1),
                    onEdit: () => _editItem(context, item),
                    onDelete: () => _confirmDelete(context, item),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editItem(BuildContext context, QueuedMessage item) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _QueueEditDialog(initialContent: item.content),
    );
    if (result != null && result.trim().isNotEmpty && mounted) {
      widget.onEdit(item.id, result);
    }
  }

  Future<void> _confirmDelete(BuildContext context, QueuedMessage item) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.common_delete),
        content: Text(l10n.chat_queueDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.common_delete,
              style: TextStyle(color: Colors.red[400]),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onDelete(item.id);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chat_queueClearAll),
        content: Text(l10n.chat_queueDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.common_delete,
              style: TextStyle(color: Colors.red[400]),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onClearAll();
  }
}

class _QueueRow extends StatelessWidget {
  final QueuedMessage item;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _QueueRow({
    required this.item,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasAttachments =
        item.attachments != null && item.attachments!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            tooltip: l10n.chat_queueMoveUp,
            onPressed: canMoveUp ? onMoveUp : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward, size: 16),
            tooltip: l10n.chat_queueMoveDown,
            onPressed: canMoveDown ? onMoveDown : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              item.content,
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (item.replyToId != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.reply, size: 12, color: Colors.grey),
            ),
          if (hasAttachments)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.attach_file, size: 12, color: Colors.grey),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: l10n.common_edit,
            onPressed: onEdit,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            tooltip: l10n.common_delete,
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// 编辑待发送消息内容的对话框。内容为空时禁用保存。
class _QueueEditDialog extends StatefulWidget {
  final String initialContent;

  const _QueueEditDialog({required this.initialContent});

  @override
  State<_QueueEditDialog> createState() => _QueueEditDialogState();
}

class _QueueEditDialogState extends State<_QueueEditDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent)
      ..selection = TextSelection.collapsed(
        offset: widget.initialContent.length,
      );
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.chat_queueEditTitle),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        maxLines: 3,
        minLines: 1,
        // 输入变化时重建 actions，让「保存」随空内容实时禁用。
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: l10n.chat_queueEditHint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        TextButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text),
          child: Text(l10n.common_edit),
        ),
      ],
    );
  }
}
