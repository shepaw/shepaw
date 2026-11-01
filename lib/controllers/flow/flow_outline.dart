import '../../peer/models/flow_models.dart';
import 'flow_edit_ops.dart';

/// 大纲里的一行（方案 M3）。
///
/// 树是嵌套的，操作却是「上移 / 下移 / 在后面加一步」这种线性说法。这里把树
/// 摊平成带深度的行，并把每一步要用的 `parent_id` / `index` / `branch` 算好，
/// [FlowEditOps] 就不用再猜。
///
/// **`if` 的两个分支在 `children` 里是拼在一起的**，所以：
/// - [branch] 记下这一行属于哪一支；
/// - [index] 是**分支内的相对下标**，不是拼起来之后的下标。用错就会把 `else`
///   里的节点挪进 `then`（实测过）。
class FlowOutlineRow {
  const FlowOutlineRow({
    required this.node,
    required this.depth,
    required this.parentId,
    required this.index,
    this.branch,
    required this.siblingCount,
  });

  final FlowNode node;

  /// 根层为 0。
  final int depth;

  /// 父节点 id；空串表示根层。
  final String parentId;

  /// 同一父节点（同一分支）内的下标。
  final int index;

  /// 父节点是 `if` 时这一行属于哪一支。其余情况为 null。
  final String? branch;

  /// 同一分支里有多少个兄弟。上移 / 下移能不能用看它。
  final int siblingCount;

  bool get canMoveUp => index > 0;
  bool get canMoveDown => index < siblingCount - 1;

  /// 父节点是 `if`：所有结构操作都必须带 [branch]，否则会跨分支。
  bool get inIfBranch => branch != null;
}

/// 把树摊平成行。[collapsed] 里的节点不展开子节点。
List<FlowOutlineRow> buildFlowOutline(
  List<FlowNode> tree, {
  Set<String> collapsed = const {},
}) {
  final rows = <FlowOutlineRow>[];
  void walk(List<FlowNode> nodes, int depth, String parentId, bool parentIsIf) {
    if (parentIsIf) {
      var then = 0;
      var els = 0;
      final counts = <String, int>{'then': 0, 'else': 0};
      for (final node in nodes) {
        final branch = node.branch ?? 'then';
        counts[branch] = (counts[branch] ?? 0) + 1;
      }
      for (final node in nodes) {
        final branch = node.branch ?? 'then';
        final index = branch == 'else' ? els++ : then++;
        rows.add(FlowOutlineRow(
          node: node,
          depth: depth,
          parentId: parentId,
          index: index,
          branch: branch,
          siblingCount: counts[branch] ?? 1,
        ));
        if (node.children.isNotEmpty && !collapsed.contains(node.id)) {
          walk(node.children, depth + 1, node.id, node.kind == 'if');
        }
      }
      return;
    }
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      rows.add(FlowOutlineRow(
        node: node,
        depth: depth,
        parentId: parentId,
        index: i,
        siblingCount: nodes.length,
      ));
      if (node.children.isNotEmpty && !collapsed.contains(node.id)) {
        walk(node.children, depth + 1, node.id, node.kind == 'if');
      }
    }
  }

  walk(tree, 0, '', false);
  return rows;
}

/// 从行直接产出的操作。全是对 [FlowEditOps] 的一层薄封装，把「这一行」翻译成
/// `parent_id` / `index` / `branch`。
class FlowOutlineOps {
  FlowOutlineOps._();

  static Map<String, dynamic> moveUp(FlowOutlineRow row) => FlowEditOps.move(
        nodeId: row.node.id,
        parentId: row.parentId,
        index: row.index - 1,
        branch: row.branch,
      );

  static Map<String, dynamic> moveDown(FlowOutlineRow row) => FlowEditOps.move(
        nodeId: row.node.id,
        parentId: row.parentId,
        index: row.index + 1,
        branch: row.branch,
      );

  /// 在这一行后面加一步。父节点是 `if` 时落进同一支。
  static Map<String, dynamic> insertAfter(
    FlowOutlineRow row,
    Map<String, dynamic> step,
  ) =>
      FlowEditOps.insert(
        parentId: row.parentId,
        index: row.index + 1,
        branch: row.branch,
        step: step,
      );

  /// 往一个容器里加子步骤。空容器也能加（主机自己建数组）。
  static Map<String, dynamic> insertChild(
    FlowNode parent,
    Map<String, dynamic> step, {
    String? branch,
  }) =>
      FlowEditOps.insert(
        parentId: parent.id,
        index: 0,
        branch: branch,
        step: step,
      );
}
