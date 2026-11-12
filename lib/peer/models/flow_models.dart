/// 工作流在 App 侧的数据（方案 C.2 / B.8）。App 不解析 YAML：节点树由 Hub 的
/// `flow_validate_resp` / `flow_run_get_resp` 给出，这里只做解码。
library;

import '../../storage/pouch_scope.dart';

/// 工作流会话 id 的格式守卫：只有主机下发的 `flow_<...>` 真会话能拼出
/// `psess_` 频道。旧运行 / 群运行的条目可能是引擎槽位 key
/// （`flow:<rid>:<node>` / `group:<gid>:<sid>:...`）、参与条目（`part-flow-…`）
/// 或已经带壳的 `psess_flow_…`，点进去只会得到一条永远没有消息的假会话。
///
/// 服务层的 `flowFoldedSessionId` 和节点的 [FlowNode.hasSession] 都复用这一份，
/// 免得两处守卫漂移（A10-7）。
String? usableFlowSessionId(String? raw) {
  final id = raw?.trim() ?? '';
  if (id.isEmpty || id.contains(':') || id.contains('/')) return null;
  if (id.startsWith('psess_')) return null;
  if (id.startsWith('part-')) return null;
  if (!id.startsWith('flow_')) return null;
  return id;
}

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

  /// 这一态是不是「等用户拍板」。只有真正有 ask_user 卡片的 [waitingUser]
  /// 才算：主机 `Halted` 是终态失败（`[NEED_ADMIN]` / blocked），v1 没有自动
  /// 卡片，给它红点 +「去回答」只会把用户带到一张旧卡上（A7-6）。
  bool get isWaitingForUser => this == FlowNodeStatus.waitingUser;

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
        return FlowRunStatus.running;
      // A10-9：节点级 Halted 是终态失败（[FlowNodeStatus.isTerminal]）。
      // run 级也按失败收尾，否则运行页一直转圈、不显示失败。
      case 'halted':
        return FlowRunStatus.failed;
    }
    for (final value in FlowRunStatus.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  bool get isFinished => this != FlowRunStatus.running;
}

/// 循环的一轮。`iter` 从 0 开始，和节点键上的 `#N` 一致。
class FlowIteration {
  const FlowIteration({
    required this.iter,
    this.status,
    this.children = const [],
  });

  final int iter;
  final FlowNodeStatus? status;
  final List<FlowNode> children;

  FlowIteration copyWith({List<FlowNode>? children}) => FlowIteration(
        iter: iter,
        status: status,
        children: children ?? this.children,
      );

