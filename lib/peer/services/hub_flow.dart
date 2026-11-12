import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_session.dart';
import '../models/flow_models.dart';
import '../models/flow_node_progress.dart';
import 'peer_connection_manager.dart';

/// 工作流帧的收发（方案 B.8 / C.7）。主机是权威：流程库、运行、关卡都在
/// 主机上，App 只发请求、吃 `flow.*` 事件。
///
/// 请求构造函数是纯函数，单测直接比对线上字段（同 [HubGroupSessions]）。
class HubFlow {
  HubFlow({
    this.send,
    Stream<PeerControlEvent>? events,
    this.sendTimeout = const Duration(seconds: 8),
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;

  /// 发送本身的上限。响应另有 10 秒超时；发送卡在废连接的发送锁上时，
  /// 没有这个上限运行页会一直转圈。
  final Duration sendTimeout;
  final _uuid = const Uuid();

  static Map<String, dynamic> listFrame(String scope, {String? requestId}) => {
        'type': 'flow_list_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
      };

  static Map<String, dynamic> getFrame(
    String name, {
    String scope = '',
    int? revision,
    String? requestId,
  }) =>
      {
        'type': 'flow_get_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        'name': name,
        if (revision != null) 'revision': revision,
      };

  static Map<String, dynamic> saveFrame(
    String name,
    String yaml, {
    String scope = '',
    bool createOnly = false,
    int? baseRevision,
    String? requestId,
  }) =>
      {
        'type': 'flow_save_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        'name': name,
        'yaml': yaml,
        // 新建 / 另存为要带上：主机收到同名就拒，不静默变成下一版（M1.5）。
        if (createOnly) 'create_only': true,
        if (baseRevision != null) 'base_revision': baseRevision,
      };

  static Map<String, dynamic> deleteFrame(
    String name, {
    String scope = '',
    String? requestId,
  }) =>
      {
        'type': 'flow_delete_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        'name': name,
      };

  static Map<String, dynamic> validateFrame(String yaml, {String? requestId}) =>
      {
        'type': 'flow_validate_req',
        if (requestId != null) 'request_id': requestId,
        'yaml': yaml,
      };

  /// 开跑：给 `yaml`，或者给库里的 `scope` + `name`。
  /// `instanceId` 传上次开跑响应的 `instance_id`：重跑同一业务时复用同一实例
  /// （重跑 / 子运行共用产物权限树）；不带就由主机铸新实例。旧主机忽略该字段。
  static Map<String, dynamic> startFrame({
    String yaml = '',
    String scope = '',
    String name = '',
    int? revision,
    Map<String, dynamic> inputs = const {},
    Map<String, dynamic>? bindings,
    String groupId = '',
    String sessionId = '',
    String taskId = '',
    String? instanceId,
    String? requestId,
  }) =>
      {
        'type': 'flow_run_start_req',
        if (requestId != null) 'request_id': requestId,
        if (yaml.isNotEmpty) 'yaml': yaml,
        if (scope.isNotEmpty) 'scope': scope,
        if (name.isNotEmpty) 'name': name,
        if (revision != null) 'revision': revision,
        'inputs': inputs,
        if (bindings != null) 'bindings': bindings,
        if (groupId.isNotEmpty) 'group_id': groupId,
        if (sessionId.isNotEmpty) 'session_id': sessionId,
        if (taskId.isNotEmpty) 'task_id': taskId,
        if (instanceId != null && instanceId.isNotEmpty)
          'instance_id': instanceId,
      };

  /// 运行列表（M8'）。`scope` / `name` 为空表示不过滤。
  static Map<String, dynamic> runListFrame({
    String scope = '',
    String name = '',
    String? requestId,
  }) =>
      {
        'type': 'flow_run_list_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        if (name.isNotEmpty) 'name': name,
      };

  static Map<String, dynamic> deleteRunFrame(String runId,
          {String? requestId}) =>
      {
        'type': 'flow_run_delete_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
      };

  static Map<String, dynamic> cancelFrame(String runId, {String? requestId}) =>
      {
        'type': 'flow_run_cancel_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
      };

  static Map<String, dynamic> runFrame(String runId, {String? requestId}) => {
        'type': 'flow_run_get_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
      };

  static Map<String, dynamic> nodeProgressFrame(
    String runId,
    String nodeKey, {
    String? requestId,
  }) =>
      {
        'type': 'flow_node_progress_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
        'node': nodeKey,
      };

  static Map<String, dynamic> gateFrame(
    String runId,
    String nodeKey,
    String choice, {
    String note = '',
    String? requestId,
  }) =>
      {
        'type': 'flow_gate_resp',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
        'node_key': nodeKey,
        'choice': choice,
        if (note.isNotEmpty) 'note': note,
      };

  /// 运行中改写（F19）：只改还没开始的节点。
  static Map<String, dynamic> patchFrame(
    String runId,
    String nodeKey,
    List<Map<String, dynamic>> steps, {
    String? requestId,
  }) =>
      {
        'type': 'flow_run_patch_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
        'node_key': nodeKey,
        'steps': steps,
      };

  static Map<String, dynamic> diffFrame({
    String scope = '',
    String name = '',
    String fromYaml = '',
    int? fromRevision,
    String toYaml = '',
    int? toRevision,
    String? requestId,
  }) =>
      {
        'type': 'flow_diff_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        if (name.isNotEmpty) 'name': name,
        if (fromYaml.isNotEmpty) 'from_yaml': fromYaml,
        if (fromRevision != null) 'from_revision': fromRevision,
        if (toYaml.isNotEmpty) 'to_yaml': toYaml,
        if (toRevision != null) 'to_revision': toRevision,
      };

  static Map<String, dynamic> editFrame(
    String yaml,
    List<Map<String, dynamic>> ops, {
    String? requestId,
  }) =>
      {
        'type': 'flow_edit_req',
        if (requestId != null) 'request_id': requestId,
        'yaml': yaml,
        'ops': ops,
      };

  static Map<String, dynamic> schemaFrame({String? requestId}) => {
        'type': 'flow_schema_req',
        if (requestId != null) 'request_id': requestId,
      };

  static Map<String, dynamic> rehearseFrame(String yaml, {String? requestId}) =>
      {
        'type': 'flow_rehearse_req',
        if (requestId != null) 'request_id': requestId,
        'yaml': yaml,
      };

  static Map<String, dynamic> rehearseAnswerFrame(
    String rehearsalId,
    String choice, {
    String? requestId,
  }) =>
      {
        'type': 'flow_rehearse_answer_req',
        if (requestId != null) 'request_id': requestId,
        'rehearsal_id': rehearsalId,
        'choice': choice,
      };

  static Map<String, dynamic> rehearseDropFrame(
    String rehearsalId, {
    String? requestId,
  }) =>
      {
        'type': 'flow_rehearse_drop_req',
        if (requestId != null) 'request_id': requestId,
        'rehearsal_id': rehearsalId,
      };

  /// 差异（C.5）。两边都不给 YAML 时，是 `name` 的最新版对上一版。
  Future<({FlowDiff? diff, String? error})> diff(
    String peerId, {
    String scope = '',
    String name = '',
    String fromYaml = '',
    int? fromRevision,
    String toYaml = '',
    int? toRevision,
  }) async {
    final response = await _request(
      peerId,
      diffFrame(
        scope: scope,
        name: name,
        fromYaml: fromYaml,
        fromRevision: fromRevision,
        toYaml: toYaml,
        toRevision: toRevision,
      ),
      responseType: 'flow_diff_resp',
    );
    return (
      diff: response == null ? null : FlowDiff.fromResponse(response),
      error: response?['error'] as String?,
    );
  }

  /// 结构化编辑（C.4）：返回新 YAML、节点树和诊断；`error` 非空是操作本身不成立。
  Future<({FlowValidation? result, String? error, bool reachable})> edit(
    String peerId,
    String yaml,
    List<Map<String, dynamic>> ops,
  ) async {
    final response = await _request(
      peerId,
      editFrame(yaml, ops),
      responseType: 'flow_edit_resp',
    );
    if (response == null) {
      return (result: null, error: null, reachable: false);
    }
    if (response['success'] != true) {
      return (
        result: null,
        error: response['error'] as String?,
        reachable: true
      );
    }
    return (
      result: FlowValidation.fromResponse({
        ...response,
        'success': response['valid'] == true,
      }),
      error: null,
      reachable: true,
    );
  }

  Future<FlowSchema?> schema(String peerId) async {
    final response = await _request(
      peerId,
      schemaFrame(),
      responseType: 'flow_schema_resp',
    );
    return response == null ? null : FlowSchema.fromResponse(response);
  }

  /// 演练（C.5）。`error` 是演练走不通的原因（校验不过、有 plan / call…）。
  /// 走到的地方若卡在关卡或判断上，`rehearsal.question` 有值，作答后继续。
  Future<({FlowRehearsal? rehearsal, String? error})> rehearse(
    String peerId,
    String yaml,
  ) async {
    final response = await _request(
      peerId,
      rehearseFrame(yaml),
      responseType: 'flow_rehearse_resp',
    );
    return (
      rehearsal: response == null ? null : FlowRehearsal.fromResponse(response),
      error: response?['error'] as String?,
    );
  }

  /// 演练卡住时作答（C.5），接着往下走。返回的同样是这一段的新样子。
  Future<({FlowRehearsal? rehearsal, String? error})> rehearseAnswer(
    String peerId,
    String rehearsalId,
    String choice,
  ) async {
    final response = await _request(
      peerId,
      rehearseAnswerFrame(rehearsalId, choice),
      responseType: 'flow_rehearse_resp',
    );
    return (
      rehearsal: response == null ? null : FlowRehearsal.fromResponse(response),
      error: response?['error'] as String?,
    );
  }

  /// 结束演练：主机上那份是内存里的，丢掉即可。
  Future<void> rehearseDrop(String peerId, String rehearsalId) async {
    await _request(
      peerId,
      rehearseDropFrame(rehearsalId),
      responseType: 'flow_rehearse_resp',
    );
  }

  Future<List<FlowSummary>?> list(String peerId, {String scope = ''}) async {
    final response = await listRaw(peerId, scope: scope);
    if (response == null) return null;
    return FlowSummary.listFromResponse(response, scope: scope);
  }

  /// `flow_list_resp` 原帧。查重要区分「主机没应答」和「主机回了失败」：前者
  /// 不能写，后者只是没法核名字（新主机的 create_only 是原子的，可以照常写）。
  Future<Map<String, dynamic>?> listRaw(String peerId,
          {String scope = ''}) async =>
      _request(
        peerId,
        listFrame(scope),
        responseType: 'flow_list_resp',
      );

  /// 读一版定义。返回 `{revision, yaml, requiredRoles}`；失败返回 null。
  ///
  /// `requiredRoles` 是新版主机算出的「开跑前要绑 Agent 的角色」；老主机不带
  /// 这个字段时为 null，调用方退回客户端的保守扫描。
  Future<({int revision, String yaml, List<String>? requiredRoles})?> get(
    String peerId,
    String name, {
    String scope = '',
    int? revision,
  }) async {
    final response = await _request(
      peerId,
      getFrame(name, scope: scope, revision: revision),
      responseType: 'flow_get_resp',
    );
    if (response == null || response['success'] != true) return null;
    final yaml = response['yaml'];
    if (yaml is! String) return null;
    final rawRoles = response['required_roles'];
    return (
      revision: (response['revision'] as num?)?.toInt() ?? 0,
      yaml: yaml,
      requiredRoles: rawRoles is List
          ? <String>[for (final role in rawRoles) role.toString()]
          : null,
    );
  }

  /// 主机校验并回节点树。`error` 非空时是写不通的原因。
  Future<FlowValidation?> validate(String peerId, String yaml) async {
    final response = await _request(
      peerId,
      validateFrame(yaml),
      responseType: 'flow_validate_resp',
    );
    if (response == null) return null;
    return FlowValidation.fromResponse(response);
  }

  Future<FlowCall> save(
    String peerId,
    String name,
    String yaml, {
    String scope = '',
    bool createOnly = false,
    int? baseRevision,
  }) =>
      _call(
        peerId,
        saveFrame(
          name,
          yaml,
          scope: scope,
          createOnly: createOnly,
          baseRevision: baseRevision,
        ),
        'flow_save_resp',
      );

  Future<FlowCall> delete(String peerId, String name, {String scope = ''}) =>
      _call(peerId, deleteFrame(name, scope: scope), 'flow_delete_resp');

  /// 开跑。成功时 [FlowCall.data] 里有 `run_id` / `instance_id` / `instance_scope`。
  Future<FlowCall> start(
    String peerId, {
    String yaml = '',
    String scope = '',
    String name = '',
    int? revision,
    Map<String, dynamic> inputs = const {},
    Map<String, dynamic>? bindings,
    String groupId = '',
    String sessionId = '',
    String taskId = '',
    String? instanceId,
  }) =>
      _call(
        peerId,
        startFrame(
          yaml: yaml,
          scope: scope,
          name: name,
          revision: revision,
          inputs: inputs,
          bindings: bindings,
          groupId: groupId,
          sessionId: sessionId,
          taskId: taskId,
          instanceId: instanceId,
        ),
        'flow_run_start_resp',
      );

  /// 删掉一次运行（B.6 / C.8）：数据清掉，节点会话从折叠组里隐藏。
  /// 还在跑的会被主机拒（`error` 里说明）。
  Future<FlowCall> deleteRun(String peerId, String runId) =>
      _call(peerId, deleteRunFrame(runId), 'flow_run_delete_resp');

  Future<FlowCall> cancel(String peerId, String runId) =>
      _call(peerId, cancelFrame(runId), 'flow_run_cancel_resp');

  Future<FlowCall> answerGate(
    String peerId,
    String runId,
    String nodeKey,
    String choice, {
    String note = '',
  }) =>
      _call(
        peerId,
        gateFrame(runId, nodeKey, choice, note: note),
        'flow_gate_resp',
      );

  Future<FlowCall> patch(
    String peerId,
    String runId,
    String nodeKey,
    List<Map<String, dynamic>> steps,
  ) =>
      _call(
        peerId,
        patchFrame(runId, nodeKey, steps),
        'flow_run_patch_resp',
      );

  /// 列出运行。返回 null 表示主机没应答（不是「没有运行」）。
  Future<List<FlowRunSummary>?> runList(
    String peerId, {
    String scope = '',
    String name = '',
  }) async {
    final response = await _request(
      peerId,
      runListFrame(scope: scope, name: name),
      responseType: 'flow_run_list_resp',
    );
    if (response == null) return null;
    // 主机明确报错（success:false）不能当成「没有运行」；返回 null 让界面显示
    // 错误态，而不是永久转圈或假空列表。
    if (response['success'] != true || response['runs'] is! List) return null;
    return FlowRunSummary.listFromResponse(response);
  }

  Future<FlowRunView?> run(String peerId, String runId) async {
    final response = await _request(
      peerId,
      runFrame(runId),
      responseType: 'flow_run_get_resp',
    );
    if (response == null) return null;
    return FlowRunView.fromResponse(response);
  }

  /// 节点最近一轮的思考 / 工具步骤。只在用户点开节点时取（正文可能几十 KB，
  /// 不放进每个事件都会重拉的 `flow_run_get_resp`）。主机没应答返回 null。
  /// [cancel] 完成（面板关掉）就不再等。
  Future<FlowNodeProgress?> nodeProgress(
    String peerId,
    String runId,
    String nodeKey, {
    Future<void>? cancel,
  }) async {
    final response = await _request(
      peerId,
      nodeProgressFrame(runId, nodeKey),
      responseType: 'flow_node_progress_resp',
      cancel: cancel,
    );
    if (response == null) return null;
    return FlowNodeProgress.fromResponse(response);
  }

  /// 主机推来的运行与节点事件。
  Stream<FlowEvent> runEvents(String peerId) {
    return events
        .where((event) =>
            event.peerId == peerId &&
            (event.type == 'flow.run.changed' ||
                event.type == 'flow.node.changed'))
        .map((event) => FlowEvent.parse(event.type, event.data))
        .where((event) => event != null)
        .cast<FlowEvent>();
  }

  /// 当前登录的主机；没登录返回空串。
  Future<String> activeHost() async {
    final session = await PouchSessionStore.readActive();
    return session?.hostPeerId ?? '';
  }

  Future<FlowCall> _call(
    String peerId,
    Map<String, dynamic> frame,
    String responseType,
  ) async {
    final response = await _request(peerId, frame, responseType: responseType);
    return FlowCall.fromResponse(response);
  }

  /// [cancel] 完成时按「没应答」收场（返回 null），并立即释放超时计时器：
  /// 面板关了就不必再等主机——老主机不认的请求原本要白挂 10 秒。
  Future<Map<String, dynamic>?> _request(
    String peerId,
    Map<String, dynamic> frame, {
    required String responseType,
    Future<void>? cancel,
  }) async {
    final requestId = frame['request_id'] as String? ?? _uuid.v4();
    frame['request_id'] = requestId;
    final done = Completer<Map<String, dynamic>?>();
    void giveUp() {
      if (!done.isCompleted) done.complete(null);
    }

    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId || event.type != responseType) return;
      if (event.data['request_id'] != requestId) return;
      done.complete(event.data);
    });
    unawaited(cancel?.then((_) => giveUp()));
    Timer? timer;
    try {
      final sent = await _send(peerId, frame).timeout(
        sendTimeout,
        onTimeout: () => false,
      );
      if (!sent) return null;
      timer = Timer(const Duration(seconds: 10), giveUp);
      return await done.future;
    } catch (_) {
      return null;
    } finally {
      timer?.cancel();
      unawaited(sub.cancel());
    }
  }

  Future<bool> _send(String peerId, Map<String, dynamic> frame) {
    final send = this.send;
    if (send != null) return send(peerId, frame);
    return PeerConnectionManager.instance.sendControl(peerId, frame);
  }
}

