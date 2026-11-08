import '../../peer/models/flow_models.dart';
import 'flow_edit_ops.dart';
import 'flow_executor.dart';
import 'flow_outline.dart';

/// 变量树里的一层。点有子节点的项会接着列出下一级，点叶子才补上 `}}`。
class FlowVarNode {
  const FlowVarNode({
    required this.segment,
    this.hint = '',
    this.children = const [],
  });

  /// 写进 `{{ }}` 的那一段，例如 `prev`、`text`、`goal`。
  final String segment;

  /// 给界面的短说明（中文）。空字符串表示不展示。
  final String hint;
  final List<FlowVarNode> children;

  bool get hasChildren => children.isNotEmpty;
}

/// 光标停在一个还没写完的 `{{` 里时，该列出哪一层、过滤词是什么。
class FlowVarSuggest {
  const FlowVarSuggest({
    required this.options,
    required this.filter,
    required this.replaceFrom,
    required this.cursor,
  });

  final List<FlowVarNode> options;
  final String filter;

  /// 当前这一段在全文里的起点，选中后从这里替换到光标。
  final int replaceFrom;
  final int cursor;

  List<FlowVarNode> get matches {
    if (filter.isEmpty) return options;
    return [
      for (final node in options)
        if (node.segment.startsWith(filter)) node,
    ];
  }
}

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

  /// 给输入 `{{` 时逐级展开的变量树。
  ///
  /// 第一层是 `inputs`、前面的步骤、循环里的 `prev`、遍历里的 `item` /
  /// `index`。点进 `prev` 或某个步骤，下一层才是 `text` / `data` / `status`。
  static List<FlowVarNode> tree({
    required List<FlowNode> tree,
    required String currentNodeId,
    required String yaml,
  }) {
    final roots = <FlowVarNode>[];
    final inputs = peekInputs(yaml);
    if (inputs.isNotEmpty) {
      roots.add(FlowVarNode(
        segment: 'inputs',
        hint: '流程输入',
        children: [
          for (final spec in inputs)
            FlowVarNode(segment: spec.name, hint: spec.type),
        ],
      ));
    }
    for (final node in _before(tree, currentNodeId)) {
      roots.add(_stepVar(node));
    }
    if (_inside(tree, currentNodeId, 'map')) {
      roots.add(const FlowVarNode(segment: 'item', hint: '当前项'));
      roots.add(const FlowVarNode(segment: 'index', hint: '当前序号'));
    }
    if (_inside(tree, currentNodeId, 'loop')) {
      final inner = _underLoop(tree, currentNodeId);
      roots.add(FlowVarNode(
        segment: 'prev',
        hint: '上一轮',
        children: [for (final node in inner) _stepVar(node)],
      ));
    }
    return roots;
  }

  /// 光标在未闭合的 `{{ ...` 里时返回当前这一层；否则 null。
  static FlowVarSuggest? suggest({
    required String text,
    required int cursor,
    required List<FlowVarNode> roots,
  }) {
    if (cursor < 0 || cursor > text.length) return null;
    final before = text.substring(0, cursor);
    final open = before.lastIndexOf('{{');
    if (open < 0) return null;
    final body = before.substring(open + 2);
    if (body.contains('}}')) return null;
    final trimmed = body.trimLeft();
    final lead = body.length - trimmed.length;
    final parts = trimmed.split('.');
    var level = roots;
    for (var i = 0; i < parts.length - 1; i++) {
      final name = parts[i].trim();
      if (name.isEmpty) return null;
      FlowVarNode? found;
      for (final node in level) {
        if (node.segment == name) {
          found = node;
          break;
        }
      }
      if (found == null) return null;
      level = found.children;
    }
    final filter = parts.last;
    return FlowVarSuggest(
      options: level,
      filter: filter,
      replaceFrom: open + 2 + lead + trimmed.length - filter.length,
      cursor: cursor,
    );
  }

  static FlowVarNode _stepVar(FlowNode node) {
    final keys = _outputKeys(node);
    return FlowVarNode(
      segment: node.id,
      hint: node.kind,
      children: [
        const FlowVarNode(segment: 'text', hint: '文字结果'),
        FlowVarNode(
          segment: 'data',
          hint: '结构化字段',
          children: [
            for (final key in keys) FlowVarNode(segment: key, hint: '字段'),
          ],
        ),
        const FlowVarNode(segment: 'status', hint: '状态'),
      ],
    );
  }

  static List<String> _outputKeys(FlowNode node) {
    final task = node.fields?['task'];
    final output = task is Map ? task['output'] : null;
    if (output is! Map) return const [];
    return [for (final key in output.keys) key.toString()];
  }

  /// 当前节点之前（文档顺序）的步骤，不含它自己。
  static List<FlowNode> _before(List<FlowNode> tree, String id) {
    final out = <FlowNode>[];
    var hit = false;
    void walk(List<FlowNode> nodes) {
      for (final node in nodes) {
        if (node.id == id) {
          hit = true;
          return;
        }
        out.add(node);
        if (node.children.isNotEmpty) walk(node.children);
        if (hit) return;
      }
    }

    walk(tree);
    return out;
  }

  /// 包住当前节点的那一层 loop 里的全部步骤（上一轮里它们都跑过）。
  static List<FlowNode> _underLoop(List<FlowNode> tree, String id) {
    List<FlowNode>? loopKids;
    bool find(List<FlowNode> nodes, List<FlowNode>? kids) {
      for (final node in nodes) {
        final nextKids = node.kind == 'loop' ? node.children : kids;
        if (node.id == id) {
          loopKids = nextKids;
          return true;
        }
        if (node.children.isNotEmpty && find(node.children, nextKids)) {
          return true;
        }
      }
      return false;
    }

    if (!find(tree, null) || loopKids == null) return const [];
    final out = <FlowNode>[];
    void collect(List<FlowNode> nodes) {
      for (final node in nodes) {
        out.add(node);
        if (node.children.isNotEmpty) collect(node.children);
      }
    }

    collect(loopKids!);
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
    // 主机的 `move` 把 index 当作**该分支数组内**的下标：then 段和 else 段是
    // 各自独立计数的，越界就夹到该分支末尾。旧实现按整份 children 的序号找
    // branchIdx==index，then 有 1 个子、index=1 时找不到，节点被追加到所有
    // else 之后，前序索引全错（A8-9）。
    String branchOf(FlowNode child) => child.branch == 'else' ? 'else' : 'then';
    final targetBranch = branch == 'else' ? 'else' : 'then';
    final branchCount =
        children.where((c) => branchOf(c) == targetBranch).length;
    final wanted = index == null ? branchCount : index.clamp(0, branchCount);
    // 把分支内下标翻译成扁平 children 里的插入位置。
    var flatIndex = children.length;
    if (wanted < branchCount) {
      var seen = 0;
      for (var i = 0; i < children.length; i++) {
        if (branchOf(children[i]) != targetBranch) continue;
        if (seen == wanted) {
          flatIndex = i;
          break;
        }
        seen++;
      }
    } else if (targetBranch == 'then') {
      // then 段末尾 = 第一段 else 之前；没有 else 就是整份 children 的末尾。
      for (var i = 0; i < children.length; i++) {
        if (branchOf(children[i]) == 'else') {
          flatIndex = i;
          break;
        }
      }
    }
    final out = List<FlowNode>.from(children);
    out.insert(flatIndex, drag);
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

  // 4) 从外面拖进 par：join.at_least 和变量写冲突交给主机诊断。
  //    同一 par 内换个位置不会改变并行关系，别误报（A6-10）。
  final newParent =
      target.parentId.isEmpty ? null : flowLocate(moved, target.parentId)?.node;
  if (newParent?.kind == 'par' && target.parentId != origParent?.id) {
    warnings.add('par ${newParent!.id} (join/write)');
  }

  return warnings;
}

