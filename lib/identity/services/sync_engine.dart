import 'dart:convert';

import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/app_cache_policy.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';

/// 同步事件构建与应用（Primary / Backup 全量，App 索引+缓存）。
class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  static const _tag = 'SyncEngine';
  static const _cursorKey = 'sync_cursor_ms';

  final _db = LocalDatabaseService();
  final _log = LoggerService();

  Future<int> getLocalCursorMs() async {
    final raw = await _db.getIdentitySyncState(_cursorKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setLocalCursorMs(int ms) async {
    await _db.setIdentitySyncState(_cursorKey, ms.toString());
  }

  /// Primary / Backup：查询 since 之后的 messages + channels。
  Future<List<SyncEvent>> queryEvents({
    required int sinceMs,
    String? channelId,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final events = <SyncEvent>[];

    final channels = await _db.getChannelsUpdatedSince(sinceMs, limit: limit);
    for (final row in channels) {
      events.add(SyncEvent.channelEvent(channelRow: row, originDeviceId: origin));
    }

    final messages = await _db.getMessagesCreatedSince(
      sinceMs: sinceMs,
      channelId: channelId,
      limit: limit,
    );
    for (final row in messages) {
      events.add(SyncEvent.messageEvent(messageRow: row, originDeviceId: origin));
    }

    events.sort((a, b) => a.wallTimeMs.compareTo(b.wallTimeMs));
    if (events.length > limit) {
      return events.sublist(0, limit);
    }
    return events;
  }

  /// 应用远端事件批次；返回成功应用的最大 wallTimeMs。
  Future<int> applyEvents(List<SyncEvent> events) async {
    if (events.isEmpty) return await getLocalCursorMs();

    final role = await AccountIdentityService.instance.localDeviceRole();
    var maxMs = await getLocalCursorMs();

    for (final event in events) {
      try {
        await _applyOne(event, role);
        if (event.wallTimeMs > maxMs) maxMs = event.wallTimeMs;
      } catch (e) {
        _log.warning('Failed to apply sync event ${event.eventId}: $e', tag: _tag);
      }
    }

    await setLocalCursorMs(maxMs);
    return maxMs;
  }

  Future<void> _applyOne(SyncEvent event, DeviceRole role) async {
    switch (event.domain) {
      case 'message':
        await _applyMessage(event, role);
        break;
      case 'channel':
        await _applyChannel(event, role);
        break;
    }
  }

  Future<void> _applyMessage(SyncEvent event, DeviceRole role) async {
    final row = event.payload;
    final id = row['id'] as String?;
    if (id == null) return;

    final preview = _messagePreview(row);
    final wallTime = event.wallTimeMs;
    final hasAttachment = _hasAttachment(row);

    await _db.upsertMessageIndex(
      messageId: id,
      channelId: row['channel_id'] as String? ?? '',
      wallTime: wallTime,
      preview: preview,
      senderName: row['sender_name'] as String? ?? '',
      hasAttachment: hasAttachment,
    );

    if (role == DeviceRole.app) {
      final policy = await _db.getAppCachePolicy();
      final existing = await _db.getMessageById(id);
      if (existing == null && await _shouldCacheMessage(policy, wallTime)) {
        await _db.upsertMessageFromSync(row);
      } else if (existing != null) {
        await _db.upsertMessageFromSync(row);
      }
      await _trimAppCache(policy);
    } else {
      await _db.upsertMessageFromSync(row);
    }
  }

  Future<void> _applyChannel(SyncEvent event, DeviceRole role) async {
    if (role == DeviceRole.app) {
      // App 设备仅同步 channel 元数据（轻量）。
      await _db.upsertChannelFromSync(event.payload);
      return;
    }
    await _db.upsertChannelFromSync(event.payload);
  }

  /// Primary：持久化来自 App 的 commit。
  Future<bool> commitEvent(SyncEvent event) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) return false;

    final existingMsg = event.domain == 'message'
        ? await _db.getMessageById(event.payload['id'] as String? ?? '')
        : null;
    if (existingMsg != null) return true;

    await _applyOne(event, DeviceRole.primary);
    return true;
  }

  String _messagePreview(Map<String, dynamic> row) {
    final content = row['content'] as String? ?? '';
    if (content.length <= 120) return content;
    return '${content.substring(0, 117)}...';
  }

  bool _hasAttachment(Map<String, dynamic> row) {
    final type = row['message_type'] as String? ?? 'text';
    if (type != 'text') return true;
    final meta = row['metadata'] as String?;
    if (meta == null || meta.isEmpty) return false;
    try {
      final m = jsonDecode(meta) as Map<String, dynamic>;
      return m.containsKey('attachments') || m.containsKey('attachment');
    } catch (_) {
      return false;
    }
  }

  Future<bool> _shouldCacheMessage(AppCachePolicy policy, int wallTimeMs) async {
    final age = DateTime.now().millisecondsSinceEpoch - wallTimeMs;
    if (age > policy.maxDays * 86400000) return false;
    final count = await _db.countCachedMessages();
    return count < policy.maxMessages;
  }

  Future<void> _trimAppCache(AppCachePolicy policy) async {
    await _db.trimMessagesToPolicy(policy.maxMessages, policy.maxDays);
  }
}
