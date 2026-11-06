import '../../peer/models/flow_models.dart';
import 'flow_edit_ops.dart';
import 'flow_executor.dart';
import 'flow_outline.dart';

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

  static bool _inside(
    List<FlowNode> nodes,
    String id,
    String kind, [
    bool inside = false,
  ]) {
    for (final node in nodes) {
      if (node.id == id) return inside;
      if (node.children.isNotEmpty &&
          _inside(node.children, id, kind, inside || node.kind == kind)) {
        return true;
      }
    }
    return false;
  }
}

// ── 拖放的软预检（方案 c0bd02d7）─────────────────────────────────────────────

/// 前序文档顺序里的一个节点，带上它祖先的类型。
class _Entry {
  _Entry(this.node, this.ancestorKinds);
  final FlowNode node;
  final List<String> ancestorKinds;
  String get id => node.id;
}

List<_Entry> _preOrder(List<FlowNode> tree) {
  final out = <_Entry>[];
  void walk(List<FlowNode> nodes, List<String> ancestors) {
    for (final n in nodes) {
      out.add(_Entry(n, ancestors));
      if (n.children.isNotEmpty) walk(n.children, [...ancestors, n.kind]);
    }
  }

  walk(tree, const []);
  return out;
}

Iterable<String> _allStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final v in value.values) {
      yield* _allStrings(v);
    }
  } else if (value is Iterable) {
    for (final v in value) {
      yield* _allStrings(v);
    }
  }
}

final RegExp _refPattern =
    RegExp(r'\{\{\s*([A-Za-z0-9_-]+)\.(?:text|data)[^}]*\}\}');

/// 一个节点引用的其它步骤：命中步骤 id，以及**原文里的引用表达式**。
///
/// 预警要指回用户真正写的那个字段（`{{ a.data.rows }}`），不能统一写成
/// `.text` —— 那会指向一个用户没写过的引用。
Iterable<({String id, String expression})> _refsOf(FlowNode node) sync* {
  for (final s in _allStrings(node.fields)) {
    for (final m in _refPattern.allMatches(s)) {
      final id = m.group(1);
      if (id != null &&
          id != 'inputs' &&
          id != 'prev' &&
          id != 'item' &&
          id != 'index') {
        yield (id: id, expression: m.group(0) ?? '{{ $id.text }}');
      }
    }
  }
}

List<FlowNode> _removeNode(List<FlowNode> nodes, String id) => [
      for (final n in nodes)
        if (n.id != id) n.copyWith(children: _removeNode(n.children, id)),
    ];

List<FlowNode> _insertAsChild(
  List<FlowNode> children,
  FlowNode drag,
  int? index,
  String? branch,
  bool parentIsIf,
) {
  if (parentIsIf && branch != null) {
    final out = <FlowNode>[];
    var branchIdx = 0;
    var inserted = false;
    for (final c in children) {
      final b = c.branch ?? 'then';
      // 追加到 then：放在第一段 else 之前；追加到 else：落到末尾。
      if (b == 'else' && branch == 'then' && index == null && !inserted) {
        out.add(drag);
        inserted = true;
      }
      if (b == branch && index != null && branchIdx == index && !inserted) {
        out.add(drag);
        inserted = true;
      }
      if (b == branch) branchIdx++;
      out.add(c);
    }
    if (!inserted) out.add(drag);
    return out;
  }
  final out = List<FlowNode>.from(children);
  if (index == null || index >= out.length) {
    out.add(drag);
  } else {
    out.insert(index < 0 ? 0 : index, drag);
  }
  return out;
}

List<FlowNode> _reinsert(
  List<FlowNode> nodes,
  String parentId,
  FlowNode drag,
  int? index,
  String? branch,
) =>
    [
      for (final n in nodes)
        n.id == parentId
            ? n.copyWith(
                children: _insertAsChild(
                    n.children, drag, index, branch, n.kind == 'if'))
            : n.copyWith(
                children: _reinsert(n.children, parentId, drag, index, branch)),
    ];