  factory FlowIteration.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'];
    return FlowIteration(
      iter: json['iter'] is num ? (json['iter'] as num).toInt() : 0,
      status: FlowNodeStatus.parse(json['status']),
      children: rawChildren is List
          ? [
              for (final child in rawChildren)
                if (child is Map)
                  FlowNode.fromJson(Map<String, dynamic>.from(child)),
            ]
          : const [],
    );
  }
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
    this.iterations = const [],
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

  /// `loop` 已经跑过的每一轮。树上的 [children] 仍是最后一轮；
  /// 点开循环时用这个把前面每一轮的结果折开展示。旧主机不下发，就是空。
  final List<FlowIteration> iterations;

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

  /// 有没有可以点进去的真会话。非空不等于可用：旧运行的引擎槽位 key 会
  /// 被 `flowFoldedSessionId` 拒绝，显示按钮只会点了没反应（A10-7）。
  bool get hasSession => usableFlowSessionId(sessionId) != null;

  /// 关卡正在等人回答。带节点会话且正在跑的执行节点也算：P6 的询问卡片会落在
  /// 这条会话里，卡片上要能提示「等人回答」。真正有卡片的 [waitingUser] 同样
  /// 要露出「去回答」入口；halted 是终态失败，不在其中（A7-6）。
  bool get awaitsAnswer =>
      (status == FlowNodeStatus.running && (kind == 'gate' || hasSession)) ||
      (status != null && status!.isWaitingForUser);

  FlowNode copyWith({
    FlowNodeStatus? status,
    int? attempt,
    List<FlowNode>? children,
    List<FlowIteration>? iterations,
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
        iterations: iterations ?? this.iterations,
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
    final rawIterations = json['iterations'];
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
      iterations: rawIterations is List
          ? [
              for (final item in rawIterations)
                if (item is Map)
                  FlowIteration.fromJson(Map<String, dynamic>.from(item)),
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
  ///
  /// 循环的历史轮次不在 [children] 里，也要跟着改，否则侧边栏里的旧轮次
  /// 会停在打开那一刻的状态。
  FlowNode mapNode(String targetKey, FlowNode Function(FlowNode) change) {
    final self = key == targetKey ? change(this) : this;
    if (self.children.isEmpty && self.iterations.isEmpty) return self;
    var touched = !identical(self, this);
    final next = [
      for (final child in self.children)
        () {
          final updated = child.mapNode(targetKey, change);
          if (!identical(updated, child)) touched = true;
          return updated;
        }(),
    ];
    final nextIterations = [
      for (final round in self.iterations)
        () {
          var roundTouched = false;
          final kids = [
            for (final child in round.children)
              () {
                final updated = child.mapNode(targetKey, change);
                if (!identical(updated, child)) roundTouched = true;
                return updated;
              }(),
          ];
          if (!roundTouched) return round;
          touched = true;
          return round.copyWith(children: kids);
        }(),
    ];
    if (!touched) return this;
    return self.copyWith(children: next, iterations: nextIterations);
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
      iterations: iterations,
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
/// 会话都是 `flow_<tag>_<...>`（群内可能再带 `group:...:` 前缀）。前缀里的
/// tag 是这次运行的十六进制短指纹：老主机 8 位，H6-10 之后是 16 位，
/// 两种都要能推出 P6 的运行会话 `flow_<tag>_she`。
/// 找不到带会话的节点时返回 null —— 没跑过任何节点，卡片也还没到，没处可点。
/// App 侧不写死 tag 长度（8 位老主机 / 16 位 H6-10 都认）：只要能抓到
/// `flow_<tag>_` 这一段就能拼出运行会话，避免主机换形状后入口消失。
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
    this.startedMs,
    this.flowId,
    this.instanceId,
    this.instanceScope,
    this.runScope,
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

  /// 主机若下发 `started_ms`，状态条显示已用时；旧主机没有就不显示。
  final int? startedMs;

  /// 三层分区坐标（M4）。旧主机的 `flow_run_get_resp` 不带这些字段，全为 null。
  /// 有 `flow_id` + `instance_id` 时 [instanceScope] 会补出实例 scope。
  final String? flowId;
  final String? instanceId;
  final String? instanceScope;
  final String? runScope;

  /// 未来「再跑一次」按钮把这个 id 传回 [HubFlow.start]，复用同一业务实例。
  /// 运行页状态按「start 响应 → run 快照」的优先级保留它。
  String? get rerunInstanceId => instanceId;

  static String? _stringField(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static Map<String, dynamic> _hostMeta(Map<String, dynamic> response) {
    final ctx = response['ctx'];
    final host = ctx is Map ? ctx['host'] : null;
    final raw = response['host_meta'] ?? host;
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  // 老的两段式 `run:<rid>` 不在三层树里，主机产物帧桥会拒；只认 flow 家族
  // 且带 `:run:` 的 scope，并且必须能被解析器接受。
  static bool _isRunScope(String value) =>
      value.startsWith('flow:') &&
      value.contains(':run:') &&
      PouchScope.tryParse(value) != null;

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
    // 三层坐标可能来自 run 帧顶层，也可能随 run.json 的 ctx.host 投影回来。
    // 旧主机没有这些字段，instanceScope / runScope 就留 null，UI 退回空产物卡。
    final hostMeta = _hostMeta(response);
    final flowId = _stringField(response, ['flow_id']) ??
        _stringField(hostMeta, ['flow_id']);
    final instanceId = _stringField(response, ['instance_id']) ??
        _stringField(hostMeta, ['instance_id']);
    final instanceScope =
        _stringField(response, ['instance_scope', 'instance_pouch_scope']) ??
            _stringField(hostMeta, ['instance_scope']) ??
            (flowId != null && instanceId != null
                ? 'flow:$flowId:instance:$instanceId'
                : null);
    var runScope = _stringField(response, ['run_scope', 'run_pouch_scope']) ??
        _stringField(hostMeta, ['run_scope', 'pouch_scope']);
    // 主机给的字符串也可能是拼出来的畸形 scope（老 run_id 带连字符），
    // 解析器拒就丢掉，退回下面的 buildFlowRunScope / 等下一次真值。
    if (runScope != null && PouchScope.tryParse(runScope) == null) {
      runScope = null;
    }
    final genericScope =
        _stringField(response, ['scope']) ?? _stringField(hostMeta, ['scope']);
    if (genericScope != null && _isRunScope(genericScope)) {
      runScope ??= genericScope;
    }
    if (runScope == null && instanceScope != null) {
      final id = (response['run_id'] as String?) ?? '';
      if (id.isNotEmpty) {
        runScope = PouchScope.buildFlowRunScope(instanceScope, id);
      }
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
      startedMs: (response['started_ms'] as num?)?.toInt(),
      flowId: flowId,
      instanceId: instanceId,
      instanceScope: instanceScope,
      runScope: runScope,
    );
  }

  FlowRunView withNodeStatus(
    String nodeKey,
    FlowNodeStatus status,
    int attempt, {
    String? sessionId,
    String? agentId,
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
              agentId: agentId,
            ),
          ),
      ],
      error: error,
      children: children,
      yaml: yaml,
      runSessionId: runSessionId,
      startedMs: startedMs,
      flowId: flowId,
      instanceId: instanceId,
      instanceScope: instanceScope,
      runScope: runScope,
    );
  }

  /// 运行级状态变了。事件帧只带状态，不带 `error`；主机在非终态也会写
  /// `run.error`（预算告警 / `on_error: continue`），若这里原样保留，看门狗
  /// 取消后的 400ms 重拉窗口里，旧告警会冒充「取消原因」显示在原因卡上。
  /// 切到终态时先清掉本地旧值，由紧接着的 `_load()` 回填主机真值。
  FlowRunView withRunStatus(FlowRunStatus next) => FlowRunView(
        runId: runId,
        status: next,
        tasksUsed: tasksUsed,
        tree: tree,
        error: next == FlowRunStatus.running ? error : null,
        children: children,
        yaml: yaml,
        runSessionId: runSessionId,
        startedMs: startedMs,
        flowId: flowId,
        instanceId: instanceId,
        instanceScope: instanceScope,
        runScope: runScope,
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
    this.lastRunStatus,
    this.lastRunMs,
    this.lastRunId,
    this.lastRunNeedsApproval = false,
  });

  final String name;
  final int latest;
  final String scope;
  final int? updatedMs;

  /// 谁最后改的。内置模板由主机 seed 时写 `"hub"`；不是 hub 就说明用户改过。
  final String? updatedBy;
  final String? description;

  /// 新版主机在 `flow_list_resp` 里附带的最近一次运行状态。旧主机没有这些
  /// 字段，一律是 null —— 列表行据此回退到「只有 rev + 说明」，不报错也不
  /// 额外发请求。状态串沿用运行快照里的写法（`running` / `failed` /
  /// `waiting_user` …），App 只认得这几种，认不出的就不画状态点。
  final String? lastRunStatus;
  final int? lastRunMs;
  final String? lastRunId;

  /// 最近一次运行里有节点在等人回答。旧主机没这个字段，默认 false。
  final bool lastRunNeedsApproval;

  bool get isUserEdited =>
      updatedBy != null && updatedBy!.isNotEmpty && updatedBy != 'hub';

  /// 列表行右侧的状态标识。和运行状态用同一套判定，别让两处漂移。
  FlowSummaryStatus get status => FlowSummaryStatus.of(lastRunStatus);

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
            lastRunStatus: item['last_run_status'] as String?,
            lastRunMs: (item['last_run_ms'] as num?)?.toInt(),
            lastRunId: item['last_run_id'] as String?,
            lastRunNeedsApproval: item['last_run_needs_approval'] == true,
          ),
    ];
  }
}