/// 一次写操作的结果。`reachable` 为假表示没问到主机（不在线、超时）。
class FlowCall {
  const FlowCall({
    required this.reachable,
    required this.ok,
    this.error,
    this.data = const {},
  });

  final bool reachable;
  final bool ok;
  final String? error;
  final Map<String, dynamic> data;

  /// 不同的帧有的回 `success`，有的回 `ok`，这里一起认。
  factory FlowCall.fromResponse(Map<String, dynamic>? response) {
    if (response == null) {
      return const FlowCall(reachable: false, ok: false);
    }
    final ok = response['success'] == true || response['ok'] == true;
    final error = response['error'];
    return FlowCall(
      reachable: true,
      ok: ok,
      error: ok ? null : (error is String && error.isNotEmpty ? error : null),
      data: response,
    );
  }

  String? get runId => data['run_id'] as String?;

  /// 三层分区坐标；旧主机不带这两个字段，取到 null 就按新实例处理。
  String? get instanceId => data['instance_id'] as String?;
  String? get instanceScope => data['instance_scope'] as String?;
}

/// `flow_validate_resp`：节点树 + 诊断。
class FlowValidation {
  const FlowValidation({
    required this.ok,
    required this.yaml,
    required this.tree,
    required this.diagnostics,
    this.error,
  });

