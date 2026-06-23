import 'dart:async';
import 'dart:convert';

import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'sync_engine.dart';
import 'sync_fanout_service.dart';

/// 本地 DB 写入后触发同步（App → outbound 队列，Primary → fan-out push）。
class SyncLocalWriteHook {
  SyncLocalWriteHook._();

  static const _tag = 'SyncLocalWriteHook';
  static final _log = LoggerService();

  static const _readDebounceDuration = Duration(seconds: 3);
  static const _heartbeatDebounceDuration = Duration(seconds: 60);
  static const _statusDebounceDuration = Duration(seconds: 5);
  static final _readDebounceTimers = <String, Timer>{};
  static final _pendingReadRows = <String, Map<String, dynamic>>{};
  static final _heartbeatDebounceTimers = <String, Timer>{};
  static final _statusDebounceTimers = <String, Timer>{};

  /// App 进入后台前立即 flush 防抖中的同步事件。
  static Future<void> flushAllPendingDebouncedSync() async {
    for (final timer in _readDebounceTimers.values) {
      timer.cancel();
    }
    _readDebounceTimers.clear();
    final reads = Map<String, Map<String, dynamic>>.from(_pendingReadRows);
    _pendingReadRows.clear();
    for (final row in reads.values) {
      await _dispatchMessageRow(Map<String, dynamic>.from(row));
    }

    for (final timer in _heartbeatDebounceTimers.values) {
      timer.cancel();
    }
    final heartbeatAgents = _heartbeatDebounceTimers.keys.toList();
    _heartbeatDebounceTimers.clear();
    for (final agentId in heartbeatAgents) {
      final row = await LocalDatabaseService().getAgentRowById(agentId);
      if (row != null) await onAgentUpserted(row);
    }

    for (final timer in _statusDebounceTimers.values) {
      timer.cancel();
    }
    final statusAgents = _statusDebounceTimers.keys.toList();
    _statusDebounceTimers.clear();
    for (final agentId in statusAgents) {
      final row = await LocalDatabaseService().getAgentRowById(agentId);
      if (row != null) await onAgentUpserted(row);
    }
  }

  /// 流式消息完成或中断时同步最终态（中间 flush 不同步到其他设备）。
  static void flushStreamingMessageSync({
    required String messageId,
    required String channelId,
    required String content,
    String? metadata,
    required String updatedAt,
  }) {
    unawaited(onMessageUpdated(
      messageId: messageId,
      channelId: channelId,
      content: content,
      metadata: metadata,
      updatedAt: updatedAt,
    ));
  }

  static Future<void> onMessageCreated({
    required String id,
    required String channelId,
    required String senderId,
    required String senderType,
    required String senderName,
    required String content,
    String messageType = 'text',
    String? metadata,
    String? replyToId,
    required String createdAt,
    String? updatedAt,
  }) async {
    await _dispatchMessageRow(
      {
        'id': id,
        'channel_id': channelId,
        'sender_id': senderId,
        'sender_type': senderType,
        'sender_name': senderName,
        'content': content,
        'message_type': messageType,
        'metadata': metadata,
        'reply_to_id': replyToId,
        'created_at': createdAt,
        'updated_at': updatedAt ?? createdAt,
        'is_read': 0,
      },
    );
  }

  static Future<void> onMessageUpdated({
    required String messageId,
    required String channelId,
    required String content,
    String? metadata,
    required String updatedAt,
    int? isRead,
  }) async {
    final existing = await LocalDatabaseService().getMessageById(messageId, fetchRemote: false);
    if (existing == null) return;

    await _dispatchMessageRow(
      {
        ...existing,
        'content': content,
        if (metadata != null) 'metadata': metadata,
        if (isRead != null) 'is_read': isRead,
        'updated_at': updatedAt,
      },
    );
  }

