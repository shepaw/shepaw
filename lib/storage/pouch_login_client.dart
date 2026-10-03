import 'dart:async';

import 'package:uuid/uuid.dart';

import '../peer/services/peer_connection_manager.dart';
import 'pouch_catalog.dart';

/// 服务端签发的一次袋子登录。
class PouchLoginGrant {
  const PouchLoginGrant({
    required this.token,
    required this.sessionId,
    required this.expiresAtMs,
  });

  final String token;
  final String sessionId;
  final int expiresAtMs;
}

/// 向已经配对的 shepaw 要一枚登录 token。没连上就失败，不在本地伪造登录态。
Future<PouchLoginGrant> requestPouchLogin({
  required String hostPeerId,
  required String pouchId,
  Duration timeout = const Duration(seconds: 8),
}) {
  return _request(
    hostPeerId: hostPeerId,
    type: 'pouch_login',
    responseType: 'pouch_login_resp',
    extra: <String, dynamic>{'pouch_id': pouchId},
    timeout: timeout,
    parse: (data) {
      if (data['accepted'] != true) {
        throw StateError((data['reason'] as String?)?.trim().isNotEmpty == true
            ? data['reason'] as String
            : '登录被拒绝');
      }
      final token = (data['token'] as String?)?.trim() ?? '';
      final sid = (data['sid'] as String?)?.trim() ?? '';
      final expires = data['expires_at'];
      if (token.isEmpty || sid.isEmpty || expires is! int) {
        throw StateError('登录响应不完整');
      }
      return PouchLoginGrant(
        token: token,
        sessionId: sid,
        expiresAtMs: expires,
      );
    },
  );
}

/// 问指定主机上有哪些袋子。手机读不到主机磁盘时靠它。
Future<List<PouchDescriptor>> requestPouchList({
  required String hostPeerId,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final listed = await _request<List<dynamic>>(
    hostPeerId: hostPeerId,
    type: 'pouch_list',
    responseType: 'pouch_list_resp',
    timeout: timeout,
    parse: (data) => (data['pouches'] as List?) ?? const [],
  );
  return _pouchesFrom(listed);
}

/// 在主机上新建一只袋子。还没登录，所以这一帧是明文。
Future<PouchDescriptor> requestPouchCreate({
  required String hostPeerId,
  required String name,
  Duration timeout = const Duration(seconds: 8),
}) {
  return _request(
    hostPeerId: hostPeerId,
    type: 'pouch_create',
    responseType: 'pouch_create_resp',
    extra: <String, dynamic>{'name': name},
    timeout: timeout,
    parse: (data) {
      if (data['ok'] != true) {
        final error = (data['error'] as String?)?.trim() ?? '';
        throw StateError(error.isEmpty ? '没能建好袋子' : error);
      }
      final raw = data['pouch'];
      if (raw is! Map) throw StateError('建袋子的响应不完整');
      final pouch = _pouchesFrom([raw]);
      if (pouch.isEmpty) throw StateError('建袋子的响应不完整');
      return pouch.single;
    },
  );
}

List<PouchDescriptor> _pouchesFrom(List<dynamic> listed) {
  return listed
      .whereType<Map>()
      .map((raw) {
        final id = (raw['id'] as String?)?.trim() ?? '';
        final name = (raw['name'] as String?)?.trim() ?? '';
        if (id.isEmpty || name.isEmpty) return null;
        return PouchDescriptor(id: id, name: name, rootPath: '');
      })
      .whereType<PouchDescriptor>()
      .toList();
}

Future<T> _request<T>({
  required String hostPeerId,
  required String type,
  required String responseType,
  Map<String, dynamic> extra = const {},
  required Duration timeout,
  required T Function(Map<String, dynamic> data) parse,
}) async {
  final requestId = const Uuid().v4();
  final done = Completer<T>();
  final sub = PeerConnectionManager.instance.controlEvents.listen((event) {
    if (done.isCompleted) return;
    if (event.peerId != hostPeerId || event.type != responseType) return;
    if (event.data['request_id'] != requestId) return;
    try {
      done.complete(parse(event.data));
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  try {
    final sent = await PeerConnectionManager.instance.sendControl(
      hostPeerId,
      <String, dynamic>{
        'type': type,
        'request_id': requestId,
        ...extra,
      },
    );
    if (!sent) throw StateError('还没连上 shepaw');
    return await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}