/// 流程列表行的状态点。旧主机没给 `last_run_status` 时一律 [none]，
/// 页面不显示任何状态标识（信息回退，但功能完整）。
enum FlowSummaryStatus {
  none,
  running,
  failed,
  needsApproval;

  static FlowSummaryStatus of(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return switch (value) {
      'running' || 'in_progress' => FlowSummaryStatus.running,
      'failed' || 'error' || 'halted' => FlowSummaryStatus.failed,
      'waiting_user' ||
      'waiting' ||
      'needs_user' ||
      'needs_approval' ||
      'pending_approval' =>
        FlowSummaryStatus.needsApproval,
      _ => FlowSummaryStatus.none,
    };
  }
}

/// 一条运行事件（`flow.run.changed` / `flow.node.changed`）。
class FlowEvent {
  const FlowEvent.run({required this.runId, required this.runStatus})
      : node = null,
        nodeStatus = null,
        attempt = 0,
        sessionId = null,
        agentId = null;

  const FlowEvent.node({
    required this.runId,
    required String this.node,
    required this.nodeStatus,
    this.attempt = 0,
    this.sessionId,
    this.agentId,
  }) : runStatus = null;

  final String runId;
  final String? node;
  final FlowNodeStatus? nodeStatus;
  final FlowRunStatus? runStatus;
  final int attempt;

