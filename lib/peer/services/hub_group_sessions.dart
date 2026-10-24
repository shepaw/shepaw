import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_session.dart';
import 'peer_connection_manager.dart';

/// 群会话（B 2.2）。主机是权威；App 只缓存这一份名单。
class GroupSessionInfo {
  const GroupSessionInfo({
    required this.id,
    required this.title,
    required this.status,
    required this.createdAt,
    this.lastTaskAt,
  });

  final String id;
  final String title;
  final String status;
  final int createdAt;
  final int? lastTaskAt;

  bool get isArchived => status == 'archived';

  factory GroupSessionInfo.fromJson(Map<String, dynamic> json) {
    final created = json['created_at'];
    final lastTask = json['last_task_at'];
    return GroupSessionInfo(
      id: (json['id'] as String?)?.trim() ?? '',
      title: (json['title'] as String?)?.trim() ?? '',
      status: (json['status'] as String?)?.trim() ?? 'active',
      createdAt: created is num ? created.toInt() : 0,
      lastTaskAt: lastTask is num ? lastTask.toInt() : null,
    );
  }
}

/// 一次名单请求的结果。`currentSession` 是群 meta 里的指针。
class GroupSessionListResult {
  const GroupSessionListResult({
    required this.currentSession,
    required this.sessions,
  });

  final String currentSession;
  final List<GroupSessionInfo> sessions;

  static GroupSessionListResult? fromResponse(Map<String, dynamic> response) {
    if (response['ok'] != true) return null;
    final raw = response['sessions'];
    final sessions = <GroupSessionInfo>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          sessions.add(
            GroupSessionInfo.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return GroupSessionListResult(
      currentSession: (response['current_session'] as String?)?.trim() ?? '',
      sessions: sessions,
    );
  }
}

/// 当前在用的群会话。不进数据库：选一次，这一端之后的群回合都带它；
/// 没选过就不带，主机取群 meta 的 current_session。
class GroupSessionSelection {
  GroupSessionSelection._();

  static final Map<String, String> _byGroup = <String, String>{};

  static String? of(String groupId) => _byGroup[groupId];

  static void select(String groupId, String sessionId) {
    if (groupId.isEmpty) return;
    if (sessionId.isEmpty) {
      _byGroup.remove(groupId);
    } else {
      _byGroup[groupId] = sessionId;
    }
  }

  static void clear() => _byGroup.clear();
}

/// 群会话帧的收发（G4 / B 4.5）：group_session_list/create/rename/archive。
///
/// 请求构造函数是纯函数，单测直接比对线上字段。
class HubGroupSessions {
  HubGroupSessions({
    this.send,
    Stream<PeerControlEvent>? events,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
  final _uuid = const Uuid();

  static Map<String, dynamic> listFrame(String groupId, {String? requestId}) =>
      <String, dynamic>{
        'type': 'group_session_list_req',
        if (requestId != null) 'request_id': requestId,
        'group_id': groupId,
      };

  static Map<String, dynamic> createFrame(
    String groupId, {
    String title = '',
    String? requestId,
  }) =>
      <String, dynamic>{
        'type': 'group_session_create_req',
        if (requestId != null) 'request_id': requestId,
        'group_id': groupId,
        if (title.isNotEmpty) 'title': title,
      };

  static Map<String, dynamic> renameFrame(
    String groupId,
    String sessionId,
    String title, {
    String? requestId,
  }) =>
      <String, dynamic>{
        'type': 'group_session_rename_req',
        if (requestId != null) 'request_id': requestId,
        'group_id': groupId,
        'session_id': sessionId,
        'title': title,
      };

  static Map<String, dynamic> archiveFrame(
    String groupId,
    String sessionId, {
    String? requestId,
  }) =>
      <String, dynamic>{
        'type': 'group_session_archive_req',
        if (requestId != null) 'request_id': requestId,
        'group_id': groupId,
        'session_id': sessionId,
      };

  Future<GroupSessionListResult?> list(String peerId, String groupId) async {
    final response = await _request(
      peerId,
      listFrame(groupId, requestId: _uuid.v4()),
      responseType: 'group_session_list_resp',
    );
    if (response == null) return null;
    return GroupSessionListResult.fromResponse(response);
  }

  /// 新建会话。返回新会话；指针只在群还没有当前会话时才动（B 2.2）。
  Future<GroupSessionInfo?> create(
    String peerId,
    String groupId, {
    String title = '',
  }) async {
    final response = await _request(
      peerId,
      createFrame(groupId, title: title, requestId: _uuid.v4()),
      responseType: 'group_session_create_resp',
    );
    final session = response?['session'];
    if (session is! Map) return null;
    return GroupSessionInfo.fromJson(Map<String, dynamic>.from(session));
  }

  Future<bool> rename(
    String peerId,
    String groupId,
    String sessionId,
    String title,
  ) async {
    final response = await _request(
      peerId,
      renameFrame(groupId, sessionId, title, requestId: _uuid.v4()),
      responseType: 'group_session_rename_resp',
    );
    return response?['ok'] == true;
  }

  Future<bool> archive(
    String peerId,
    String groupId,
    String sessionId,
  ) async {
    final response = await _request(
      peerId,
      archiveFrame(groupId, sessionId, requestId: _uuid.v4()),
      responseType: 'group_session_archive_resp',
    );
    return response?['ok'] == true;
  }

  /// 登录失败返回 null；调用方按「主机不在线」处理。
  Future<String> activeHost() async {
    final session = await PouchSessionStore.readActive();
    return session?.hostPeerId ?? '';
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
      return await done.future.timeout(const Duration(seconds: 8));
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
