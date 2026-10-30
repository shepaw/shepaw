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

  bool get isContainer => children.isNotEmpty;

  /// 关卡正在等人回答。
  bool get awaitsAnswer =>
      kind == 'gate' && status == FlowNodeStatus.running;

  FlowNode copyWith({FlowNodeStatus? status, int? attempt, List<FlowNode>? children}) =>
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
  });

  final String runId;
  final FlowRunStatus status;
  final int tasksUsed;
  final List<FlowNode> tree;
  final String? error;

  /// 子运行（`call`）的 run id。
  final List<String> children;

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
    );
  }

  FlowRunView withNodeStatus(String nodeKey, FlowNodeStatus status, int attempt) {
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