  /// `flow.node.changed` 上新下发的真会话 id；有它不用等重拉就能放入口。
  final String? sessionId;

  /// 同帧的执行 agent。`flow_run_get_resp` 重拉要 400ms 之后才到，这之前点
  /// 「查看会话」若没有 agentId 会建出一条没有成员的空壳频道。
  /// 主机旧帧里这个字段叫 `agent`，两种都认；缺失时沿用树上已有的值。
  final String? agentId;

  static String? _nonEmptyText(Map<String, dynamic> data, String key) {
    final value = data[key];
    return value is String && value.isNotEmpty ? value : null;
  }

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
        sessionId: _nonEmptyText(data, 'session_id'),
        agentId:
            _nonEmptyText(data, 'agent_id') ?? _nonEmptyText(data, 'agent'),
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
    this.inputTitle = '',
  });

  final String runId;
  final String flow;
  final String status;
  final String scope;
  final int? revision;
  final String? groupId;
  final int startedMs;
  final int tasksUsed;

  /// 用户开跑时填的那句话（`flow_run_list_resp.input_title`）。
  /// 主机从 `inputs.title` / `goal` / `task` 里取，没有就用第一个非空字符串。
  /// 旧主机不带这个字段，这里就是空串。
  final String inputTitle;

  bool get isRunning => status == 'running';

  /// 运行列表分组：要人拍板的排最前，其次运行中的，最后已结束的。
  ///
  /// 主机 run 级状态只有 running/succeeded/failed/cancelled，`waiting_user`
  /// 是节点状态；这里仍然认这几种写法，兼容把它上升成 run 级状态的新主机。
  FlowRunGroup get group {
    final value = status.toLowerCase();
    if (const {
      'waiting_user',
      'waiting',
      'needs_user',
      'needs_approval',
      'blocked',
      'halted',
    }.contains(value)) {
      return FlowRunGroup.attention;
    }
    return isRunning ? FlowRunGroup.running : FlowRunGroup.finished;
  }

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
            inputTitle: (item['input_title'] as String?)?.trim() ?? '',
          ),
    ];
  }
}

/// 运行列表的分组顺序（[FlowRunSummary.group]）。
enum FlowRunGroup { attention, running, finished }

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

// ── M4 工作流产物 ──────────────────────────────────────────────────────────
// 主机 `pouch.artifact_list/get` 的解码。旧主机没有这两个命令、响应缺字段或
// 夹了未知类型，都只退化成空列表 / 空版本，不让运行页抛异常。

Map<String, dynamic> _artifactMap(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};

Object? _artifactField(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value != null) return value;
  }
  return null;
}

String _artifactText(Map<String, dynamic> json, List<String> keys) {
  final value = _artifactField(json, keys);
  if (value is String) return value.trim();
  return value == null ? '' : value.toString().trim();
}

