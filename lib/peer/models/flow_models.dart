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
  cancelled,

  /// P6：群外节点的 `ask_user` 卡片转 deferred，节点在等用户回答。
  /// 主机 `NodeStatus::WaitingUser` 序列化成 `waiting_user`。
  waitingUser;

  static FlowNodeStatus? parse(Object? raw) {
    if (raw is! String) return null;
    // 主机若把「等用户回答」下发成别的写法，也统一归到 waitingUser。
    // 不认的写法一律返回 null：宁可这一格没有状态，也不要抛异常把整棵
    // 运行树解析崩掉（FlowRunView.fromResponse / FlowEvent.parse 都会跳过）。
    switch (raw) {
      case 'waiting_user':
      case 'waiting':
      case 'needs_user':
        return FlowNodeStatus.waitingUser;
    }
    for (final value in FlowNodeStatus.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  /// 这一态是不是「等用户拍板」。`halted` 是旧的关卡等待态，也按等人处理；
  /// P6 的「去回答」入口和卡片红点按它显示。
  bool get isWaitingForUser =>
      this == FlowNodeStatus.waitingUser || this == FlowNodeStatus.halted;

  bool get isTerminal => switch (this) {
        FlowNodeStatus.pending ||
        FlowNodeStatus.running ||
        FlowNodeStatus.waitingUser =>
          false,
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
    // P6：主机若把「等用户回答」上升成 run 级状态，运行其实还没结束。
    // 按 running 处理，别让整屏被判成「读不到这次运行」。
    switch (raw) {
      case 'waiting_user':
      case 'waiting':
      case 'needs_user':
      case 'halted':
        return FlowRunStatus.running;
    }
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
    this.sessionId,
    this.agentId,
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

  /// 引擎槽位 key（旧字段，`flow:<rid>:<node>`）。主机为兼容仍在下发，
  /// 但它不是会话库里的私聊会话，不能用它拼频道 id。
  final String? session;

  /// 主机会话库里的真会话 id（`flow_<rid8>_<node>`，无冒号）。有它就能按
  /// `psess_<sessionId>` 打开普通私聊，看历史、继续聊、停止。
  final String? sessionId;

  /// Hub 侧的 agent id。用来在本地会话里定位对应的 agent 行。
  final String? agentId;

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

  /// 有没有可以点进去的私聊会话。
  bool get hasSession => sessionId != null && sessionId!.isNotEmpty;

  /// 关卡正在等人回答。带节点会话且正在跑的执行节点也算：P6 的询问卡片会落在
  /// 这条会话里，卡片上要能提示「等人回答」。等用户回答的节点态（waitingUser /
  /// halted）同样要露出「去回答」入口。
  bool get awaitsAnswer =>
      (status == FlowNodeStatus.running && (kind == 'gate' || hasSession)) ||
      (status != null && status!.isWaitingForUser);

  FlowNode copyWith({
    FlowNodeStatus? status,
    int? attempt,
    List<FlowNode>? children,
    String? sessionId,
    String? agentId,
  }) =>
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
        sessionId: sessionId ?? this.sessionId,
        agentId: agentId ?? this.agentId,
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
      sessionId: asText(json['session_id']),
      agentId: asText(json['agent_id']),
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
      session: session,
      sessionId: sessionId,
      agentId: agentId,
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

/// 主机目前不在 `flow_run_get_resp` 里下发 run 级惜宝会话 id，但每个节点
/// 会话都是 `flow_<rid8>_<...>`（群内可能再带 `group:...:` 前缀）。前缀里的
/// `<rid8>` 就是这次运行的 tag，由此拼出 P6 的运行会话 `flow_<rid8>_she`。
/// 找不到带会话的节点时返回 null —— 没跑过任何节点，卡片也还没到，没处可点。
final RegExp _flowRunTag = RegExp(r'flow_([A-Za-z0-9]+)_');

String? flowRunSheSessionId(Iterable<FlowNode> tree) {
  for (final root in tree) {
    final hit = root.find((node) {
      final id = node.sessionId;
      return id != null && _flowRunTag.hasMatch(id);
    });
    final id = hit?.sessionId;
    if (id == null) continue;
    final match = _flowRunTag.firstMatch(id);
    if (match != null) return 'flow_${match.group(1)}_she';
  }
  return null;
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
    this.runSessionId,
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

  /// P6：这次运行的惜宝会话 id（`flow_<rid8>_she`，裸主机会话 id）。
  /// 主机若开始下发 run 级字段就直接用；否则从节点会话前缀推出来。
  /// 顶部「运行会话」入口打开 `psess_<runSessionId>`。
  final String? runSessionId;

  static FlowRunView? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    final status = FlowRunStatus.parse(response['status']);
    final raw = response['tree'];
    if (status == null || raw is! List) return null;
    final rawChildren = response['children'];
    final tree = [
      for (final node in raw)
        if (node is Map) FlowNode.fromJson(Map<String, dynamic>.from(node)),
    ];
    // 群运行的流程层面问题走群聊，主机不建 run 级惜宝会话。主机在
    // flow_run_get_resp 里下发 group_id / she_session_id：有 group_id 就收起入口，
    // 否则直接用下发的 she_session_id（节点还没跑过时也能打开）。
    final groupId = response['group_id'];
    final isGroupRun = (groupId is String && groupId.isNotEmpty) ||
        response['scene'] == 'group';
    String? runSessionId;
    if (!isGroupRun) {
      for (final key in const [
        'she_session_id',
        'run_session_id',
        'session_id',
      ]) {
        final value = response[key];
        if (value is String && value.isNotEmpty) {
          runSessionId = value;
          break;
        }
      }
      runSessionId ??= flowRunSheSessionId(tree);
    }
    return FlowRunView(
      runId: (response['run_id'] as String?) ?? '',
      status: status,
      tasksUsed: (response['tasks_used'] as num?)?.toInt() ?? 0,
      tree: tree,
      error: (response['error'] as String?)?.isNotEmpty == true
          ? response['error'] as String
          : null,
      children: rawChildren is List
          ? [for (final id in rawChildren) id.toString()]
          : const [],
      yaml: (response['yaml'] as String?) ?? '',
      runSessionId: runSessionId,
    );
  }

  FlowRunView withNodeStatus(
    String nodeKey,
    FlowNodeStatus status,
    int attempt, {
    String? sessionId,
  }) {
    return FlowRunView(
      runId: runId,
      status: this.status,
      tasksUsed: tasksUsed,
      tree: [
        for (final node in tree)
          node.mapNode(
            nodeKey,
            (n) => n.copyWith(
              status: status,
              attempt: attempt,
              sessionId: sessionId,
            ),
          ),
      ],
      error: error,
      children: children,
      yaml: yaml,
      runSessionId: runSessionId,
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
        runSessionId: runSessionId,
      );
}

/// 流程库里的一项（`flow_list_resp`）。
class FlowSummary {
  const FlowSummary({
    required this.name,
    required this.latest,
    required this.scope,
    this.updatedMs,
    this.updatedBy,
    this.description,
  });

  final String name;
  final int latest;
  final String scope;
  final int? updatedMs;

  /// 谁最后改的。内置模板由主机 seed 时写 `"hub"`；不是 hub 就说明用户改过。
  final String? updatedBy;
  final String? description;

  bool get isUserEdited =>
      updatedBy != null && updatedBy!.isNotEmpty && updatedBy != 'hub';

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
            updatedBy: item['updated_by'] as String?,
            description: item['description'] as String?,
          ),
    ];
  }
}