  /// 已读/未读状态变更（按 channel 防抖批量同步，支持双向 is_read）。
  static void onMessageReadStateChanged({
    required Map<String, dynamic> messageRow,
    required String updatedAt,
    required int isRead,
  }) {
    final channelId = messageRow['channel_id'] as String? ?? '';
    final messageId = messageRow['id'] as String?;
    if (channelId.isEmpty || messageId == null) return;

    _pendingReadRows[messageId] = {
      ...messageRow,
      'is_read': isRead,
      'updated_at': updatedAt,
    };
    _readDebounceTimers[channelId]?.cancel();
    _readDebounceTimers[channelId] = Timer(_readDebounceDuration, () {
      final pending = _pendingReadRows.entries
          .where((e) => e.value['channel_id'] == channelId)
          .toList();
      for (final entry in pending) {
        unawaited(_dispatchMessageRow(
          Map<String, dynamic>.from(entry.value),
        ));
        _pendingReadRows.remove(entry.key);
      }
      _readDebounceTimers.remove(channelId);
    });
  }

  /// Agent 心跳（60s 防抖同步 last_heartbeat）。
  static void onAgentHeartbeatDebounced(String agentId) {
    if (agentId.isEmpty) return;
    _heartbeatDebounceTimers[agentId]?.cancel();
    _heartbeatDebounceTimers[agentId] = Timer(_heartbeatDebounceDuration, () async {
      final row = await LocalDatabaseService().getAgentRowById(agentId);
      if (row != null) await onAgentUpserted(row);
      _heartbeatDebounceTimers.remove(agentId);
    });
  }

  /// Agent 在线状态（5s 防抖，避免健康检查频繁 outbound）。
  static void onAgentStatusDebounced(String agentId) {
    if (agentId.isEmpty) return;
    _statusDebounceTimers[agentId]?.cancel();
    _statusDebounceTimers[agentId] = Timer(_statusDebounceDuration, () async {
      final row = await LocalDatabaseService().getAgentRowById(agentId);
      if (row != null) await onAgentUpserted(row);
      _statusDebounceTimers.remove(agentId);
    });
  }

