import 'package:flutter/material.dart';

import '../../controllers/flow/flow_outline.dart';
import '../../l10n/app_localizations.dart';
import '../../peer/models/flow_models.dart';
import 'flow_node_tree.dart';

/// 可编辑的大纲（方案 M3）。
///
/// 和 [FlowNodeTree] 的区别：那个是「画出来看」的（运行视图、手机只读），这个
/// 是「拿来改」的 —— 每一行带深度、分支和上移 / 下移 / 加一步 / 删除。
///
/// [canEdit] 为 false 时只画，不给按钮；`if` 的子节点在主机没标 `branch` 时
/// （[branchesLabelled] 为 false）也一律不给按钮：按下标派发会跨分支。
class FlowOutlineTree extends StatelessWidget {
  const FlowOutlineTree({
    super.key,
    required this.rows,
    required this.canEdit,
    this.branchesLabelled = true,
    this.selectedId,
    this.errorCounts = const {},
    this.collapsed = const {},
    this.badgeFor,
    this.onTapRow,
    this.onToggleCollapse,
    this.onAddAfter,
    this.onMoveUp,
    this.onMoveDown,
    this.onDelete,
    this.onMenu,
  });

  final List<FlowOutlineRow> rows;
  final bool canEdit;
  final bool branchesLabelled;
  final String? selectedId;

  /// 节点 id → error 级诊断条数。用来在行上标红点。
  final Map<String, int> errorCounts;
  final Set<String> collapsed;

  /// 行尾的小角标（和 [FlowNodeTree.badgeFor] 一样，用来标 diff）。
  final (String, Color)? Function(FlowOutlineRow row)? badgeFor;

  final void Function(FlowOutlineRow row)? onTapRow;
  final void Function(FlowOutlineRow row)? onToggleCollapse;
  final void Function(FlowOutlineRow row)? onAddAfter;
  final void Function(FlowOutlineRow row)? onMoveUp;
  final void Function(FlowOutlineRow row)? onMoveDown;
  final void Function(FlowOutlineRow row)? onDelete;

  /// 「⋯」菜单：加子步骤 / 缩进 / 改类型。
  final void Function(FlowOutlineRow row)? onMenu;

  /// 这一行能不能改结构。`if` 内没有分支标记时一律不给。
  bool _editable(FlowOutlineRow row) {
    if (!canEdit) return false;
    if (row.inIfBranch && !branchesLabelled) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          _Row(
            l10n: l10n,
            scheme: scheme,
            theme: theme,
            row: row,
            selected: selectedId == row.node.id,
            errors: errorCounts[row.node.id] ?? 0,
            collapsed: collapsed.contains(row.node.id),
            editable: _editable(row),
            badge: badgeFor?.call(row),
            onTap: onTapRow == null ? null : () => onTapRow!(row),
            onToggleCollapse:
                onToggleCollapse == null ? null : () => onToggleCollapse!(row),
            onAddAfter: onAddAfter == null ? null : () => onAddAfter!(row),
            onMoveUp: onMoveUp == null ? null : () => onMoveUp!(row),
            onMoveDown: onMoveDown == null ? null : () => onMoveDown!(row),
            onDelete: onDelete == null ? null : () => onDelete!(row),
            onMenu: onMenu == null ? null : () => onMenu!(row),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.l10n,
    required this.scheme,
    required this.theme,
    required this.row,
    required this.selected,
    required this.errors,
    required this.collapsed,
    required this.editable,
    required this.badge,
    required this.onTap,
    required this.onToggleCollapse,
    required this.onAddAfter,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onMenu,
  });

  final AppLocalizations l10n;
  final ColorScheme scheme;
  final ThemeData theme;
  final FlowOutlineRow row;
  final bool selected;
  final int errors;
  final bool collapsed;
  final bool editable;
  final (String, Color)? badge;
  final VoidCallback? onTap;
  final VoidCallback? onToggleCollapse;
  final VoidCallback? onAddAfter;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDelete;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final hasChildren = node.children.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(left: 16.0 * row.depth, bottom: 6),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          key: ValueKey('row-${node.id}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                if (hasChildren)
                  IconButton(
                    key: ValueKey('collapse-${node.id}'),
                    icon: Icon(collapsed
                        ? Icons.chevron_right
                        : Icons.expand_more),
                    tooltip: l10n.flow_outlineCollapse,
                    onPressed: onToggleCollapse,
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              flowKindTitle(l10n, node),
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (row.branch != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              row.branch == 'else'
                                  ? l10n.flow_outlineElse
                                  : l10n.flow_outlineThen,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (errors > 0) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.error_outline,
                                size: 14, color: scheme.error),
                          ],
                          if (badge != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              badge!.$1,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: badge!.$2,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (node.desc != null && node.desc!.isNotEmpty)
                        Text(
                          node.desc!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (editable) ...[
                  IconButton(
                    key: ValueKey('up-${node.id}'),
                    tooltip: l10n.flow_outlineMoveUp,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: row.canMoveUp ? onMoveUp : null,
                  ),
                  IconButton(
                    key: ValueKey('down-${node.id}'),
                    tooltip: l10n.flow_outlineMoveDown,
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    onPressed: row.canMoveDown ? onMoveDown : null,
                  ),
                  IconButton(
                    key: ValueKey('after-${node.id}'),
                    tooltip: l10n.flow_addAfter,
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: onAddAfter,
                  ),
                  IconButton(
                    key: ValueKey('menu-${node.id}'),
                    tooltip: l10n.flow_outlineMenu,
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onPressed: onMenu,
                  ),
                  IconButton(
                    key: ValueKey('del-${node.id}'),
                    tooltip: l10n.flow_inspectorDelete,
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: scheme.error),
                    onPressed: onDelete,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
