import 'dart:convert';

/// 同步事件动作。
enum SyncEventAction {
  upsert('upsert'),
  delete('delete');

  final String wireValue;
  const SyncEventAction(this.wireValue);

  static SyncEventAction fromWire(String? raw) {
    if (raw == 'delete') return SyncEventAction.delete;
    return SyncEventAction.upsert;
  }
}

/// P2P 同步事件（Primary 权威 log 条目）。
class SyncEvent {
  final String eventId;
  final String domain;
  final SyncEventAction action;
  final Map<String, dynamic> payload;
  final int wallTimeMs;
  final String originDeviceId;

  const SyncEvent({
    required this.eventId,
    required this.domain,
    this.action = SyncEventAction.upsert,
    required this.payload,
    required this.wallTimeMs,
    required this.originDeviceId,
  });

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'domain': domain,
        'action': action.wireValue,
        'payload': payload,
        'wall_time_ms': wallTimeMs,
        'origin_device_id': originDeviceId,
      };

  factory SyncEvent.fromJson(Map<String, dynamic> json) => SyncEvent(
        eventId: json['event_id'] as String,
        domain: json['domain'] as String,
        action: SyncEventAction.fromWire(json['action'] as String?),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        wallTimeMs: json['wall_time_ms'] as int,
        originDeviceId: json['origin_device_id'] as String? ?? '',
      );

  static SyncEvent messageEvent({
    required Map<String, dynamic> messageRow,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final updatedAt = messageRow['updated_at'] as String?;
    final createdAt = messageRow['created_at'] as String? ?? '';
    final timeStr = (updatedAt != null && updatedAt.isNotEmpty) ? updatedAt : createdAt;
    final wallTime = DateTime.tryParse(timeStr)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'msg:${messageRow['id']}',
      domain: 'message',
      action: action,
      payload: Map<String, dynamic>.from(messageRow),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent messageDeleteEvent({
    required String messageId,
    required String channelId,
    required String originDeviceId,
    int? wallTimeMs,
  }) {
    final ms = wallTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'msg:$messageId:del:$ms',
      domain: 'message',
      action: SyncEventAction.delete,
      payload: {'id': messageId, 'channel_id': channelId},
      wallTimeMs: ms,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent channelEvent({
    required Map<String, dynamic> channelRow,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final updatedAt = channelRow['updated_at'] as String? ?? channelRow['created_at'] as String? ?? '';
    final wallTime = DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'ch:${channelRow['id']}',
      domain: 'channel',
      action: action,
      payload: Map<String, dynamic>.from(channelRow),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent channelMemberEvent({
    required Map<String, dynamic> memberRow,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final updatedAt = memberRow['updated_at'] as String? ?? memberRow['joined_at'] as String? ?? '';
    final wallTime = DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    final channelId = memberRow['channel_id'] as String? ?? '';
    final agentId = memberRow['agent_id'] as String? ?? '';
    return SyncEvent(
      eventId: 'cm:$channelId:$agentId',
      domain: 'channel_member',
      action: action,
      payload: Map<String, dynamic>.from(memberRow),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent channelMemberDeleteEvent({
    required String channelId,
    required String agentId,
    required String originDeviceId,
    int? wallTimeMs,
  }) {
    final ms = wallTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'cm:$channelId:$agentId:del:$ms',
      domain: 'channel_member',
      action: SyncEventAction.delete,
      payload: {'channel_id': channelId, 'agent_id': agentId},
      wallTimeMs: ms,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent agentEvent({
    required Map<String, dynamic> agentRow,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final updatedAt = agentRow['updated_at'] as int? ?? agentRow['created_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'agent:${agentRow['id']}',
      domain: 'agent',
      action: action,
      payload: Map<String, dynamic>.from(agentRow),
      wallTimeMs: updatedAt,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent agentDeleteEvent({
    required String agentId,
    required String originDeviceId,
    int? wallTimeMs,
  }) {
    final ms = wallTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'agent:$agentId:del:$ms',
      domain: 'agent',
      action: SyncEventAction.delete,
      payload: {'id': agentId},
      wallTimeMs: ms,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent sheMemoryEvent({
    required Map<String, dynamic> row,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final key = row['key'] as String? ?? '';
    final wallTime = row['updated_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'sm:$key',
      domain: 'she_memory',
      action: action,
      payload: Map<String, dynamic>.from(row),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent sheMemoryDeleteEvent({
    required String key,
    required String originDeviceId,
    int? wallTimeMs,
  }) {
    final ms = wallTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'sm:$key:del:$ms',
      domain: 'she_memory',
      action: SyncEventAction.delete,
      payload: {'key': key},
      wallTimeMs: ms,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent cognitionSelfEvent({
    required Map<String, dynamic> row,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final agentId = row['agent_id'] as String? ?? '';
    final wallTime = row['updated_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'cog:self:$agentId',
      domain: 'cognition',
      action: action,
      payload: {
        ...Map<String, dynamic>.from(row),
        'kind': 'self',
      },
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent cognitionUserEvent({
    required Map<String, dynamic> row,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final agentId = row['agent_id'] as String? ?? '';
    final wallTime = row['last_updated'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'cog:user:$agentId',
      domain: 'cognition',
      action: action,
      payload: {
        ...Map<String, dynamic>.from(row),
        'kind': 'user',
      },
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent agentMemoryEvent({
    required Map<String, dynamic> row,
    required String originDeviceId,
    SyncEventAction action = SyncEventAction.upsert,
  }) {
    final syncKey = row['sync_key'] as String? ?? '';
    final wallTime = row['updated_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'am:$syncKey',
      domain: 'agent_memory',
      action: action,
      payload: Map<String, dynamic>.from(row),
      wallTimeMs: wallTime,
      originDeviceId: originDeviceId,
    );
  }

  static SyncEvent agentMemoryDeleteEvent({
    required String agentId,
    required String syncKey,
    required String originDeviceId,
    int? wallTimeMs,
  }) {
    final ms = wallTimeMs ?? DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'am:$syncKey:del:$ms',
      domain: 'agent_memory',
      action: SyncEventAction.delete,
      payload: {'agent_id': agentId, 'sync_key': syncKey},
      wallTimeMs: ms,
      originDeviceId: originDeviceId,
    );
  }

  /// Tombstone 表与 upsert 去重用的实体键（同 domain 内唯一）。
  static String? entityKeyForEvent(SyncEvent event) {
    switch (event.domain) {
      case 'message':
      case 'channel':
      case 'agent':
        return event.payload['id'] as String?;
      case 'channel_member':
        final channelId = event.payload['channel_id'] as String?;
        final agentId = event.payload['agent_id'] as String?;
        if (channelId == null || agentId == null) return null;
        return '$channelId:$agentId';
      case 'she_memory':
        return event.payload['key'] as String?;
      case 'cognition':
        final agentId = event.payload['agent_id'] as String?;
        if (agentId == null) return null;
        final kind = event.payload['kind'] as String? ?? 'self';
        return '$kind:$agentId';
      case 'agent_memory':
        return event.payload['sync_key'] as String?;
      default:
        return null;
    }
  }

  String toJsonString() => jsonEncode(toJson());

  factory SyncEvent.fromJsonString(String raw) =>
      SyncEvent.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