  static Future<void> onMessageDeleted({
    required String messageId,
    required String channelId,
  }) async {
    await _dispatchEvent(
      SyncEvent.messageDeleteEvent(
        messageId: messageId,
        channelId: channelId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onChannelUpserted(Map<String, dynamic> channelRow) async {
    try {
      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';
      final event = SyncEvent.channelEvent(channelRow: channelRow, originDeviceId: origin);
      await _dispatchEvent(event);
    } catch (e) {
      _log.warning('onChannelUpserted sync hook failed: $e', tag: _tag, error: e);
    }
  }

  static Future<void> _dispatchMessageRow(Map<String, dynamic> row) async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';
      final event = SyncEvent.messageEvent(messageRow: row, originDeviceId: origin);
      final db = LocalDatabaseService();

      if (await _shouldUseOutboundQueue(role)) {
        await db.enqueueOutboundEvent(
          id: event.eventId,
          domain: event.domain,
          payloadJson: event.toJsonString(),
        );
      } else if (await _shouldFanoutAsPrimary(role)) {
        await SyncEngine.instance.recordEntitySyncState(event);
        await SyncFanoutService.fanout(event);
      }
    } catch (e) {
      _log.warning('_dispatchMessageRow sync hook failed: $e', tag: _tag, error: e);
    }
  }

  static Future<void> onChannelMemberUpserted(Map<String, dynamic> memberRow) async {
    try {
      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';
      final event = SyncEvent.channelMemberEvent(memberRow: memberRow, originDeviceId: origin);
      await _dispatchEvent(event);
    } catch (e) {
      _log.warning('onChannelMemberUpserted sync hook failed: $e', tag: _tag, error: e);
    }
  }

  static Future<void> onChannelMemberRemoved({
    required String channelId,
    required String agentId,
  }) async {
    await _dispatchEvent(
      SyncEvent.channelMemberDeleteEvent(
        channelId: channelId,
        agentId: agentId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onAgentUpserted(Map<String, dynamic> agentRow) async {
    await _dispatchEvent(
      SyncEvent.agentEvent(
        agentRow: agentRow,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onAgentDeleted(String agentId) async {
    await _dispatchEvent(
      SyncEvent.agentDeleteEvent(
        agentId: agentId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onSheMemoryUpserted(Map<String, dynamic> row) async {
    await _dispatchEvent(
      SyncEvent.sheMemoryEvent(
        row: row,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onSheMemoryDeleted({required String key}) async {
    await _dispatchEvent(
      SyncEvent.sheMemoryDeleteEvent(
        key: key,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onCognitionSelfUpserted(Map<String, dynamic> row) async {
    await _dispatchEvent(
      SyncEvent.cognitionSelfEvent(
        row: row,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onCognitionUserUpserted(Map<String, dynamic> row) async {
    await _dispatchEvent(
      SyncEvent.cognitionUserEvent(
        row: row,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onCognitionSelfDeleted({required String agentId}) async {
    await _dispatchEvent(
      SyncEvent.cognitionSelfDeleteEvent(
        agentId: agentId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onCognitionUserDeleted({required String agentId}) async {
    await _dispatchEvent(
      SyncEvent.cognitionUserDeleteEvent(
        agentId: agentId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onChannelDeleted({required String channelId}) async {
    await _dispatchEvent(
      SyncEvent.channelDeleteEvent(
        channelId: channelId,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onAgentMemoryUpserted(Map<String, dynamic> row) async {
    await _dispatchEvent(
      SyncEvent.agentMemoryEvent(
        row: row,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<void> onAgentMemoryDeleted({
    required String agentId,
    required String syncKey,
  }) async {
    await _dispatchEvent(
      SyncEvent.agentMemoryDeleteEvent(
        agentId: agentId,
        syncKey: syncKey,
        originDeviceId: await _originDeviceId(),
      ),
    );
  }

  static Future<String> _originDeviceId() async {
    final local = await AccountIdentityService.instance.localDevice();
    return local?.deviceId ?? 'local';
  }

  static bool _usesOutboundQueue(DeviceRole role) =>
      role == DeviceRole.app || role == DeviceRole.backup;

  static Future<bool> _shouldUseOutboundQueue(DeviceRole role) async {
    if (_usesOutboundQueue(role)) return true;
    if (role == DeviceRole.primary) {
      return !await AccountIdentityService.instance.isCanonicalPrimary();
    }
    return false;
  }

  static Future<bool> _shouldRecordTombstone(DeviceRole role) async {
    if (role == DeviceRole.backup) return true;
    if (role == DeviceRole.primary) {
      return AccountIdentityService.instance.isCanonicalPrimary();
    }
    return false;
  }

  static Future<bool> _shouldFanoutAsPrimary(DeviceRole role) async {
    return role == DeviceRole.primary &&
        await AccountIdentityService.instance.isCanonicalPrimary();
  }

  static Future<void> _dispatchEvent(SyncEvent event) async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (event.action == SyncEventAction.delete &&
          await _shouldRecordTombstone(role)) {
        await LocalDatabaseService().recordSyncTombstone(event);
      }
      if (await _shouldUseOutboundQueue(role)) {
        final db = LocalDatabaseService();
        await db.enqueueOutboundEvent(
          id: event.eventId,
          domain: event.domain,
          payloadJson: event.toJsonString(),
        );
      } else if (await _shouldFanoutAsPrimary(role)) {
        await SyncEngine.instance.recordEntitySyncState(event);
        await SyncFanoutService.fanout(event);
      }
    } catch (e) {
      _log.warning('_dispatchEvent sync hook failed: $e', tag: _tag, error: e);
    }
  }

  static String? attachmentPathFromEventJson(Map<String, dynamic> eventJson) {
    if (eventJson['domain'] != 'message') return null;
    final payload = eventJson['payload'];
    if (payload is! Map) return null;
    return _attachmentPathFromRow(Map<String, dynamic>.from(payload));
  }

  static String? _attachmentPathFromRow(Map<String, dynamic> row) {
    final metaRaw = row['metadata'];
    Map<String, dynamic>? meta;
    if (metaRaw is String && metaRaw.isNotEmpty) {
      try {
        meta = Map<String, dynamic>.from(jsonDecode(metaRaw) as Map);
      } catch (_) {
        return null;
      }
    }
    final path = meta?['path'] as String?;
    if (path != null && path.isNotEmpty) return path;
    return null;
  }
}
