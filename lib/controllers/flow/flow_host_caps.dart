import '../../peer/models/flow_models.dart';

/// 这台主机能干什么（方案「关键设计 11」）。
///
/// 新 App 会连到旧主机：旧主机不认 `header` / `retype`，也不给节点标 `branch`。
/// 与其让客户端发出去再被拒（或者更糟 —— 安静地把节点放进错的分支），不如先
/// 按能力降级：缺什么就把对应的入口收起来，缺得太多整页只读。
class FlowHostCaps {
  const FlowHostCaps({
    required this.canEdit,
    required this.canEditHeader,
    required this.canRetype,
    required this.canMove,
    required this.branchesLabelled,
  });

  /// 结构编辑（insert / delete / move / wrap / unwrap）齐不齐。
  final bool canEdit;

  /// 能不能改定义头（`inputs` / `roles` / `limits` / `outputs`）。
  final bool canEditHeader;

  /// 能不能换节点类型。没有的话 `set <类型>=null` 也不许发（会删子树）。
  final bool canRetype;

  /// 支不支持挪动节点。没有的话重排入口全部收起。
  final bool canMove;

  /// `if` 的 `then` / `else` 子节点有没有带 `branch` 标记。
  ///
  /// 没有标记时，`if` 里的按下标派发会跨分支（实测 `else` 里的节点上移会跳进
  /// `then`），所以这种情况下 `if` 内一律不给结构操作。
  final bool branchesLabelled;

  /// 连 `move` 都没有的主机：只给看，不给改。
  bool get readOnly => !canEdit;

  static const FlowHostCaps none = FlowHostCaps(
    canEdit: false,
    canEditHeader: false,
    canRetype: false,
    canMove: false,
    branchesLabelled: false,
  );

  /// 从主机的 schema 和已经拿到的节点树推。
  ///
  /// [tree] 用来判断 `branch` 有没有标：树里出现 `if` 但它的子节点都没标，就
  /// 认为这台主机不带标记（而不是"这个流程恰好没有 if"）。
  factory FlowHostCaps.of(FlowSchema? schema, List<FlowNode> tree) {
    if (schema == null) return FlowHostCaps.none;
    final canMove = schema.hasOp('move');
    final canEdit = schema.hasOp('insert') &&
        schema.hasOp('delete') &&
        canMove &&
        schema.hasOp('wrap') &&
        schema.hasOp('unwrap');
    return FlowHostCaps(
      canEdit: canEdit,
      canEditHeader: schema.hasOp('header'),
      canRetype: schema.hasOp('retype'),
      canMove: canMove,
      branchesLabelled: _branchesLabelled(tree),
    );
  }

  /// 树里出现 `if` 但它的子节点没标 `branch`，就认为这台主机不带标记。
  /// 必须走遍整棵树：只查第一个 `if` 时，混合标注（旧主机数据 + 新数据）会漏掉
  /// 没标注的分支，界面一旦对它放开结构操作就会跨分支。
  static bool _branchesLabelled(List<FlowNode> tree) {
    bool visit(List<FlowNode> nodes) {
      for (final node in nodes) {
        if (node.kind == 'if' &&
            node.children.isNotEmpty &&
            !node.children.every((child) => child.branch != null)) {
          return false;
        }
        if (node.children.isNotEmpty && !visit(node.children)) return false;
      }
      return true;
    }

    return visit(tree);
  }
}