/// 按落点模拟一次移动：先整树摘掉被拖节点，再插到目标父节点里。
List<FlowNode> _simulateMove(
  List<FlowNode> tree,
  FlowNode drag,
  FlowDropTarget target,
) {
  final removed = _removeNode(tree, drag.id);
  if (target.parentId.isEmpty) {
    return _insertAsChild(removed, drag, target.index, null, false);
  }
  return _reinsert(removed, target.parentId, drag, target.index, target.branch);
}

/// 拖放前的软预检，只提示不拦截。用前序文档顺序模拟一次，找出「本来合法、
/// 移动后才坏」的引用，以及离开 map/loop 的特殊变量、被抽空的容器等。
///
/// 真正的结论以主机回来的 diagnostics 为准（能解析的结果主机返回 success +
/// diagnostics）。返回的是给人看的短文案，界面把它们列在黄色落点的 tooltip 里。
List<String> refWarningsAfterMove(
  List<FlowNode> tree,
  String dragId,
  FlowDropTarget target,
) {
  final warnings = <String>[];
  final drag = flowLocate(tree, dragId)?.node;
  if (drag == null) return warnings;

  final before = _preOrder(tree);
  final moved = _simulateMove(tree, drag, target);
  final after = _preOrder(moved);
  final beforeIndex = <String, int>{
    for (var i = 0; i < before.length; i++) before[i].id: i,
  };
  final afterIndex = <String, int>{
    for (var i = 0; i < after.length; i++) after[i].id: i,
  };

  // 1) 前向引用：之前能解析（引用在前面），移动后引用跑到后面去了。
  for (final entry in after) {
    for (final ref in _refsOf(entry.node)) {
      final bi = beforeIndex[ref.id];
      final bj = beforeIndex[entry.id];
      final ai = afterIndex[ref.id];
      final aj = afterIndex[entry.id];
      if (bi == null || bj == null || ai == null || aj == null) continue;
      if (bi < bj && ai >= aj) {
        warnings.add('${ref.expression} ← ${entry.id}');
      }
    }
  }

  // 2) 被拖子树里的节点用到 {{ item }}/{{ index }}/prev.*，移动后离开了
  //    map / loop 祖先。
  final dragIds = <String>{};
  void collect(FlowNode n) {
    dragIds.add(n.id);
    for (final c in n.children) {
      collect(c);
    }
  }

  collect(drag);
  for (final entry in after.where((e) => dragIds.contains(e.id))) {
    final text = _allStrings(entry.node.fields).join(' ');
    // `{{ item }}` / `{{ index }}`，以及访问字段的 `{{ item.name }}`。
    if (RegExp(r'\{\{\s*(item|index)(?:\s*\.\s*[A-Za-z0-9_]+)?\s*\}\}')
            .hasMatch(text) &&
        !entry.ancestorKinds.contains('map')) {
      warnings.add('{{ item }} / {{ index }} ← ${entry.id}');
    }
    if (text.contains('prev.') && !entry.ancestorKinds.contains('loop')) {
      warnings.add('prev.* ← ${entry.id}');
    }
  }

  // 3) 把容器里最后一个子节点拖走会让容器变空（seq/par/loop 空了会报错）。
  //    拖回原容器（into 区 / 同父换位置）时容器不会变空，别误报。
  final origParent = flowLocate(tree, dragId)?.parent;
  if (origParent != null &&
      target.parentId != origParent.id &&
      FlowStepDefaults.isContainer(origParent.kind) &&
      origParent.children.length == 1) {
    warnings.add('${origParent.id} (empty container)');
  }

  // 4) 拖进 par：join.at_least 和变量写冲突交给主机诊断。
  final newParent =
      target.parentId.isEmpty ? null : flowLocate(moved, target.parentId)?.node;
  if (newParent?.kind == 'par') {
    warnings.add('par ${newParent!.id} (join/write)');
  }

  return warnings;
}