  final bool ok;

  /// 补过 id 的 YAML；后续修改沿用同一批 id。
  final String yaml;
  final List<FlowNode> tree;
  final List<FlowDiagnostic> diagnostics;
  final String? error;

  factory FlowValidation.fromResponse(Map<String, dynamic> response) {
    final rawTree = response['tree'];
    final rawDiagnostics = response['diagnostics'];
    return FlowValidation(
      ok: response['success'] == true,
      yaml: (response['yaml'] as String?) ?? '',
      tree: rawTree is List
          ? [
              for (final node in rawTree)
                if (node is Map)
                  FlowNode.fromJson(Map<String, dynamic>.from(node)),
            ]
          : const [],
      diagnostics: rawDiagnostics is List
          ? [
              for (final item in rawDiagnostics)
                if (item is Map)
                  FlowDiagnostic.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      error: response['error'] as String?,
    );
  }
}

class FlowDiagnostic {
  const FlowDiagnostic({
    required this.at,
    required this.severity,
    required this.message,
  });

  final String at;
  final String severity;
  final String message;

  bool get isError => severity == 'error';

  factory FlowDiagnostic.fromJson(Map<String, dynamic> json) => FlowDiagnostic(
        at: (json['at'] as String?) ?? '',
        severity: (json['severity'] as String?) ?? 'error',
        message: (json['message'] as String?) ?? '',
      );
}
