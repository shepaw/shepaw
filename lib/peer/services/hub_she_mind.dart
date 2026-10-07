import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../storage/pouch_session.dart';
import 'peer_connection_manager.dart';

/// 惜宝的画像和长期记忆。读写都在主机上。
class HubSheMind {
  HubSheMind({
    this.send,
    Stream<PeerControlEvent>? events,
  }) : events = events ?? PeerConnectionManager.instance.controlEvents;

  final Future<bool> Function(String peerId, Map<String, dynamic> frame)? send;
  final Stream<PeerControlEvent> events;
  final _uuid = const Uuid();

  Future<Map<String, String>> profile() async {
    final response = await _roundTrip(
      {'type': 'she_profile_get_req'},
      'she_profile_get_resp',
    );
    final raw = response['profile'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  }

  Future<void> saveProfile(Map<String, String> profile) async {
    await _roundTrip(
      {'type': 'she_profile_set_req', 'profile': profile},
      'she_profile_set_resp',
    );
  }

  Future<String> longTermMemory() async {
    final response = await _roundTrip(
      {'type': 'she_memory_get_req'},
      'she_memory_get_resp',
    );
    return response['long_term_memory'] as String? ?? '';
  }

  Future<void> saveLongTermMemory(String text) async {
    await _roundTrip(
      {'type': 'she_memory_set_req', 'long_term_memory': text},
      'she_memory_set_resp',
    );
  }

  Future<Map<String, dynamic>> _roundTrip(
    Map<String, dynamic> frame,
    String responseType,
  ) async {
    final session = await PouchSessionStore.readActive();
    final peerId = session?.hostPeerId ?? '';
    if (peerId.isEmpty) {
      throw Exception('没有连上主机');
    }
    final requestId = _uuid.v4();
    frame['request_id'] = requestId;
    final done = Completer<Map<String, dynamic>>();
    final sub = events.listen((event) {
      if (done.isCompleted) return;
      if (event.peerId != peerId || event.type != responseType) return;
      if (event.data['request_id'] != requestId) return;
      done.complete(event.data);
    });
    try {
      final sent = await _send(peerId, frame);
      if (!sent) throw Exception('没有连上主机');
      final response = await done.future.timeout(const Duration(seconds: 8));
      if (response['ok'] != true) {
        throw Exception(response['error']?.toString() ?? '主机没有保存');
      }
      return response;
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
