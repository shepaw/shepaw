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
  static const _legacyCursorKey = 'sync_cursor_ms';
  static const _messageCursorKey = 'sync_cursor_msg_ms';
  static const _channelCursorKey = 'sync_cursor_ch_ms';
  static const _memberCursorKey = 'sync_cursor_member_ms';

  final _db = LocalDatabaseService();
  final _log = LoggerService();

  Future<int> getMessageCursorMs() => _getCursor(_messageCursorKey);

  Future<int> getChannelCursorMs() => _getCursor(_channelCursorKey);

  Future<int> getMemberCursorMs() => _getCursor(_memberCursorKey);

  Future<void> setMessageCursorMs(int ms) => _db.setIdentitySyncState(_messageCursorKey, ms.toString());

  Future<void> setChannelCursorMs(int ms) => _db.setIdentitySyncState(_channelCursorKey, ms.toString());

  Future<void> setMemberCursorMs(int ms) => _db.setIdentitySyncState(_memberCursorKey, ms.toString());

  Future<int> _getCursor(String key) async {
    final raw = await _db.getIdentitySyncState(key);
    if (raw != null && raw.isNotEmpty) {
      return int.tryParse(raw) ?? 0;
    }
    // 迁移旧版单一游标。
    if (key == _messageCursorKey || key == _channelCursorKey || key == _memberCursorKey) {
      final legacy = await _db.getIdentitySyncState(_legacyCursorKey);
      return int.tryParse(legacy ?? '') ?? 0;
    }
    return 0;
  }

  /// Primary / Backup：查询 since 之后的消息事件。
  Future<List<SyncEvent>> queryMessageEvents({
    required int sinceMs,
    String? channelId,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getMessagesChangedSince(
      sinceMs: sinceMs,
      channelId: channelId,
      limit: limit,
    );
    return rows
        .map((row) => SyncEvent.messageEvent(messageRow: row, originDeviceId: origin))
        .toList();
  }

  /// Primary / Backup：查询 since 之后的频道事件。
  Future<List<SyncEvent>> queryChannelEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getChannelsUpdatedSince(sinceMs, limit: limit);
    return rows
        .map((row) => SyncEvent.channelEvent(channelRow: row, originDeviceId: origin))
        .toList();
  }

  Future<List<SyncEvent>> queryChannelMemberEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getChannelMembersChangedSince(sinceMs, limit: limit);
    return rows
        .map((row) => SyncEvent.channelMemberEvent(memberRow: row, originDeviceId: origin))
        .toList();
  }

  /// 应用频道成员事件批次。
  Future<int> applyMemberEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorSetter: setMemberCursorMs, cursorGetter: getMemberCursorMs);

  /// 兼容旧调用：按域分别查询后合并（仅测试/legacy）。
  Future<List<SyncEvent>> queryEvents({
    required int sinceMs,
    String? channelId,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final messages = await queryMessageEvents(
      sinceMs: sinceMs,
      channelId: channelId,
      limit: limit,
      originDeviceId: originDeviceId,
    );
    final channels = await queryChannelEvents(
      sinceMs: sinceMs,
      limit: limit,
      originDeviceId: originDeviceId,
    );
    final events = [...messages, ...channels]..sort((a, b) => a.wallTimeMs.compareTo(b.wallTimeMs));
    if (events.length > limit) return events.sublist(0, limit);
    return events;
  }

  /// 应用消息事件批次；遇失败停止，不跳过中间条目。
  Future<int> applyMessageEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorSetter: setMessageCursorMs, cursorGetter: getMessageCursorMs);

  /// 应用频道事件批次。
  Future<int> applyChannelEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorSetter: setChannelCursorMs, cursorGetter: getChannelCursorMs);

  Future<int> applyEvents(List<SyncEvent> events) async {
    final messages = events.where((e) => e.domain == 'message').toList();
    final channels = events.where((e) => e.domain == 'channel').toList();
    final members = events.where((e) => e.domain == 'channel_member').toList();
    var cursor = await getMessageCursorMs();
    if (messages.isNotEmpty) {
      cursor = await applyMessageEvents(messages);
    }
    if (channels.isNotEmpty) {
      await applyChannelEvents(channels);
    }
    if (members.isNotEmpty) {
      await applyMemberEvents(members);
    }
    return cursor;
  }

  Future<int> _applyEvents(
    List<SyncEvent> events, {
    required Future<void> Function(int ms) cursorSetter,
    required Future<int> Function() cursorGetter,
  }) async {
    if (events.isEmpty) return cursorGetter();

    final role = await AccountIdentityService.instance.localDeviceRole();
    var maxMs = await cursorGetter();

    for (final event in events) {
      try {
        await _applyOne(event, role);
        if (event.wallTimeMs > maxMs) maxMs = event.wallTimeMs;
      } catch (e) {
        _log.warning('Failed to apply sync event ${event.eventId}: $e', tag: _tag);
        break;
      }
    }

    await cursorSetter(maxMs);
    return maxMs;
  }

  Future<void> _applyOne(SyncEvent event, DeviceRole role) async {
    if (event.action == SyncEventAction.delete) {
      await _applyDelete(event, role);
      return;
    }
    switch (event.domain) {
      case 'message':
        await _applyMessage(event, role);
        break;
      case 'channel':
        await _applyChannel(event, role);
        break;
      case 'channel_member':
        await _applyChannelMember(event, role);
        break;
    }
  }

  Future<void> _applyChannelMember(SyncEvent event, DeviceRole role) async {
    await _db.upsertChannelMemberFromSync(event.payload);
  }

  Future<void> _applyDelete(SyncEvent event, DeviceRole role) async {
    switch (event.domain) {
      case 'message':
        final id = event.payload['id'] as String?;
        if (id == null) return;
        await _db.deleteMessageFromSync(id);
        await _db.deleteMessageIndex(id);
        break;
      case 'channel_member':
        final channelId = event.payload['channel_id'] as String?;
        final agentId = event.payload['agent_id'] as String?;
        if (channelId == null || agentId == null) return;
        await _db.removeChannelMemberFromSync(channelId, agentId);
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
    await _db.upsertChannelFromSync(event.payload);
  }

  /// Primary：持久化来自 App 的 commit（含更新与删除）。
  Future<bool> commitEvent(SyncEvent event) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) return false;

    if (event.action == SyncEventAction.delete) {
      await _applyDelete(event, DeviceRole.primary);
      return true;
    }

    if (event.domain == 'message') {
      final id = event.payload['id'] as String? ?? '';
      final existing = await _db.getMessageById(id);
      if (existing != null) {
        final existingUpdated = existing['updated_at'] as String? ?? existing['created_at'] as String? ?? '';
        final existingMs = DateTime.tryParse(existingUpdated)?.millisecondsSinceEpoch ?? 0;
        if (event.wallTimeMs < existingMs) return true;
      }
    }

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
