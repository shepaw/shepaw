import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';

/// 一条诊断指的是哪儿。
sealed class FlowDiagnosticTarget {}

/// 指向某个节点。`field` 是从诊断文案里抽出的字段名（`prompt`、`timeout`、
/// `loop.max`），定位时用来滚到那个输入框。抽不出来就是 null。
class NodeTarget extends FlowDiagnosticTarget {
  NodeTarget(this.nodeId, {this.field});

  final String nodeId;
  final String? field;
}

/// 指向定义头上的某个字段（`inputs.goal`、`limits.timeout`…）。
class HeaderTarget extends FlowDiagnosticTarget {
  HeaderTarget(this.field);

  final String field;
}

/// 没有具体位置（整份定义的问题）。
class GlobalTarget extends FlowDiagnosticTarget {}

/// 头部字段的前缀，用来判断 `at` 是不是在说头。
const _headerPrefixes = ['inputs', 'roles', 'limits', 'outputs', 'description'];

/// 把诊断的 `at` 翻译成一个定位目标。
///
/// 诊断的 `at` 是节点路径（`l/t`），而树的 `key` 带轮次（`l#0/t`），**不能直接
/// 比**。好在节点 id 全局唯一（`insert` / `wrap` 都查重），所以取最后一段按 id
/// 匹配。
FlowDiagnosticTarget resolveDiagnostic(
  FlowDiagnostic diagnostic,
  List<FlowNode> tree,
) {
  final at = diagnostic.at;
  if (at.isEmpty) return GlobalTarget();
  final head = at.split('.').first.split('/').first;
  if (_headerPrefixes.contains(head)) return HeaderTarget(at);
  final id = at.split('/').last;
  if (id.isEmpty) return GlobalTarget();
  for (final node in tree) {
    if (node.find((n) => n.id == id) != null) {
      return NodeTarget(id, field: fieldHintFromMessage(diagnostic.message));
    }
  }
  return GlobalTarget();
}

const _kindNames = {
  'task',
  'seq',
  'par',
  'loop',
  'if',
  'map',
  'gate',
  'set',
  'call',
  'plan',
};

/// 主机把出错的字段写在反引号里（`` `prompt` ``、`` `loop.max` ``）。
/// 类型名（`task`）跳过，有带点的路径就用路径。
String? fieldHintFromMessage(String message) {
  final matches = RegExp(r'`([^`]+)`').allMatches(message);
  String? leaf;
  for (final match in matches) {
    final token = match.group(1)!;
    if (token.contains(' ') || token.contains('/')) continue;
    if (token.contains('.')) return token;
    if (_kindNames.contains(token)) continue;
    leaf = token;
  }
  return leaf;
}
