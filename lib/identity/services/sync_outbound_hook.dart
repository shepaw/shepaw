import 'dart:async';

import '../../services/local_database_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';

/// App 设备本地写入消息后，入队等待 sync_commit 到 Primary。
class SyncOutboundHook {
  SyncOutboundHook._();

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
  }) async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.app) return;

      final local = await AccountIdentityService.instance.localDevice();
      final origin = local?.deviceId ?? 'local';

      final row = {
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
        'is_read': 0,
      };

      final event = SyncEvent.messageEvent(messageRow: row, originDeviceId: origin);
      final db = LocalDatabaseService();
      await db.enqueueOutboundEvent(
        id: event.eventId,
        domain: event.domain,
        payloadJson: event.toJsonString(),
      );
    } catch (_) {
      // 不阻塞消息写入
    }
  }
}
