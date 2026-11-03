import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_session.dart';
import 'peer_connection_manager.dart';

/// 会话创建交给主机：App 只发帧、等回包，不再本地建会话。
///
/// 主机在 peer 控制通道上处理 `session_create_req`，回 `session_create_resp`。
/// 和 [HubGroupSessions] 一样用 `request_id` 配对，避免并发建会话串包。
class HubSessionCreate {
  HubSessionCreate({
    this.send,
    this.readActive,
    this.peerId,
    Stream<PeerControlEvent>? events,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Future<PouchSession?> Function()? readActive;
  /// 测试里直接给 peer id，跳过读登录态。
  final String? peerId;
  final Stream<PeerControlEvent> events;
  final _uuid = const Uuid();

  /// [frame] 里是业务字段（kind / agent_id / channel_id / reason / summary ...）。
  Future<Map<String, dynamic>> create(Map<String, dynamic> frame) async {
    final active = peerId == null
        ? await (readActive?.call() ?? PouchSessionStore.readActive())
        : null;
    final host = (peerId ?? active?.hostPeerId ?? '').trim();
    if (host.isEmpty) {
      return {'error': '没有连接主机，无法创建会话'};
    }
    final requestId = _uuid.v4();
    final payload = <String, dynamic>{
      'type': 'session_create_req',
      'request_id': requestId,
      ...frame,
    };
    final done = Completer<Map<String, dynamic>?>();
    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != host || event.type != 'session_create_resp') return;
      if (event.data['request_id'] != requestId) return;
      done.complete(event.data);
    });
    try {
      final sent = await _send(host, payload);
      if (!sent) return {'error': '发送失败：主机未连接'};
      final reply = await done.future.timeout(const Duration(seconds: 10));
      return reply ?? {'error': '主机没有回复'};
    } catch (_) {
      return {'error': '等待主机回复超时'};
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
