/// 工作流在 App 侧的数据（方案 C.2 / B.8）。App 不解析 YAML：节点树由 Hub 的
/// `flow_validate_resp` / `flow_run_get_resp` 给出，这里只做解码。
library;

enum FlowNodeStatus {
  pending,
  running,
  done,
  halted,
  failed,
  skipped,
  cancelled;

  static FlowNodeStatus? parse(Object? raw) {
    if (raw is! String) return null;
    for (final value in FlowNodeStatus.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  bool get isTerminal => switch (this) {
        FlowNodeStatus.pending || FlowNodeStatus.running => false,
        _ => true,
      };
}

enum FlowRunStatus {
  running,
  succeeded,
  failed,
  cancelled;

  static FlowRunStatus? parse(Object? raw) {
    if (raw is! String) return null;
    for (final value in FlowRunStatus.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  bool get isFinished => this != FlowRunStatus.running;
}

class FlowNode {
  const FlowNode({
    required this.key,
    required this.id,
    required this.kind,
    this.desc,
    this.status,
    this.attempt = 0,
    this.iter,
    this.rounds,
    this.text,
    this.error,
    this.children = const [],
    this.session,
    this.options = const [],
    this.fields,
    this.branch,
  });

  /// 定位键（`build#2/impl/backend`）。事件、作答、查看会话都用它。
  final String key;
  final String id;
  final String kind;
  final String? desc;

  /// 没有运行信息（设计预览）时为 null。
  final FlowNodeStatus? status;
  final int attempt;
  final int? iter;
  final int? rounds;
  final String? text;
  final String? error;
  final List<FlowNode> children;
  final String? session;

  /// `gate` 的可选项。
  final List<String> options;

  /// 节点自己的字段（设计视图才有），检查器回填当前值。
  final Map<String, dynamic>? fields;

  /// 父节点是 `if` 时这一步属于哪一支：`then` / `else`。
  ///
  /// `if` 的两个分支在 `children` 里是拼在一起的，光靠下标分不出来。旧主机
  /// 不带这个字段（[FlowHostCaps.branchesLabelled] 为 false），那时 `if` 内
  /// 一律不给结构操作。
  final String? branch;

  bool get isContainer => children.isNotEmpty;

  /// 关卡正在等人回答。
  bool get awaitsAnswer => kind == 'gate' && status == FlowNodeStatus.running;

  FlowNode copyWith(
          {FlowNodeStatus? status, int? attempt, List<FlowNode>? children}) =>
      FlowNode(
        key: key,
        id: id,
        kind: kind,
        desc: desc,
        status: status ?? this.status,
        attempt: attempt ?? this.attempt,
        iter: iter,
        rounds: rounds,
        text: text,
        error: error,
        children: children ?? this.children,
        session: session,
        options: options,
        fields: fields,
        branch: branch,
      );

  factory FlowNode.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    String? asText(Object? v) => v is String && v.isNotEmpty ? v : null;
    final rawChildren = json['children'];
    final rawOptions = json['options'];
    return FlowNode(
      key: (json['key'] as String?) ?? (json['id'] as String? ?? ''),
      id: (json['id'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? '',
      desc: asText(json['desc']),
      status: FlowNodeStatus.parse(json['status']),
      attempt: asInt(json['attempt']) ?? 0,
      iter: asInt(json['iter']),
      rounds: asInt(json['rounds']),
      text: asText(json['text']),
      error: asText(json['error']),
      children: rawChildren is List
          ? [
              for (final child in rawChildren)
                if (child is Map)
                  FlowNode.fromJson(Map<String, dynamic>.from(child)),
            ]
          : const [],
      session: asText(json['session']),
      options: rawOptions is List
          ? [for (final item in rawOptions) item.toString()]
          : const [],
      fields: json['fields'] is Map
          ? Map<String, dynamic>.from(json['fields'] as Map)
          : null,
      branch: asText(json['branch']),
    );
  }

  /// 在这棵树里按 key 改一个节点；找不到原样返回。
  FlowNode mapNode(String targetKey, FlowNode Function(FlowNode) change) {
    if (key == targetKey) return change(this);
    if (children.isEmpty) return this;
    var touched = false;
    final next = [
      for (final child in children)
        () {
          final updated = child.mapNode(targetKey, change);
          if (!identical(updated, child)) touched = true;
          return updated;
        }(),
    ];
    return touched ? copyWith(children: next) : this;
  }

  /// 演练的动画帧：派活顺序里已经走过的叶子是完成，正在走的是进行中，其余等待；
  /// 容器按子节点汇总。`done` / `running` 是节点 key。
  FlowNode withProgress(Set<String> done, String? running) {
    final kids = [for (final c in children) c.withProgress(done, running)];
    FlowNodeStatus status;
    if (kids.isEmpty) {
      status = key == running
          ? FlowNodeStatus.running
          : done.contains(key)
              ? FlowNodeStatus.done
              : FlowNodeStatus.pending;
    } else if (kids.every((k) => k.status == FlowNodeStatus.done)) {
      status = FlowNodeStatus.done;
    } else if (kids.every((k) => k.status == FlowNodeStatus.pending)) {
      status = FlowNodeStatus.pending;
    } else {
      status = FlowNodeStatus.running;
    }
    return FlowNode(
      key: key,
      id: id,
      kind: kind,
      desc: desc,
      status: status,
      rounds: rounds,
      children: kids,
      options: options,
      fields: fields,
    );
  }

  /// 深度优先找第一个满足条件的节点。
  FlowNode? find(bool Function(FlowNode) test) {
    if (test(this)) return this;
    for (final child in children) {
      final hit = child.find(test);
      if (hit != null) return hit;
    }
    return null;
  }
}

/// `flow_run_get_resp` 的内容。
class FlowRunView {
  const FlowRunView({
    required this.runId,
    required this.status,
    required this.tasksUsed,
    required this.tree,
    this.error,
    this.children = const [],
    this.yaml = '',
  });

  final String runId;
  final FlowRunStatus status;
  final int tasksUsed;
  final List<FlowNode> tree;
  final String? error;

  /// 子运行（`call`）的 run id。
  final List<String> children;

  /// 运行固定在这一版定义上（B.6）。改写（F19）要靠它取出某个容器的子步骤。
  final String yaml;

  static FlowRunView? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    final status = FlowRunStatus.parse(response['status']);
    final raw = response['tree'];
    if (status == null || raw is! List) return null;
    final rawChildren = response['children'];
    return FlowRunView(
      runId: (response['run_id'] as String?) ?? '',
      status: status,
      tasksUsed: (response['tasks_used'] as num?)?.toInt() ?? 0,
      tree: [
        for (final node in raw)
          if (node is Map) FlowNode.fromJson(Map<String, dynamic>.from(node)),
      ],
      error: (response['error'] as String?)?.isNotEmpty == true
          ? response['error'] as String
          : null,
      children: rawChildren is List
          ? [for (final id in rawChildren) id.toString()]
          : const [],
      yaml: (response['yaml'] as String?) ?? '',
    );
  }

  FlowRunView withNodeStatus(
      String nodeKey, FlowNodeStatus status, int attempt) {
    return FlowRunView(
      runId: runId,
      status: this.status,
      tasksUsed: tasksUsed,
      tree: [
        for (final node in tree)
          node.mapNode(
            nodeKey,
            (n) => n.copyWith(status: status, attempt: attempt),
          ),
      ],
      error: error,
      children: children,
    );
  }

  FlowRunView withRunStatus(FlowRunStatus next) => FlowRunView(
        runId: runId,
        status: next,
        tasksUsed: tasksUsed,
        tree: tree,
        error: error,
        children: children,
        yaml: yaml,
      );
}

/// 流程库里的一项（`flow_list_resp`）。
class FlowSummary {
  const FlowSummary({
    required this.name,
    required this.latest,
    required this.scope,
    this.updatedMs,
  });

  final String name;
  final int latest;
  final String scope;
  final int? updatedMs;

  static List<FlowSummary>? listFromResponse(
    Map<String, dynamic> response, {
    String scope = '',
  }) {
    if (response['success'] != true) return null;
    final raw = response['flows'];
    if (raw is! List) return null;
    return [
      for (final item in raw)
        if (item is Map)
          FlowSummary(
            name: (item['name'] as String?) ?? '',
            latest: (item['latest'] as num?)?.toInt() ?? 0,
            scope: (item['scope'] as String?) ?? scope,
            updatedMs: (item['updated_ms'] as num?)?.toInt(),
          ),
    ];
  }
}

/// 一条运行事件（`flow.run.changed` / `flow.node.changed`）。
class FlowEvent {
  const FlowEvent.run({required this.runId, required this.runStatus})
      : node = null,
        nodeStatus = null,
        attempt = 0;

  const FlowEvent.node({
    required this.runId,
    required String this.node,
    required this.nodeStatus,
    this.attempt = 0,
  }) : runStatus = null;

  final String runId;
  final String? node;
  final FlowNodeStatus? nodeStatus;
  final FlowRunStatus? runStatus;
  final int attempt;

  static FlowEvent? parse(String type, Map<String, dynamic> data) {
    final runId = data['run_id'];
    if (runId is! String || runId.isEmpty) return null;
    if (type == 'flow.run.changed') {
      final status = FlowRunStatus.parse(data['status']);
      return status == null
          ? null
          : FlowEvent.run(runId: runId, runStatus: status);
    }
    if (type == 'flow.node.changed') {
      final node = data['node'];
      final status = FlowNodeStatus.parse(data['status']);
      if (node is! String || status == null) return null;
      return FlowEvent.node(
        runId: runId,
        node: node,
        nodeStatus: status,
        attempt: (data['attempt'] as num?)?.toInt() ?? 0,
      );
    }
    return null;
  }
}

/// 差异里的一条字段变化。
class FlowFieldChange {
  const FlowFieldChange({required this.field, this.from, this.to});

  final String field;
  final Object? from;
  final Object? to;
}

enum FlowChange { added, removed, changed }

class FlowNodeDiff {
  const FlowNodeDiff({
    required this.id,
    required this.kind,
    required this.change,
    this.fields = const [],
  });

  final String id;
  final String kind;
  final FlowChange change;
  final List<FlowFieldChange> fields;
}

/// `flow_diff_resp`：按节点 id 对齐的差异。
class FlowDiff {
  const FlowDiff({required this.nodes, required this.header});

  final List<FlowNodeDiff> nodes;
  final List<FlowFieldChange> header;

  bool get isEmpty => nodes.isEmpty && header.isEmpty;

  FlowNodeDiff? of(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  List<FlowNodeDiff> get removed => [
        for (final n in nodes)
          if (n.change == FlowChange.removed) n
      ];

  static List<FlowFieldChange> _fields(Object? raw) => raw is List
      ? [
          for (final item in raw)
            if (item is Map)
              FlowFieldChange(
                field: (item['field'] as String?) ?? '',
                from: item['from'],
                to: item['to'],
              ),
        ]
      : const [];

  static FlowDiff? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    final raw = response['nodes'];
    if (raw is! List) return null;
    FlowChange? change(Object? v) {
      for (final c in FlowChange.values) {
        if (c.name == v) return c;
      }
      return null;
    }

    final nodes = <FlowNodeDiff>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final kind = change(item['change']);
      if (kind == null) continue;
      nodes.add(FlowNodeDiff(
        id: (item['id'] as String?) ?? '',
        kind: (item['kind'] as String?) ?? '',
        change: kind,
        fields: _fields(item['fields']),
      ));
    }
    return FlowDiff(nodes: nodes, header: _fields(response['header']));
  }
}

/// 检查器里的一个字段（`flow_schema_resp`）。
class FlowSchemaField {
  const FlowSchemaField({
    required this.name,
    required this.type,
    required this.label,
    this.options = const [],
  });

  final String name;

  /// `string` / `text` / `int` / `enum`。
  final String type;
  final String label;
  final List<String> options;

  factory FlowSchemaField.fromJson(Map<String, dynamic> json) =>
      FlowSchemaField(
        name: (json['name'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'string',
        label: (json['label'] as String?) ?? (json['name'] as String? ?? ''),
        options: json['options'] is List
            ? [for (final o in json['options'] as List) o.toString()]
            : const [],
      );
}

class FlowSchema {
  const FlowSchema({
    required this.common,
    required this.kinds,
    this.ops = const [],
  });

  final List<FlowSchemaField> common;
  final Map<String, List<FlowSchemaField>> kinds;

  /// 主机认哪些操作。空表示这台主机没说（旧主机），按「什么都不支持」处理。
  final List<String> ops;

  bool hasOp(String name) => ops.contains(name);

  List<FlowSchemaField> fieldsFor(String kind) => [...common, ...?kinds[kind]];

  static FlowSchema? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    List<FlowSchemaField> parse(Object? raw) => raw is List
        ? [
            for (final item in raw)
              if (item is Map)
                FlowSchemaField.fromJson(Map<String, dynamic>.from(item)),
          ]
        : const [];
    final kinds = <String, List<FlowSchemaField>>{};
    final rawKinds = response['kinds'];
    if (rawKinds is Map) {
      for (final entry in rawKinds.entries) {
        kinds[entry.key.toString()] = parse(entry.value);
      }
    }
    return FlowSchema(
      common: parse(response['common']),
      kinds: kinds,
      ops: [
        // 新 App 会连到旧主机：旧主机的 schema 里没有 `ops`，也就没有
        // `header` / `retype`。能力探测全靠它，不能假设操作一定在。
        for (final item in response['ops'] is List ? response['ops'] as List : const [])
          if (item is String) item,
      ],
    );
  }
}

/// 演练卡住的地方（C.5）：关卡给人选，判断给"是 / 否"。
class FlowQuestion {
  const FlowQuestion({
    required this.kind,
    required this.key,
    required this.options,
    this.ask = '',
    this.show = '',
    this.question = '',
    this.who = '',
  });

  /// `gate` 或 `judge`。
  final String kind;
  final String key;
  final List<String> options;

  /// 关卡：给人看的那句话 / 要判断的那句话。
  final String ask;
  final String show;

  /// 判断（`judge`）：问的是这句；`ask` 为空时用它做标题。
  final String question;
  final String who;

  /// 摆在按钮上面那句话。
  String get prompt => ask.isNotEmpty ? ask : question;

  bool get isGate => kind == 'gate';

  static FlowQuestion? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final key = json['key'];
    if (kind is! String || key is! String) return null;
    final rawOptions = json['options'];
    return FlowQuestion(
      kind: kind,
      key: key,
      options: rawOptions is List
          ? [for (final o in rawOptions) o.toString()]
          : const [],
      ask: (json['ask'] as String?) ?? '',
      show: (json['show'] as String?) ?? '',
      question: (json['question'] as String?) ?? '',
      who: (json['who'] as String?) ?? '',
    );
  }
}

/// 演练结果：派活顺序（节点 key）和走完后的节点树。
class FlowRehearsal {
  const FlowRehearsal({
    required this.steps,
    required this.tree,
    required this.status,
    this.error,
    this.rehearsalId = '',
    this.question,
  });

  final List<String> steps;
  final List<FlowNode> tree;
  final FlowRunStatus status;
  final String? error;

  /// 主机上这一次的 id；卡住时作答要用。
  final String rehearsalId;

  /// 卡住的问题；为空表示这一段走完了。
  final FlowQuestion? question;

  bool get isWaiting => question != null;

  static FlowRehearsal? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    final status = FlowRunStatus.parse(response['status']);
    final steps = response['steps'];
    final tree = response['tree'];
    if (status == null || steps is! List || tree is! List) return null;
    final rawQuestion = response['question'];
    return FlowRehearsal(
      steps: [
        for (final s in steps)
          if (s is Map && s['key'] is String) s['key'] as String,
      ],
      tree: [
        for (final n in tree)
          if (n is Map) FlowNode.fromJson(Map<String, dynamic>.from(n)),
      ],
      status: status,
      error: (response['error'] as String?)?.isNotEmpty == true
          ? response['error'] as String
          : null,
      rehearsalId: (response['rehearsal_id'] as String?) ?? '',
      question: rawQuestion is Map
          ? FlowQuestion.fromJson(Map<String, dynamic>.from(rawQuestion))
          : null,
    );
  }
}

/// 点分路径取值：`task.prompt` → fields['task']['prompt']。
Object? flowFieldValue(Map<String, dynamic>? fields, String path) {
  Object? cursor = fields;
  for (final part in path.split('.')) {
    if (cursor is Map && cursor.containsKey(part)) {
      cursor = cursor[part];
    } else {
      return null;
    }
  }
  return cursor;
}

/// 节点的父节点（根层返回 null，用 [isRoot] 区分「没找到」）。
({FlowNode? parent, int index})? flowLocate(List<FlowNode> tree, String id,
    {FlowNode? parent}) {
  for (var i = 0; i < tree.length; i++) {
    if (tree[i].id == id) return (parent: parent, index: i);
    final hit = flowLocate(tree[i].children, id, parent: tree[i]);
    if (hit != null) return hit;
  }
  return null;
}