/// 一条运行事件（`flow.run.changed` / `flow.node.changed`）。
class FlowEvent {
  const FlowEvent.run({required this.runId, required this.runStatus})
      : node = null,
        nodeStatus = null,
        attempt = 0,
        sessionId = null;

  const FlowEvent.node({
    required this.runId,
    required String this.node,
    required this.nodeStatus,
    this.attempt = 0,
    this.sessionId,
  }) : runStatus = null;

  final String runId;
  final String? node;
  final FlowNodeStatus? nodeStatus;
  final FlowRunStatus? runStatus;
  final int attempt;

  /// `flow.node.changed` 上新下发的真会话 id；有它不用等重拉就能放入口。
  final String? sessionId;

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
        sessionId: data['session_id'] is String &&
                (data['session_id'] as String).isNotEmpty
            ? data['session_id'] as String
            : null,
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

/// 运行列表里的一项（M8' 的 `flow_run_list_resp`）。
class FlowRunSummary {
  const FlowRunSummary({
    required this.runId,
    required this.flow,
    required this.status,
    this.scope = '',
    this.revision,
    this.groupId,
    this.startedMs = 0,
    this.tasksUsed = 0,
  });

  final String runId;
  final String flow;
  final String status;
  final String scope;
  final int? revision;
  final String? groupId;
  final int startedMs;
  final int tasksUsed;

  bool get isRunning => status == 'running';

  static List<FlowRunSummary> listFromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return const [];
    final runs = response['runs'];
    if (runs is! List) return const [];
    return [
      for (final item in runs)
        if (item is Map)
          FlowRunSummary(
            runId: (item['run_id'] as String?) ?? '',
            flow: (item['flow'] as String?) ?? '',
            status: (item['status'] as String?) ?? '',
            scope: (item['scope'] as String?) ?? '',
            revision: (item['revision'] as num?)?.toInt(),
            groupId: item['group_id'] as String?,
            startedMs: (item['started_ms'] as num?)?.toInt() ?? 0,
            tasksUsed: (item['tasks_used'] as num?)?.toInt() ?? 0,
          ),
    ];
  }
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
        for (final item
            in response['ops'] is List ? response['ops'] as List : const [])
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
/// 同时带回节点本身，调用方不必再写一份树遍历。
({FlowNode node, FlowNode? parent, int index, String? branch})? flowLocate(
    List<FlowNode> tree, String id,
    {FlowNode? parent}) {
  // 父节点是 `if` 时，下标按分支内相对位置算：`then` / `else` 在 children 里
  // 是拼在一起的，直接用拼起来的下标会把节点派到错的分支。
  if (parent?.kind == 'if') {
    var then = 0;
    var els = 0;
    for (final node in tree) {
      final branch = node.branch ?? 'then';
      final index = branch == 'else' ? els++ : then++;
      if (node.id == id) {
        return (node: node, parent: parent, index: index, branch: branch);
      }
      // 分支里还可能套着 seq / loop 之类的容器。别因为直接父节点是 `if` 就
      // 截断递归：运行视图的「改写」要靠它找到嵌套在分支内部的节点的父节点。
      final hit = flowLocate(node.children, id, parent: node);
      if (hit != null) return hit;
    }
    return null;
  }
  for (var i = 0; i < tree.length; i++) {
    if (tree[i].id == id) {
      return (node: tree[i], parent: parent, index: i, branch: null);
    }
    final hit = flowLocate(tree[i].children, id, parent: tree[i]);
    if (hit != null) return hit;
  }
  return null;
}
