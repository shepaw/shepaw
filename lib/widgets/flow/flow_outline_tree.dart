import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/flow/flow_outline.dart';
import '../../controllers/flow/flow_references.dart';
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
///
/// [dragEnabled] 只在「桌面可编辑态」（`canEdit && !rehearsal.active && !busy`）
/// 打开：每行左侧多一个拖拽手柄，**只有手柄能触发拖拽**（长按已经被「点选 +
/// 说话」的多选占用了）。落点分上 / 中 / 下三区，非法落点不会发出 [onDrop]。
class FlowOutlineTree extends StatefulWidget {
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
    this.onLongPressRow,
    this.rowKeys = const {},
    this.flashId,
    this.onDrop,
    this.dragEnabled = false,
    this.canMove = true,
    this.tree = const [],
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

  /// 长按多选（群流程的「点选 + 说话」）。
  final void Function(FlowOutlineRow row)? onLongPressRow;

  /// 每行一个 GlobalKey：诊断定位时靠它 `Scrollable.ensureVisible`。
  final Map<String, GlobalKey> rowKeys;

  /// 正在闪烁的那一行（诊断点选后 600ms）。
  final String? flashId;

  /// 拖放落点。参数是被拖节点 id 和解析好的落点。
  final void Function(String dragId, FlowDropTarget target)? onDrop;

  /// 是否开启拖放（桌面可编辑且不忙）。
  final bool dragEnabled;

  /// 主机支不支持 move；不支持时所有落点都会被拒。
  final bool canMove;

  /// 完整节点树（不受折叠影响），软引用预检用。
  final List<FlowNode> tree;

  /// Test seam：拖拽过程中实际跑了几次 [refWarningsAfterMove]（全树模拟 +
  /// 正则扫描）。落点没变时不该增加。
  @visibleForTesting
  static int debugHoverWarningsComputed = 0;

  /// Test seam：自动滚动计时器实际 tick 了几次。拖拽被卸载 / 切到 busy
  /// 之后不该再增长。
  @visibleForTesting
  static int debugAutoScrollTicks = 0;

  /// Test seam：自动滚动实际被应用到滚动位置上的次数（指针不在大纲里时
  /// 不该再增加）。
  @visibleForTesting
  static int debugAutoScrollMoves = 0;

  /// 这一行能不能改结构。`if` 内没有分支标记时一律不给。
  bool _editable(FlowOutlineRow row) {
    if (!canEdit) return false;
    if (row.inIfBranch && !branchesLabelled) return false;
    return true;
  }

  @override
  State<FlowOutlineTree> createState() => _FlowOutlineTreeState();
}

class _Hover {
  const _Hover({
    required this.overId,
    required this.zone,
    required this.branch,
    required this.target,
    required this.warnings,
  });

  final String overId;
  final DropZone zone;
  final String? branch;
  final FlowDropTarget? target;
  final List<String> warnings;
}

class _FlowOutlineTreeState extends State<FlowOutlineTree> {
  String? _dragId;
  _Hover? _hover;
  double? _pointerDy;
  ScrollableState? _scrollable;
  Timer? _autoScroll;
  final Map<String, GlobalKey> _boxKeys = {};

  @override
  void dispose() {
    _cancelDragState();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FlowOutlineTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 拖拽中切到 busy（dragEnabled 变 false）时 Draggable 会被卸载，
    // onDragEnd 不会回调；这里主动收掉计时器和拖拽状态。
    if (!widget.dragEnabled) _cancelDragState();
  }

