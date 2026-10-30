import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_session.dart';
import '../models/flow_models.dart';
import 'peer_connection_manager.dart';

/// 工作流帧的收发（方案 B.8 / C.7）。主机是权威：流程库、运行、关卡都在
/// 主机上，App 只发请求、吃 `flow.*` 事件。
///
/// 请求构造函数是纯函数，单测直接比对线上字段（同 [HubGroupSessions]）。
class HubFlow {
  HubFlow({
    this.send,
    Stream<PeerControlEvent>? events,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
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
    String? requestId,
  }) =>
      {
        'type': 'flow_save_req',
        if (requestId != null) 'request_id': requestId,
        if (scope.isNotEmpty) 'scope': scope,
        'name': name,
        'yaml': yaml,
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
      };

  static Map<String, dynamic> cancelFrame(String runId, {String? requestId}) => {
        'type': 'flow_run_cancel_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
      };

  static Map<String, dynamic> runFrame(String runId, {String? requestId}) => {
        'type': 'flow_run_get_req',
        if (requestId != null) 'request_id': requestId,
        'run_id': runId,
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

  Future<List<FlowSummary>?> list(String peerId, {String scope = ''}) async {
    final response = await _request(
      peerId,
      listFrame(scope),
      responseType: 'flow_list_resp',
    );
    if (response == null) return null;
    return FlowSummary.listFromResponse(response, scope: scope);
  }

  /// 读一版定义。返回 `{revision, yaml}`；失败返回 null。
  Future<({int revision, String yaml})?> get(
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
    return (revision: (response['revision'] as num?)?.toInt() ?? 0, yaml: yaml);
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
  }) =>
      _call(
        peerId,
        saveFrame(name, yaml, scope: scope),
        'flow_save_resp',
      );

  Future<FlowCall> delete(String peerId, String name, {String scope = ''}) =>
      _call(peerId, deleteFrame(name, scope: scope), 'flow_delete_resp');

  /// 开跑。成功时 [FlowCall.data] 里有 `run_id`。
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
        ),
        'flow_run_start_resp',
      );

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

  Future<FlowRunView?> run(String peerId, String runId) async {
    final response = await _request(
      peerId,
      runFrame(runId),
      responseType: 'flow_run_get_resp',
    );
    if (response == null) return null;
    return FlowRunView.fromResponse(response);
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

  Future<Map<String, dynamic>?> _request(
    String peerId,
    Map<String, dynamic> frame, {
    required String responseType,
  }) async {
    final requestId = frame['request_id'] as String? ?? _uuid.v4();
    frame['request_id'] = requestId;
    final done = Completer<Map<String, dynamic>?>();
    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId || event.type != responseType) return;
      if (event.data['request_id'] != requestId) return;
      done.complete(event.data);
    });
    try {
      final sent = await _send(peerId, frame);
      if (!sent) return null;
      return await done.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
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
      return const FlowCall(reachable: false, ok: false, error: '主机没有回应');
    }
    final ok = response['success'] == true || response['ok'] == true;
    final error = response['error'];
    return FlowCall(
      reachable: true,
      ok: ok,
      error: ok ? null : (error is String && error.isNotEmpty ? error : '失败'),
      data: response,
    );
  }

  String? get runId => data['run_id'] as String?;
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