/// 哪些步骤用到了某个输入或角色。算不出来就给空表，调用方不显示、也不拦编辑。
class FlowHeaderUsage {
  FlowHeaderUsage._();

  static Map<String, List<String>> inputs(List<FlowNode> tree) {
    final out = <String, List<String>>{};
    for (final node in _nodes(tree)) {
      final text = _strings(node.fields).join('\n');
      for (final match in RegExp(r'inputs\.([A-Za-z0-9_-]+)').allMatches(text)) {
        final name = match.group(1)!;
        final users = out[name] ??= <String>[];
        if (node.id.isNotEmpty && !users.contains(node.id)) users.add(node.id);
      }
    }
    return out;
  }

  static Map<String, List<String>> roles(List<FlowNode> tree) {
    final out = <String, List<String>>{};
    for (final node in _nodes(tree)) {
      final task = node.fields?['task'];
      final role = task is Map ? task['role']?.toString().trim() : null;
      if (role == null || role.isEmpty || node.id.isEmpty) continue;
      final users = out[role] ??= <String>[];
      if (!users.contains(node.id)) users.add(node.id);
    }
    return out;
  }

  static List<FlowNode> _nodes(List<FlowNode> tree) {
    final out = <FlowNode>[];
    void walk(List<FlowNode> nodes) {
      for (final node in nodes) {
        out.add(node);
        walk(node.children);
      }
    }

    walk(tree);
    return out;
  }

  static List<String> _strings(Object? value) {
    if (value is String) return [value];
    if (value is Map) {
      return [for (final entry in value.values) ..._strings(entry)];
    }
    if (value is List) {
      return [for (final item in value) ..._strings(item)];
    }
    return const [];
  }
}
