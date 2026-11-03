import '../../peer/models/flow_models.dart';
import 'flow_executor.dart';

/// 「插入引用」的候选（方案 M4）。
///
/// 只列**当前节点之前**的步骤 —— 引用后面的步骤引擎会报「只能引用已经跑过的
/// 步骤」。还有 `inputs.*`，以及所在容器给的 `item` / `prev.*`。
class FlowReferences {
  FlowReferences._();

  static const _fieldsWithRefs = {
    'task.prompt',
    'when',
    'loop.until',
    'loop.while',
    'if.cond',
    'map.over',
    'gate.show',
    'plan.brief',
  };

  /// 这个字段要不要给「插入引用」按钮。
  static bool supports(String field) => _fieldsWithRefs.contains(field);

  /// 生成候选，`{{ path }}` 形式。
  static List<String> of({
    required List<FlowNode> tree,
    required String currentNodeId,
    required String yaml,
  }) {
    final out = <String>[];

    // 头部声明的输入。
    for (final spec in peekInputs(yaml)) {
      out.add('{{ inputs.${spec.name} }}');
    }

    // 当前节点之前的步骤：text 和 data 里的字段。
    var reached = false;
    void walk(List<FlowNode> nodes) {
      for (final node in nodes) {
        if (node.id == currentNodeId) {
          reached = true;
          return;
        }
        if (!reached) {
          out.add('{{ ${node.id}.text }}');
          // 声明了 output 的节点，那些键在运行时落在 `.data` 上。
          final task = node.fields?['task'];
          final output = task is Map ? task['output'] : null;
          if (output is Map) {
            for (final key in output.keys) {
              out.add('{{ ${node.id}.data.$key }}');
            }
          }
        }
        if (node.children.isNotEmpty) walk(node.children);
        if (reached) return;
      }
    }

    walk(tree);

    // 容器里才有的特殊引用。
    if (_inside(tree, currentNodeId, 'map')) out.add('{{ item }}');
    if (_inside(tree, currentNodeId, 'loop')) {
      out.add('{{ prev.text }}');
    }
    return out;
  }

  static bool _inside(List<FlowNode> nodes, String id, String kind,
      [bool parentMatches = false]) {
    for (final node in nodes) {
      if (node.id == id) return parentMatches;
      if (node.kind == kind &&
          node.children.isNotEmpty &&
          _inside(node.children, id, kind, true)) {
        return true;
      }
      if (node.children.isNotEmpty && _inside(node.children, id, kind)) {
        return true;
      }
    }
    return false;
  }
}