int _artifactInt(Map<String, dynamic> json, List<String> keys) {
  final value = _artifactField(json, keys);
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

Map<String, dynamic> _artifactPayload(Map<String, dynamic>? response) {
  if (response == null) return const <String, dynamic>{};
  for (final key in const ['data', 'result']) {
    final nested = _artifactMap(response[key]);
    if (nested['artifacts'] is List ||
        nested['artifact'] is Map ||
        nested.containsKey('artifact_id')) {
      return nested;
    }
  }
  return response;
}

bool _artifactFailed(Map<String, dynamic> json) =>
    json['success'] == false || json['ok'] == false;

String _artifactVersionUri({
  required String pouchId,
  required String scope,
  required String artifactId,
  required int version,
  required String filename,
  required String path,
}) {
  if (pouchId.isEmpty || scope.isEmpty) return '';
  final relative = path.isNotEmpty
      ? path.replaceAll(RegExp(r'^/+|/+$'), '')
      : 'artifacts/${Uri.encodeComponent(artifactId)}/v$version/'
          '${Uri.encodeComponent(filename)}';
  return 'pouch://$pouchId/$scope/$relative';
}

/// 产物的一版。URI 是主机给的 `pouch://` 地址；旧响应只有 path 时按三层
/// 目录约定补一个地址，仍打不开就不给点击。
class FlowArtifactVersion {
  const FlowArtifactVersion({
    required this.version,
    required this.filename,
    this.scope = '',
    this.path = '',
    this.hash = '',
    this.size = 0,
    this.createdMs = 0,
    this.uri = '',
    this.note = '',
  });

  final int version;
  final String filename;
  final String scope;
  final String path;
  final String hash;
  final int size;
  final int createdMs;
  final String uri;
  final String note;

  factory FlowArtifactVersion.fromJson(
    Map<String, dynamic> json, {
    String fallbackUri = '',
  }) {
    final path = _artifactText(json, ['path']);
    var filename = _artifactText(json, ['filename', 'name']);
    if (filename.isEmpty && path.isNotEmpty) {
      filename = path.split('/').last;
    }
    final explicitUri = _artifactText(json, ['uri', 'pouch_uri']);
    return FlowArtifactVersion(
      version: _artifactInt(json, ['version']),
      filename: filename,
      scope: _artifactText(json, ['scope']),
      path: path,
      hash: _artifactText(json, ['hash', 'sha256']),
      size: _artifactInt(json, ['size']),
      createdMs: _artifactInt(json, ['created_ms', 'createdMs']),
      uri: explicitUri.isNotEmpty ? explicitUri : fallbackUri,
      note: _artifactText(json, ['note']),
    );
  }
}

/// 一个 `artifact_id` 及它的版本列表。列表响应的重复 id（例如 run / instance
/// 两边都查到同一产物）由 [groupByArtifactId] 合并。
class FlowArtifact {
  const FlowArtifact({
    required this.artifactId,
    this.title = '',
    this.kind = '',
    this.latestVersion = 0,
    this.scope = '',
    this.pouchId = '',
    this.versions = const <FlowArtifactVersion>[],
  });

  final String artifactId;
  final String title;
  final String kind;
  final int latestVersion;
  final String scope;
  final String pouchId;
  final List<FlowArtifactVersion> versions;

  factory FlowArtifact.fromJson(Map<String, dynamic> json) {
    final artifactId = _artifactText(json, ['artifact_id', 'artifactId', 'id']);
    final scope = _artifactText(json, ['scope', 'origin_scope']);
    final pouchId = _artifactText(json, ['pouch_id', 'pouchId']);
    final rawVersions = json['versions'];
    final versions = <FlowArtifactVersion>[];
    if (rawVersions is List) {
      for (final raw in rawVersions) {
        if (raw is! Map) continue;
        final version = _artifactMap(raw);
        final number = _artifactInt(version, ['version']);
        if (number <= 0) continue;
        final filename = _artifactText(version, ['filename', 'name']);
        final versionScope = _artifactText(version, ['scope']);
        final path = _artifactText(version, ['path']);
        versions.add(FlowArtifactVersion.fromJson(
          version,
          fallbackUri: _artifactVersionUri(
            pouchId: pouchId,
            scope: versionScope.isNotEmpty ? versionScope : scope,
            artifactId: artifactId,
            version: number,
            filename: filename,
            path: path,
          ),
        ));
      }
    }
    var latest = _artifactInt(json, ['latest_version', 'latestVersion']);
    for (final version in versions) {
      if (version.version > latest) latest = version.version;
    }
    return FlowArtifact(
      artifactId: artifactId,
      title: _artifactText(json, ['title']),
      kind: _artifactText(json, ['kind']),
      latestVersion: latest,
      scope: scope,
      pouchId: pouchId,
      versions: versions,
    );
  }

  static FlowArtifact? fromResponse(Map<String, dynamic>? response) {
    if (response == null || _artifactFailed(response)) return null;
    final payload = _artifactPayload(response);
    if (_artifactFailed(payload)) return null;
    final single = payload['artifact'];
    if (single is Map) {
      final artifact = FlowArtifact.fromJson(_artifactMap(single));
      return artifact.artifactId.isEmpty ? null : artifact;
    }
    final list = payload['artifacts'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      final artifact = FlowArtifact.fromJson(_artifactMap(list.first));
      return artifact.artifactId.isEmpty ? null : artifact;
    }
    if (!payload.containsKey('artifact_id')) return null;
    final artifact = FlowArtifact.fromJson(payload);
    return artifact.artifactId.isEmpty ? null : artifact;
  }

  static List<FlowArtifact> listFromResponse(Map<String, dynamic>? response) {
    if (response == null || _artifactFailed(response)) {
      return const <FlowArtifact>[];
    }
    final payload = _artifactPayload(response);
    if (_artifactFailed(payload)) return const <FlowArtifact>[];
    final raw = payload['artifacts'];
    if (raw is! List) return const <FlowArtifact>[];
    return groupByArtifactId([
      for (final item in raw)
        if (item is Map) FlowArtifact.fromJson(_artifactMap(item)),
    ]);
  }

  /// 按 `artifact_id` 合并；版本去重后 v 大的排前面。
  static List<FlowArtifact> groupByArtifactId(
      Iterable<FlowArtifact> artifacts) {
    final merged = <String, FlowArtifact>{};
    final versions = <String, List<FlowArtifactVersion>>{};
    for (final artifact in artifacts) {
      final id = artifact.artifactId;
      if (id.isEmpty) continue;
      final previous = merged[id];
      if (previous == null) {
        merged[id] = artifact;
        versions[id] = List<FlowArtifactVersion>.of(artifact.versions);
        continue;
      }
      merged[id] = FlowArtifact(
        artifactId: id,
        title: previous.title.isNotEmpty ? previous.title : artifact.title,
        kind: previous.kind.isNotEmpty ? previous.kind : artifact.kind,
        latestVersion: previous.latestVersion > artifact.latestVersion
            ? previous.latestVersion
            : artifact.latestVersion,
        scope: previous.scope.isNotEmpty ? previous.scope : artifact.scope,
        pouchId:
            previous.pouchId.isNotEmpty ? previous.pouchId : artifact.pouchId,
      );
      versions[id]!.addAll(artifact.versions);
    }
    return <FlowArtifact>[
      for (final id in merged.keys) _withVersions(merged[id]!, versions[id]!),
    ];
  }

  static FlowArtifact _withVersions(
    FlowArtifact artifact,
    List<FlowArtifactVersion> versions,
  ) {
    final unique = <String, FlowArtifactVersion>{};
    for (final version in versions) {
      final key = '${version.version}|${version.filename}|${version.uri}|'
          '${version.hash}';
      unique.putIfAbsent(key, () => version);
    }
    final sorted = unique.values.toList()
      ..sort((a, b) {
        final byVersion = b.version.compareTo(a.version);
        return byVersion != 0 ? byVersion : a.filename.compareTo(b.filename);
      });
    var latest = artifact.latestVersion;
    for (final version in sorted) {
      if (version.version > latest) latest = version.version;
    }
    return FlowArtifact(
      artifactId: artifact.artifactId,
      title: artifact.title,
      kind: artifact.kind,
      latestVersion: latest,
      scope: artifact.scope,
      pouchId: artifact.pouchId,
      versions: sorted,
    );
  }
}
