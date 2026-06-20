import 'dart:convert';

/// P2P 同步事件（Primary 权威 log 条目）。
class SyncEvent {
  final String eventId;
  final String domain;
  final Map<String, dynamic> payload;
  final int wallTimeMs;
  final String originDeviceId;

  const SyncEvent({
    required this.eventId,
    required this.domain,
    required this.payload,
    required this.wallTimeMs,
    required this.originDeviceId,
  });

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'domain': domain,
        'payload': payload,
        'wall_time_ms': wallTimeMs,
        'origin_device_id': originDeviceId,
      };

  factory SyncEvent.fromJson(Map<String, dynamic> json) => SyncEvent(
        eventId: json['event_id'] as String,
        domain: json['domain'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        wallTimeMs: json['wall_time_ms'] as int,
        originDeviceId: json['origin_device_id'] as String? ?? '',
      );

  static SyncEvent messageEvent({
    required Map<String, dynamic> messageRow,
    required String originDeviceId,
  }) {
    final createdAt = messageRow['created_at'] as String? ?? '';
    final wallTime = DateTime.tryParse(createdAt)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'msg:${messageRow['id']}',
      domain: 'message',
      payload: Map<String, dynamic>.from(messageRow),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent channelEvent({
    required Map<String, dynamic> channelRow,
    required String originDeviceId,
  }) {
    final updatedAt = channelRow['updated_at'] as String? ?? channelRow['created_at'] as String? ?? '';
    final wallTime = DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'ch:${channelRow['id']}',
      domain: 'channel',
      payload: Map<String, dynamic>.from(channelRow),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory SyncEvent.fromJsonString(String raw) =>
      SyncEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
