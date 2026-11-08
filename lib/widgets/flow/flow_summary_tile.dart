import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';

/// 流程库的一行（工作台列表）。
///
/// 改版前每行都挂一个常驻的「开始运行」按钮，误触就真的调 agent。现在：
/// - 点行进详情（默认概览），开跑只在概览里；
/// - 第一行名称 + 状态点，第二行说明 / 版本 + 草稿标记；
/// - 「开始运行 / 执行历史 / 复制 / 查看历史 / 删除」收进右侧 `⋯` 菜单。
///
/// 状态来自 `flow_list_resp` 的可选字段：旧主机不返回时 [FlowSummary.status]
/// 是 [FlowSummaryStatus.none]，这一行就退化成「名称 + 版本」，功能不变。
class FlowSummaryTile extends StatelessWidget {
  const FlowSummaryTile({
    super.key,
    required this.flow,
    required this.selected,
    required this.hasDraft,
    required this.onTap,
    required this.onStart,
    required this.onExecutions,
    required this.onDuplicate,
    required this.onDelete,
    required this.onHistory,
    this.needsApproval = false,
    this.onApproval,
  });

  final FlowSummary flow;
  final bool selected;
  final bool hasDraft;

  /// 主机明确说「最近一次运行里有人在等你审批」。比状态串更可靠，也兼容
  /// 老主机（永远 false）。
  final bool needsApproval;

  /// 手机只读，橙色徽标直接带去那次运行里等回答的节点。
  final VoidCallback? onApproval;

  final VoidCallback onTap;
  final VoidCallback onStart;
  final VoidCallback onExecutions;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = needsApproval
        ? FlowSummaryStatus.needsApproval
        : flow.status;
    final (color, label) = switch (status) {
      FlowSummaryStatus.running => (
          scheme.primary,
          l10n.flow_listStatusRunning
        ),
      FlowSummaryStatus.failed => (
          scheme.error,
          l10n.flow_listStatusFailed
        ),
      FlowSummaryStatus.needsApproval => (
          Colors.orange,
          l10n.flow_listStatusNeedsApproval
        ),
      FlowSummaryStatus.none => (Colors.transparent, ''),
    };
    final description = flow.description?.trim() ?? '';
    return ListTile(
      key: ValueKey('flow-row-${flow.name}'),
      selected: selected,
      leading: Icon(
        Icons.account_tree_outlined,
        color: selected ? scheme.primary : null,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(flow.name, overflow: TextOverflow.ellipsis),
          ),
          if (status != FlowSummaryStatus.none) ...[
            Tooltip(
              message: label,
              child: Container(
                key: ValueKey('flow-status-${flow.name}'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              description.isNotEmpty
                  ? description
                  : l10n.flow_revisionLabel(flow.latest),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status == FlowSummaryStatus.needsApproval)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: onApproval == null
                  ? Text(
                      label,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.orange),
                    )
                  : InkWell(
                      key: ValueKey('flow-approval-${flow.name}'),
                      onTap: onApproval,
                      child: Text(
                        label,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.orange,
                            decoration: TextDecoration.underline),
                      ),
                    ),
            ),
          if (hasDraft)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                l10n.flow_listDraft,
                key: ValueKey('flow-draft-${flow.name}'),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
      trailing: PopupMenuButton<_RowAction>(
        key: ValueKey('flow-more-${flow.name}'),
        tooltip: l10n.flow_toolbarMore,
        onSelected: (action) => switch (action) {
          _RowAction.start => onStart(),
          _RowAction.executions => onExecutions(),
          _RowAction.duplicate => onDuplicate(),
          _RowAction.delete => onDelete(),
          _RowAction.history => onHistory(),
        },
        itemBuilder: (context) => [
          PopupMenuItem<_RowAction>(
            key: ValueKey('flow-start-${flow.name}'),
            value: _RowAction.start,
            child: Text(l10n.flow_listStart),
          ),
          PopupMenuItem<_RowAction>(
            key: ValueKey('flow-executions-${flow.name}'),
            value: _RowAction.executions,
            child: Text(l10n.flow_listExecutions),
          ),
          PopupMenuItem<_RowAction>(
            key: ValueKey('flow-copy-${flow.name}'),
            value: _RowAction.duplicate,
            child: Text(l10n.flow_listCopy),
          ),
          PopupMenuItem<_RowAction>(
            key: ValueKey('flow-history-${flow.name}'),
            value: _RowAction.history,
            child: Text(l10n.flow_listHistory),
          ),
          PopupMenuItem<_RowAction>(
            key: ValueKey('flow-delete-${flow.name}'),
            value: _RowAction.delete,
            child: Text(
              l10n.flow_listDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

enum _RowAction { start, executions, duplicate, history, delete }
