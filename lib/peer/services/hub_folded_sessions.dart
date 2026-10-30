import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/folded_sessions.dart';
import 'peer_connection_manager.dart';

/// 会话列表的折叠视图（折叠方案 §3.1）：各组摘要、组明细分页、分叉到私聊。
///
/// 请求都带 `request_id`，主机原样带回；现有的平铺名单回包没有 request_id，
/// 两条路互不串。
class HubFoldedSessions {
  HubFoldedSessions({
    this.send,
    Stream<PeerControlEvent>? events,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
  final _uuid = const Uuid();

  static Map<String, dynamic> summaryFrame(String agentId,
          {String? requestId}) =>
      {
        'type': 'agent_sessions_req',
        if (requestId != null) 'request_id': requestId,
        'agent_id': agentId,
        'view': 'folded',
      };

  static Map<String, dynamic> folderFrame(
    String agentId,
    SessionFolderKind folder, {
    String cursor = '',
    int? limit,
    String parentSession = '',
    String? requestId,
  }) =>
      {
        'type': 'agent_sessions_req',
        if (requestId != null) 'request_id': requestId,
        'agent_id': agentId,
        'view': 'folded',
        'folder': folder.wire,
        if (cursor.isNotEmpty) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        if (parentSession.isNotEmpty) 'parent_session': parentSession,
      };

  /// 分叉到私聊：新会话是可聊的 private。
  static Map<String, dynamic> forkFrame(
    String agentId,
    String sessionId, {
    String? requestId,
  }) =>
      {
        'type': 'agent_session_fork_req',
        if (requestId != null) 'request_id': requestId,
        'agent_id': agentId,
        'session_id': sessionId,
      };

  Future<FoldedSummary?> summary(String peerId, String agentId) async {
    final response = await _request(
      peerId,
      summaryFrame(agentId),
      'agent_sessions_resp',
    );
    return response == null ? null : FoldedSummary.fromResponse(response);
  }

  Future<FoldedPage?> page(
    String peerId,
    String agentId,
    SessionFolderKind folder, {
    String cursor = '',
    int limit = 50,
    String parentSession = '',
  }) async {
    final response = await _request(
      peerId,
      folderFrame(
        agentId,
        folder,
        cursor: cursor,
        limit: limit,
        parentSession: parentSession,
      ),
      'agent_sessions_resp',
    );
    return response == null ? null : FoldedPage.fromResponse(response);
  }

  /// 分叉成功返回新会话 id；失败返回 null 和主机给的原因（`error`）。
  Future<({String? sessionId, String? error})> fork(
    String peerId,
    String agentId,
    String sessionId,
  ) async {
    final response = await _request(
      peerId,
      forkFrame(agentId, sessionId),
      'agent_session_fork_resp',
    );
    if (response == null) return (sessionId: null, error: '主机没有回应');
    if (response['ok'] == true && response['session_id'] is String) {
      return (sessionId: response['session_id'] as String, error: null);
    }
    return (sessionId: null, error: response['error'] as String? ?? '分叉失败');
  }

  Future<Map<String, dynamic>?> _request(
    String peerId,
    Map<String, dynamic> frame,
    String responseType,
  ) async {
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
      final sent = await (send?.call(peerId, frame) ??
          PeerConnectionManager.instance.sendControl(peerId, frame));
      if (!sent) return null;
      return await done.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      unawaited(sub.cancel());
    }
  }
}
