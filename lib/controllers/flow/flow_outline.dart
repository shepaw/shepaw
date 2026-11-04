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
    required this.siblingCount,
    this.branch,
    this.previousSibling,
    this.parent,
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

  /// 同一父节点（同一分支）里的前一个兄弟。缩进菜单要用它。
  final FlowNode? previousSibling;

  /// 同一分支里有多少个兄弟。上移 / 下移能不能用看它。
  final int siblingCount;

  /// 父节点那一行。取消缩进要用它：得知道往哪一层挪、插在第几位。
  /// 根层的行没有父行。
  final FlowOutlineRow? parent;

  /// 有地方可以取消缩进（不是根层，且父行找得到）。
  bool get canOutdent => parent != null;

  bool get canMoveUp => index > 0;
  bool get canMoveDown => index < siblingCount - 1;

  /// 父节点是 `if`：所有结构操作都必须带 [branch]，否则会跨分支。
  bool get inIfBranch => branch != null;
}

/// `if` 的两支是拼在一起的，前一个兄弟要在**同一支**里找。
FlowNode? _previousInBranch(
  List<FlowNode> nodes,
  FlowNode node,
  String branch,
) {
  FlowNode? last;
  for (final candidate in nodes) {
    if (identical(candidate, node)) return last;
    if ((candidate.branch ?? 'then') == branch) last = candidate;
  }
  return last;
}

/// 把树摊平成行。[collapsed] 里的节点不展开子节点。
List<FlowOutlineRow> buildFlowOutline(
  List<FlowNode> tree, {
  Set<String> collapsed = const {},
}) {
  final rows = <FlowOutlineRow>[];
  void walk(
    List<FlowNode> nodes,
    int depth,
    String parentId,
    bool parentIsIf,
    FlowOutlineRow? parentRow,
  ) {
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
          previousSibling: index == 0
              ? null
              : _previousInBranch(nodes, node, branch),
          parent: parentRow,
        ));
        if (node.children.isNotEmpty && !collapsed.contains(node.id)) {
          walk(node.children, depth + 1, node.id, node.kind == 'if', rows.last);
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
        previousSibling: i == 0 ? null : nodes[i - 1],
        parent: parentRow,
      ));
      if (node.children.isNotEmpty && !collapsed.contains(node.id)) {
        walk(node.children, depth + 1, node.id, node.kind == 'if', rows.last);
      }
    }
  }

  walk(tree, 0, '', false, null);
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

  /// 往容器里加子步骤。空容器也能加（主机自己建数组）。
  static Map<String, dynamic> insertChild(
    FlowNode parent,
    Map<String, dynamic> step, {
    String? branch,
  }) =>
      FlowEditOps.insertChild(
        parentId: parent.id,
        branch: branch,
        step: step,
      );

  /// 取消缩进：挪到父节点后面那一层。
  ///
  /// 插在父节点**之后**（`parent.index + 1`），这样顺序看起来没变。父节点是
  /// `if` 时 branch 跟着父行走。
  static Map<String, dynamic> outdent(FlowOutlineRow row) => FlowEditOps.move(
        nodeId: row.node.id,
        parentId: row.parent!.parentId,
        index: row.parent!.index + 1,
        branch: row.parent!.branch,
      );
  ///
  /// 和「包起来」的区别：这只是换个父节点，不新建容器，也不改执行语义。
  static Map<String, dynamic> moveIntoPrevious(FlowOutlineRow row) =>
      FlowEditOps.move(
        nodeId: row.node.id,
        parentId: row.previousSibling!.id,
      );

  /// 把当前节点和上一个兄弟一起包进一个新容器。
  ///
  /// 这是**显式**的选择 —— 以前「缩进」遇到叶子兄弟会悄悄造一个 seq，用户并不
  /// 知道自己多了一层，移进 `par` / `loop` 还会改变执行语义（并发、重复）。
  /// 菜单项要写清是哪一种。
  static List<Map<String, dynamic>> wrapWithPrevious(
    FlowOutlineRow row,
    String kind,
    String wrapperId,
  ) =>
      FlowEditOps.indentIntoLeaf(
        nodeId: row.node.id,
        previousSiblingId: row.previousSibling!.id,
        wrapperId: wrapperId,
        kind: kind,
      );

  /// 显式移到 `if` 的另一支。不带 index → 追加到该支末尾，不会按拼接后的
  /// 下标把节点放错位置。
  static Map<String, dynamic> moveToBranch(
    FlowOutlineRow row,
    String branch,
  ) =>
      FlowEditOps.move(
        nodeId: row.node.id,
        parentId: row.parentId,
        branch: branch,
      );

  /// 换节点类型。只发一个 `retype`，由主机保留 id 和公共字段。
  static Map<String, dynamic> retype(
    FlowOutlineRow row,
    String kind, {
    Map<String, dynamic>? body,
  }) =>
      FlowEditOps.retype(nodeId: row.node.id, kind: kind, body: body);
}
