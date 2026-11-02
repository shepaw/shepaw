import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

/// 一次编辑改动前的快照。
///
/// 存三元组而不是只存 YAML：撤销就不需要再问主机要树和诊断，也不可能因为
/// 主机状态变了而和界面不一致。
class FlowEditorSnapshot {
  const FlowEditorSnapshot({
    required this.yaml,
    required this.tree,
    required this.diagnostics,
  });

  final String yaml;
  final List<FlowNode> tree;
  final List<FlowDiagnostic> diagnostics;
}

/// 撤销栈。
///
/// 主机的 `flow_edit_req` 是整批原子操作，回来的是新的（yaml, tree,
/// diagnostics）三元组，所以记快照比记"操作的逆操作"简单得多 —— `wrap` /
/// `unwrap` / 改节点类型的逆操作写起来很绕，而且容易和主机的语义对不上。
class FlowEditorHistory {
  FlowEditorHistory({this.limit = 40});

  /// 最多记多少步。一份树很小，按条数限就够了。
  final int limit;

  final List<FlowEditorSnapshot> _past = [];
  final List<FlowEditorSnapshot> _future = [];

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// 记一步改动前的状态。
  ///
  /// [coalesce] 为 true 时不新压一条，保留栈顶那份更早的状态 —— 也就是把这次
  /// 改动并进上一步。打一段提示词会触发好几次防抖发送，不合并的话 40 步 undo
  /// 瞬间就用完了。
  void record(FlowEditorSnapshot snapshot, {bool coalesce = false}) {
    if (coalesce && _past.isNotEmpty) return;
    _past.add(snapshot);
    if (_past.length > limit) {
      _past.removeAt(0);
    }
    // 有了新的改动，之前"重做"的那条分支就作废了。
    _future.clear();
  }

  /// 撤销：把 [current] 推到将来，返回要退回到的那一步。
  FlowEditorSnapshot? undo(FlowEditorSnapshot current) {
    if (_past.isEmpty) return null;
    final previous = _past.removeLast();
    _future.add(current);
    return previous;
  }

  FlowEditorSnapshot? redo(FlowEditorSnapshot current) {
    if (_future.isEmpty) return null;
    final next = _future.removeLast();
    _past.add(current);
    return next;
  }

  void clear() {
    _past.clear();
    _future.clear();
  }
}
