import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/flow_models.dart';
import 'peer_connection_manager.dart';

/// 工作流产物读接口（M4）。写/提升/删除都由主机在流程收尾与 scope 清理里做，
/// App 只列 `pouch.artifact_list`、按需读 `pouch.artifact_get`。
///
/// 帧名沿用 `pouch_*_req/resp` 控制帧；`command` 同时带上主机命令目录里的
/// 点号 id，方便主机把同一请求转给 `pouch.artifact_*` 总线命令。主机没回或
/// 老主机缺字段，解析层一律返回空列表，不把运行页变成错误页。
class HubArtifact {
  HubArtifact({
    this.send,
    Stream<PeerControlEvent>? events,
    this.sendTimeout = const Duration(seconds: 8),
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
  final Duration sendTimeout;
  final _uuid = const Uuid();

  static const artifactListCommand = 'pouch.artifact_list';
  static const artifactGetCommand = 'pouch.artifact_get';
  static const listRequestType = 'pouch_artifact_list_req';
  static const listResponseType = 'pouch_artifact_list_resp';
  static const getRequestType = 'pouch_artifact_get_req';
  static const getResponseType = 'pouch_artifact_get_resp';

  static Map<String, dynamic> artifactListFrame(
    String scope, {
    String? runId,
    String? requestId,
  }) =>
      {
        'type': listRequestType,
        'command': artifactListCommand,
        if (requestId != null) 'request_id': requestId,
        'scope': scope,
        if (runId != null && runId.isNotEmpty) 'run_id': runId,
        'args': <String, dynamic>{
          'scope': scope,
          if (runId != null && runId.isNotEmpty) 'run_id': runId,
        },
      };

  static Map<String, dynamic> artifactGetFrame(
    String artifactId, {
    String scope = '',
    int? version,
    String? uri,
    String? requestId,
  }) =>
      {
        'type': getRequestType,
        'command': artifactGetCommand,
        if (requestId != null) 'request_id': requestId,
        'artifact_id': artifactId,
        if (scope.isNotEmpty) 'scope': scope,
        if (version != null) 'version': version,
        if (uri != null && uri.isNotEmpty) 'uri': uri,
        'args': <String, dynamic>{
          // `pouch.artifact_get` 的命令目录只收 artifact_id；scope / version
          // 是给 peer 帧处理器定位用的可选项，不塞进命令参数。
          'artifact_id': artifactId,
        },
      };

  static List<FlowArtifact> parseListResponse(Map<String, dynamic>? response) =>
      FlowArtifact.listFromResponse(response);

  static FlowArtifact? parseGetResponse(Map<String, dynamic>? response) =>
      FlowArtifact.fromResponse(response);

  Future<List<FlowArtifact>> list(
    String peerId,
    String scope, {
    String? runId,
  }) async {
    if (scope.trim().isEmpty) return const <FlowArtifact>[];
    final response = await _request(
      peerId,
      artifactListFrame(scope, runId: runId),
      responseType: listResponseType,
      command: artifactListCommand,
    );
    return parseListResponse(response);
  }

  Future<FlowArtifact?> get(
    String peerId,
    String artifactId, {
    String scope = '',
    int? version,
    String? uri,
  }) async {
    if (artifactId.trim().isEmpty && (uri == null || uri.trim().isEmpty)) {
      return null;
    }
    // 主机要求三层树 scope 作为授权边界（防止跨实例读产物）；没带就不发帧，
    // 和 list 对空 scope 的降级保持一致。
    if (scope.trim().isEmpty) return null;
    final response = await _request(
      peerId,
      artifactGetFrame(
        artifactId,
        scope: scope,
        version: version,
        uri: uri,
      ),
      responseType: getResponseType,
      command: artifactGetCommand,
    );
    return parseGetResponse(response);
  }

  Future<Map<String, dynamic>?> _request(
    String peerId,
    Map<String, dynamic> frame, {
    required String responseType,
    required String command,
  }) async {
    final requestId = frame['request_id'] as String? ?? _uuid.v4();
    frame['request_id'] = requestId;
    // pouch 协议信封用 req_id；两种 id 都带上，响应只需回其中一个。
    frame.putIfAbsent('req_id', () => requestId);
    final done = Completer<Map<String, dynamic>?>();
    final sub = events.listen((event) {
      if (done.isCompleted || event.peerId != peerId) return;
      final data = event.data;
      if (data['request_id'] != requestId && data['req_id'] != requestId) {
        return;
      }
      final type = event.type;
      final isTypedReply = type == responseType || type == command;
      // 通用 pouch 信封只在真的带着产物数据时才算回复；否则同一个 req_id
      // 上任何一次无关的 pouch result/error 都会把等待提前结束。
      final isPouchEnvelope = type == 'pouch' &&
          (data['op'] == 'result' || data['op'] == 'error') &&
          (data.containsKey('artifacts') ||
              data.containsKey('artifact') ||
              data.containsKey('artifact_id'));
      if (isTypedReply || isPouchEnvelope) done.complete(data);
    });
    try {
      final sent = await _send(peerId, frame).timeout(
        sendTimeout,
        onTimeout: () => false,
      );
      if (!sent) return null;
      return await done.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      unawaited(sub.cancel());
    }
  }

  Future<bool> _send(String peerId, Map<String, dynamic> frame) {
    final send = this.send;
    if (send != null) return send(peerId, frame);
    return PeerConnectionManager.instance.sendControl(peerId, frame);
  }
}
