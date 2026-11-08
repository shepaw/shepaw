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

  /// 上移 / 下移。手机上的 compact 行没有行尾按钮，这两个动作只能走菜单。
  moveUp,
  moveDown,
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
  bool includeMove = false,
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
  if (includeMove) {
    // 不能移的行干脆不给条目：手机上没有禁用态的行尾按钮可看。
    if (row.canMoveUp) {
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_outlineMoveUp,
        choice: (
          action: FlowOutlineMenuAction.moveUp,
          kind: null,
          branch: null,
        ),
      ));
    }
    if (row.canMoveDown) {
      entries.add(FlowOutlineMenuEntry(
        label: l10n.flow_outlineMoveDown,
        choice: (
          action: FlowOutlineMenuAction.moveDown,
          kind: null,
          branch: null,
        ),
      ));
    }
  }
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
  bool includeMove = false,
}) {
  final l10n = AppLocalizations.of(context);
  final entries = flowOutlineMenuEntries(
    l10n: l10n,
    row: row,
    canRetype: canRetype,
    includeMove: includeMove,
  );
  if (LayoutUtils.isDesktopLayout(context)) {
    return _showMenuAnchor(context, entries, position);
  }
  return showModalBottomSheet<FlowOutlineMenuChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => _Sheet(entries: entries),
  );
}

/// 桌面菜单锚在按钮或右键位置。
///
/// 用 [showMenu]：菜单贴着锚点矩形，点一项立刻把选项带回来。
/// 不能再套一层 [MenuAnchor]——它会先关掉菜单，下一帧才调 `onPressed`，
/// 选项还没写上菜单就已经关了。
Future<FlowOutlineMenuChoice?> _showMenuAnchor(
  BuildContext context,
  List<FlowOutlineMenuEntry> entries,
  Offset? position,
) {
  final overlayBox = Overlay.maybeOf(context)?.context.findRenderObject();
  if (overlayBox is! RenderBox || !overlayBox.hasSize) {
    return Future.value(null);
  }
  final Rect anchor;
  if (position != null) {
    final local = overlayBox.globalToLocal(position);
    anchor = Rect.fromLTWH(local.dx, local.dy, 0, 0);
  } else {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Future.value(null);
    final origin = overlayBox.globalToLocal(box.localToGlobal(Offset.zero));
    anchor = origin & box.size;
  }
  final error = Theme.of(context).colorScheme.error;
  return showMenu<FlowOutlineMenuChoice>(
    context: context,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlayBox.size),
    items: [
      for (final item in entries)
        if (item.divider)
          const PopupMenuDivider(height: 8)
        else if (item.choice != null)
          PopupMenuItem<FlowOutlineMenuChoice>(
            key: ValueKey(
              'outline-menu-${item.choice!.action.name}-${item.choice!.kind ?? item.choice!.branch ?? ''}',
            ),
            value: item.choice,
            child: Text(
              item.shortcut == null
                  ? item.label
                  : '${item.label}  ${item.shortcut}',
              style: item.danger ? TextStyle(color: error) : null,
            ),
          ),
    ],
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