  /// 只清本地拖拽状态，不触发 setState —— 给 dispose / didUpdateWidget 用
  /// （这两处随后本来就会重建或已不可重建）。
  void _cancelDragState() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _dragId = null;
    _hover = null;
    _pointerDy = null;
  }

  void _startDrag(String id) {
    if (!mounted) return;
    _scrollable = Scrollable.maybeOf(context);
    _autoScroll?.cancel();
    setState(() {
      _dragId = id;
      _hover = null;
    });
    // 长列表拖到边缘时自动滚。
    _autoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    if (_dragId == null) return;
    if (!mounted) {
      _cancelDragState();
      return;
    }
    setState(() {
      _dragId = null;
      _hover = null;
      _pointerDy = null;
    });
  }

  void _autoScrollTick() {
    FlowOutlineTree.debugAutoScrollTicks++;
    if (!mounted) return;
    final dy = _pointerDy;
    final pos = _scrollable?.position;
    if (dy == null || pos == null || _dragId == null) return;
    final box = _scrollable!.context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    // 指针已经移出可视区（离开大纲）时最后的位置不再代表用户意图：
    // 停掉计时器，别让列表在指针不在时还一直滚。
    if (dy < top || dy > bottom) {
      _pointerDy = null;
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    double? target;
    if (dy < top + 48) {
      target = pos.pixels - 16;
    } else if (dy > bottom - 48) {
      target = pos.pixels + 16;
    }
    if (target == null) return;
    FlowOutlineTree.debugAutoScrollMoves++;
    pos.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  /// 指针离开某一行时调用。清掉最后记录的指针位置：`_onMove` 只在指针
  /// 位于某一行上时才会更新它，指针移出大纲后如果继续按旧值滚，列表会一直
  /// 停不下来。换到另一行时随后的 `onMove` 会立刻把位置补回来。
  void _onPointerLeaveRow() {
    _pointerDy = null;
  }

  /// 只算便宜的落点身份（行 + 上中下区 + if 分支），不碰全树预检。
  ({String overId, DropZone zone, String? branch})? _slotAt(
    FlowOutlineRow row,
    Offset global,
  ) {
    final box = _boxKeys[row.node.id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final local = box.globalToLocal(global);
    final h = box.size.height;
    final w = box.size.width;
    final zone = local.dy < h * 0.25
        ? DropZone.before
        : (local.dy > h * 0.75 ? DropZone.after : DropZone.into);
    // `if` 的中间区再按左右拆成 then / else 两个落点。
    String? branch;
    if (zone == DropZone.into && row.node.kind == 'if') {
      branch = local.dx < w / 2 ? 'then' : 'else';
    }
    return (overId: row.node.id, zone: zone, branch: branch);
  }

  _Hover _hoverFor(
    String dragId,
    ({String overId, DropZone zone, String? branch}) slot,
  ) {
    final target = resolveDrop(
      widget.rows,
      dragId,
      slot.overId,
      slot.zone,
      branch: slot.branch,
      canMove: widget.canMove,
      branchesLabelled: widget.branchesLabelled,
    );
    final warnings =
        target == null ? const <String>[] : _warningsFor(dragId, target);
    return _Hover(
      overId: slot.overId,
      zone: slot.zone,
      branch: slot.branch,
      target: target,
      warnings: warnings,
    );
  }

  List<String> _warningsFor(String dragId, FlowDropTarget target) {
    FlowOutlineTree.debugHoverWarningsComputed++;
    return refWarningsAfterMove(widget.tree, dragId, target);
  }

  _Hover? _computeHover(FlowOutlineRow row, Offset global) {
    final dragId = _dragId;
    if (dragId == null) return null;
    final slot = _slotAt(row, global);
    if (slot == null) return null;
    return _hoverFor(dragId, slot);
  }

  void _onMove(FlowOutlineRow row, Offset global) {
    if (!mounted) return;
    _pointerDy = global.dy;
    final dragId = _dragId;
    if (dragId == null) return;
    // 先比便宜的落点身份；没变就别做 target / 全树预检。
    final slot = _slotAt(row, global);
    if (slot == null) return;
    final hover = _hover;
    if (hover != null &&
        hover.overId == slot.overId &&
        hover.zone == slot.zone &&
        hover.branch == slot.branch) {
      return;
    }
    final next = _hoverFor(dragId, slot);
    setState(() => _hover = next);
  }

  void _onAccept(FlowOutlineRow row, DragTargetDetails<String> details) {
    if (!mounted) return;
    final hover = _computeHover(row, details.offset);
    _endDrag();
    if (hover?.target != null) {
      widget.onDrop?.call(details.data, hover!.target!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in widget.rows)
          _buildRow(context, l10n, theme, scheme, row),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
    FlowOutlineRow row,
  ) {
    final editable = widget._editable(row);
    final draggable = widget.dragEnabled && editable;
    final hover = _hover?.overId == row.node.id ? _hover : null;

    Widget rowWidget = _Row(
      key: widget.rowKeys[row.node.id],
      l10n: l10n,
      scheme: scheme,
      theme: theme,
      row: row,
      selected: widget.selectedId == row.node.id,
      errors: widget.errorCounts[row.node.id] ?? 0,
      collapsed: widget.collapsed.contains(row.node.id),
      flashing: widget.flashId == row.node.id,
      editable: editable,
      badge: widget.badgeFor?.call(row),
      draggable: draggable,
      onDragStarted: () => _startDrag(row.node.id),
      onDragEnd: _endDrag,
      onTap: widget.onTapRow == null ? null : () => widget.onTapRow!(row),
      onToggleCollapse: widget.onToggleCollapse == null
          ? null
          : () => widget.onToggleCollapse!(row),
      onAddAfter:
          widget.onAddAfter == null ? null : () => widget.onAddAfter!(row),
      onMoveUp: widget.onMoveUp == null ? null : () => widget.onMoveUp!(row),
      onMoveDown:
          widget.onMoveDown == null ? null : () => widget.onMoveDown!(row),
      onDelete: widget.onDelete == null ? null : () => widget.onDelete!(row),
      onMenu: widget.onMenu == null ? null : () => widget.onMenu!(row),
      onLongPress: widget.onLongPressRow == null
          ? null
          : () => widget.onLongPressRow!(row),
    );

    if (hover != null) {
      Widget highlight = _DropHighlight(
        hover: hover,
        row: row,
        scheme: scheme,
        l10n: l10n,
      );
      highlight = IgnorePointer(child: highlight);
      if (hover.warnings.isNotEmpty) {
        // Tooltip 必须在 IgnorePointer **外层**：落在里面时子树的命中测试被
        // 整个跳过，hover / 长按都到不了 tooltip，预警永远看不到。
        highlight = Tooltip(
          message: '${l10n.flow_dropRefWarning}\n${hover.warnings.join('\n')}',
          child: highlight,
        );
      }
      rowWidget = Stack(
        clipBehavior: Clip.none,
        children: [
          rowWidget,
          Positioned.fill(child: highlight),
        ],
      );
    }

    if (!widget.dragEnabled) return rowWidget;

    return DragTarget<String>(
      key: _boxKeys.putIfAbsent(row.node.id, () => GlobalKey()),
      onWillAcceptWithDetails: (details) =>
          widget.dragEnabled && _dragId != null,
      onMove: (details) => _onMove(row, details.offset),
      onLeave: (data) {
        if (_hover?.overId == row.node.id) setState(() => _hover = null);
        _onPointerLeaveRow();
      },
      onAcceptWithDetails: (details) => _onAccept(row, details),
      builder: (context, candidate, rejected) => rowWidget,
    );
  }
}

/// 落点提示：before/after 画一条带缩进的插入线，into 画高亮框；会断引用时变
/// 黄，非法落点变红；`if` 的 into 再叠 then / else 两个分支标签行。
class _DropHighlight extends StatelessWidget {
  const _DropHighlight({
    required this.hover,
    required this.row,
    required this.scheme,
    required this.l10n,
  });

  final _Hover hover;
  final FlowOutlineRow row;
  final ColorScheme scheme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final color = hover.target == null
        ? scheme.error
        : (hover.warnings.isNotEmpty ? Colors.amber : scheme.primary);

    if (hover.zone != DropZone.into) {
      return Padding(
        padding: EdgeInsets.only(left: 16.0 * row.depth),
        child: Align(
          alignment: hover.zone == DropZone.before
              ? Alignment.topCenter
              : Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            height: 3,
            color: color,
          ),
        ),
      );
    }

    Widget box = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: box),
        if (row.node.kind == 'if')
          Positioned.fill(
            child: IgnorePointer(
              child: Row(
                children: [
                  _branchChip(
                      l10n.flow_outlineThen, hover.branch == 'then', color),
                  _branchChip(
                      l10n.flow_outlineElse, hover.branch == 'else', color),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _branchChip(String label, bool active, Color color) => Expanded(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: active ? color : color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: active ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.l10n,
    required this.scheme,
    required this.theme,
    required this.row,
    required this.selected,
    required this.errors,
    required this.collapsed,
    required this.flashing,
    required this.editable,
    required this.badge,
    required this.draggable,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onTap,
    required this.onToggleCollapse,
    required this.onAddAfter,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onMenu,
    required this.onLongPress,
  });

  final AppLocalizations l10n;
  final ColorScheme scheme;
  final ThemeData theme;
  final FlowOutlineRow row;
  final bool selected;
  final int errors;
  final bool collapsed;
  final bool flashing;
  final bool editable;
  final (String, Color)? badge;
  final bool draggable;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnd;
  final VoidCallback? onTap;
  final VoidCallback? onToggleCollapse;
  final VoidCallback? onAddAfter;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDelete;
  final VoidCallback? onMenu;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    final hasChildren = node.children.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(left: 16.0 * row.depth, bottom: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: flashing ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: flashing
                ? scheme.primary
                : (selected ? scheme.primary : scheme.outlineVariant),
            width: flashing ? 2 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('row-${node.id}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                if (draggable) _dragHandle(),
                if (hasChildren)
                  IconButton(
                    key: ValueKey('collapse-${node.id}'),
                    icon: Icon(
                        collapsed ? Icons.chevron_right : Icons.expand_more),
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

  /// 只有手柄能触发拖拽：长按仍归「点选 + 说话」的多选用。
  Widget _dragHandle() => Draggable<String>(
        key: ValueKey('drag-${row.node.id}'),
        data: row.node.id,
        // DragTargetDetails.offset 是拖拽反馈的原点，不是指针。默认
        // childDragAnchorStrategy 会把「指针在手柄内的抓取偏移」带进落点，
        // 落点整体向上偏，自动滚动边界也跟着晚触发。改成指针锚点后
        // offset 就是指针本身。
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
          child: SizedBox(
            width: 220,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.drag_indicator, size: 18),
              title: Text(flowKindTitle(l10n, row.node),
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        childWhenDragging: const SizedBox(width: 20, height: 24),
        onDragStarted: onDragStarted,
        onDragEnd: (_) => onDragEnd?.call(),
        onDraggableCanceled: (_, __) => onDragEnd?.call(),
        child: Semantics(
          label: l10n.flow_dragHandle,
          child: Icon(Icons.drag_indicator,
              size: 18, color: scheme.onSurfaceVariant),
        ),
      );
}
