import 'package:flutter/material.dart';

import '../../controllers/flow/flow_edit_ops.dart';
import '../../controllers/flow/flow_outline.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/layout_utils.dart';

/// 行菜单 / 属性面板 `⋯` 共用的动作。
enum FlowOutlineMenuAction {
  /// 在这一步后面加一步。
  insertAfter,

  /// 往这个容器里加子步骤。
  insertChild,

  /// 把这一步包进 par / loop。
  wrap,

  /// 拆开容器。
  unwrap,

  /// 换节点类型。
  retype,

  /// 删除这一步。
  delete,

  /// 移进上一个兄弟（它得是容器）。保留给快捷键路径。
  moveIntoPrevious,

  /// 和上一个兄弟一起包进一个新容器。
  wrapWithPrevious,

  /// 显式跨分支移动。
  moveToBranch,

  /// 移出一层。
  outdent,
}

typedef FlowOutlineMenuChoice = ({
  FlowOutlineMenuAction action,
  String? kind,
  String? branch,
});

/// 菜单条目。两处界面（大纲行、属性面板）渲染同一份。
class FlowOutlineMenuEntry {
  const FlowOutlineMenuEntry({
    required this.label,
    this.choice,
    this.danger = false,
    this.divider = false,
    this.shortcut,
  });

  final String label;
  final FlowOutlineMenuChoice? choice;
  final bool danger;
  final bool divider;
  final String? shortcut;
}

List<FlowOutlineMenuEntry> flowOutlineMenuEntries({
  required AppLocalizations l10n,
  required FlowOutlineRow row,
  required bool canRetype,
}) {
  final node = row.node;
  final isContainer =
      node.kind == 'if' || FlowStepDefaults.isContainer(node.kind);
  final entries = <FlowOutlineMenuEntry>[
    FlowOutlineMenuEntry(
      label: l10n.flow_addAfter,
      shortcut: 'Alt+N',
      choice: (
        action: FlowOutlineMenuAction.insertAfter,
        kind: null,
        branch: null,
      ),
    ),
  ];
  if (isContainer) {
    if (node.kind == 'if') {
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_menuAddThen,
        choice: (
          action: FlowOutlineMenuAction.insertChild,
          kind: null,
          branch: 'then',
        ),
      ));
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_menuAddElse,
        choice: (
          action: FlowOutlineMenuAction.insertChild,
          kind: null,
          branch: 'else',
        ),
      ));
    } else {
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_menuAddInside,
        choice: (
          action: FlowOutlineMenuAction.insertChild,
          kind: null,
          branch: null,
        ),
      ));
    }
  }
  entries.add(FlowOutlineMenuEntry(
    label: l10n.flow_wrapPar,
    choice: (
      action: FlowOutlineMenuAction.wrap,
      kind: 'par',
      branch: null,
    ),
  ));
  entries.add(FlowOutlineMenuEntry(
    label: l10n.flow_wrapLoop,
    choice: (
      action: FlowOutlineMenuAction.wrap,
      kind: 'loop',
      branch: null,
    ),
  ));
  if (isContainer) {
    entries.add(FlowOutlineMenuEntry(
      label: l10n.flow_menuUnwrap,
      choice: (
        action: FlowOutlineMenuAction.unwrap,
        kind: null,
        branch: null,
      ),
    ));
  }
  if (canRetype) {
    entries.add(const FlowOutlineMenuEntry(label: '', divider: true));
    const kinds = [
      'task',
      'seq',
      'par',
      'loop',
      'if',
      'map',
      'set',
      'call',
      'gate',
      'plan',
    ];
    for (final kind in kinds) {
      if (kind == node.kind) continue;
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_menuRetypeKind(kind),
        choice: (
          action: FlowOutlineMenuAction.retype,
          kind: kind,
          branch: null,
        ),
      ));
    }
  }
  entries.add(const FlowOutlineMenuEntry(label: '', divider: true));
  entries.add(FlowOutlineMenuEntry(
    label: l10n.flow_inspectorDelete,
    danger: true,
    choice: (
      action: FlowOutlineMenuAction.delete,
      kind: null,
      branch: null,
    ),
  ));
  return entries;
}

/// 大纲行 / 检查器上的结构菜单。
///
/// 桌面端锚在按钮或右键位置，不再从底部弹出。手机端仍用底部弹层。
Future<FlowOutlineMenuChoice?> showFlowOutlineMenu(
  BuildContext context, {
  required FlowOutlineRow row,
  required bool canRetype,
  Offset? position,
}) {
  final l10n = AppLocalizations.of(context);
  final entries = flowOutlineMenuEntries(
    l10n: l10n,
    row: row,
    canRetype: canRetype,
  );
  if (LayoutUtils.isDesktopLayout(context)) {
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    final box = context.findRenderObject();
    var origin = position ?? Offset.zero;
    if (position == null && box is RenderBox && box.hasSize) {
      origin = box.localToGlobal(Offset.zero);
    }
    var left = origin.dx;
    var top = origin.dy;
    if (overlay is RenderBox) {
      final local = overlay.globalToLocal(origin);
      left = local.dx;
      top = local.dy;
    }
    return showMenu<FlowOutlineMenuChoice>(
      context: context,
      position: RelativeRect.fromLTRB(left, top, left + 1, top + 1),
      items: [
        for (final entry in entries)
          if (entry.divider)
            const PopupMenuDivider()
          else if (entry.choice != null)
            PopupMenuItem<FlowOutlineMenuChoice>(
              key: ValueKey('outline-menu-${entry.choice!.action.name}-${entry.choice!.kind ?? entry.choice!.branch ?? ''}'),
              value: entry.choice,
              child: Text(
                entry.shortcut == null
                    ? entry.label
                    : '${entry.label}  ${entry.shortcut}',
                style: entry.danger
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ),
      ],
    );
  }
  return showModalBottomSheet<FlowOutlineMenuChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => _Sheet(entries: entries),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.entries});

  final List<FlowOutlineMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      shrinkWrap: true,
      children: [
        for (final entry in entries)
          if (entry.divider)
            const Divider(height: 1)
          else
            ListTile(
              title: Text(
                entry.label,
                style: entry.danger ? TextStyle(color: scheme.error) : null,
              ),
              trailing: entry.shortcut == null ? null : Text(entry.shortcut!),
              onTap: entry.choice == null
                  ? null
                  : () => Navigator.pop(context, entry.choice),
            ),
      ],
    );
  }
}
