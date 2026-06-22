import 'dart:async';
import 'dart:convert';

import '../../services/local_database_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'sync_fanout_service.dart';

/// 本地 DB 写入后触发同步（App → outbound 队列，Primary → fan-out push）。
class SyncLocalWriteHook {
  SyncLocalWriteHook._();

  static const _streamingDebounceDuration = Duration(seconds: 2);
  static final _streamingDebounceTimers = <String, Timer>{};

  /// 流式 flush 防抖，避免高频 outbound；完成/中断前应调用 [flushStreamingMessageSync]。
  static void onStreamingMessageUpdated({
    required String messageId,
    required String channelId,
    required String content,
    String? metadata,
    required String updatedAt,
  }) {
    _streamingDebounceTimers[messageId]?.cancel();
    _streamingDebounceTimers[messageId] = Timer(_streamingDebounceDuration, () {
      unawaited(onMessageUpdated(
        messageId: messageId,
        channelId: channelId,
        content: content,
        metadata: metadata,
        updatedAt: updatedAt,
      ));
      _streamingDebounceTimers.remove(messageId);
    });
  }

  static void flushStreamingMessageSync({
    required String messageId,
    required String channelId,
    required String content,
    String? metadata,
    required String updatedAt,
  }) {
    _streamingDebounceTimers.remove(messageId)?.cancel();
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
      enqueueBlob: true,
    );
  }

  static Future<void> onMessageUpdated({
    required String messageId,
    required String channelId,
    required String content,
    String? metadata,
    required String updatedAt,
  }) async {
    final existing = await LocalDatabaseService().getMessageById(messageId, fetchRemote: false);
    if (existing == null) return;

    await _dispatchMessageRow(
      {
        ...existing,
        'content': content,
        if (metadata != null) 'metadata': metadata,
        'updated_at': updatedAt,
      },
      enqueueBlob: metadata != null,
    );
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
    } catch (_) {}
  }

  static Future<void> _dispatchMessageRow(
    Map<String, dynamic> row, {
    required bool enqueueBlob,
  }) async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';
      final event = SyncEvent.messageEvent(messageRow: row, originDeviceId: origin);
      final db = LocalDatabaseService();

      if (_usesOutboundQueue(role)) {
        await db.enqueueOutboundEvent(
          id: event.eventId,
          domain: event.domain,
          payloadJson: event.toJsonString(),
        );
        if (enqueueBlob) {
          await _maybeEnqueueBlob(db, row);
        }
      } else if (role == DeviceRole.primary) {
        await SyncFanoutService.fanout(event);
      }
    } catch (_) {}
  }

  static Future<void> _maybeEnqueueBlob(LocalDatabaseService db, Map<String, dynamic> row) async {
    final path = _attachmentPathFromRow(row);
    if (path != null) {
      await db.enqueueBlobOutbound(relativePath: path);
    }
  }

  static Future<void> onChannelMemberUpserted(Map<String, dynamic> memberRow) async {
    try {
      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';
      final event = SyncEvent.channelMemberEvent(memberRow: memberRow, originDeviceId: origin);
      await _dispatchEvent(event);
    } catch (_) {}
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

  static Future<void> _dispatchEvent(SyncEvent event) async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (event.action == SyncEventAction.delete &&
          (role == DeviceRole.primary || role == DeviceRole.backup)) {
        await LocalDatabaseService().recordSyncTombstone(event);
      }
      if (_usesOutboundQueue(role)) {
        final db = LocalDatabaseService();
        await db.enqueueOutboundEvent(
          id: event.eventId,
          domain: event.domain,
          payloadJson: event.toJsonString(),
        );
      } else if (role == DeviceRole.primary) {
        await SyncFanoutService.fanout(event);
      }
    } catch (_) {}
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
