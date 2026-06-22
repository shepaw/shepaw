import 'dart:convert';

import '../../services/agent_memory_db_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/minds_database_service.dart';
import '../../services/she_memory_db_service.dart';
import '../models/app_cache_policy.dart';
import '../models/sync_commit_result.dart';
import '../models/sync_domain_cursor.dart';
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
  static const _agentCursorKey = 'sync_cursor_agent_ms';
  static const _sheMemoryCursorKey = 'sync_cursor_she_memory_ms';
  static const _cognitionCursorKey = 'sync_cursor_cognition_ms';
  static const _agentMemoryCursorKey = 'sync_cursor_agent_memory_ms';

  final _db = LocalDatabaseService();
  final _log = LoggerService();
  final _sheMemoryDb = SheMemoryDbService.instance;
  final _mindsDb = MindsDatabaseService();

  Future<SyncDomainCursor> getDomainCursor(String domain) =>
      _getDomainCursor(_cursorKeyForDomain(domain));

  static String _cursorKeyForDomain(String domain) => switch (domain) {
        'message' => _messageCursorKey,
        'channel' => _channelCursorKey,
        'channel_member' => _memberCursorKey,
        'agent' => _agentCursorKey,
        'she_memory' => _sheMemoryCursorKey,
        'cognition' => _cognitionCursorKey,
        'agent_memory' => _agentMemoryCursorKey,
        _ => _messageCursorKey,
      };

  /// 过滤已 apply 的边界事件（同毫秒 tie-break）。
  List<SyncEvent> filterNewEvents(List<SyncEvent> events, SyncDomainCursor cursor) {
    return events.where((e) => SyncDomainCursor.isEventAfter(e, cursor)).toList();
  }

  Future<void> _setDomainCursor(String key, SyncDomainCursor cursor) =>
      _db.setIdentitySyncState(key, cursor.serialize());

  Future<SyncDomainCursor> _getDomainCursor(String key) async {
    final raw = await _db.getIdentitySyncState(key);
    if (raw != null && raw.isNotEmpty) {
      return SyncDomainCursor.parse(raw);
    }
    // 旧版单一游标仅迁移到 message 域，避免其他域跳过历史。
    if (key == _messageCursorKey) {
      final legacy = await _db.getIdentitySyncState(_legacyCursorKey);
      final ms = int.tryParse(legacy ?? '') ?? 0;
      if (ms > 0) return SyncDomainCursor(wallTimeMs: ms);
    }
    return SyncDomainCursor.zero;
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
    final upserts = rows
        .map((row) => SyncEvent.messageEvent(messageRow: row, originDeviceId: origin))
        .toList();
    var deletes = await _db.querySyncTombstonesSince(
      domain: 'message',
      sinceMs: sinceMs,
      limit: limit,
    );
    if (channelId != null) {
      deletes = deletes.where((e) => e.payload['channel_id'] == channelId).toList();
    }
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  /// Primary / Backup：查询 since 之后的频道事件。
  Future<List<SyncEvent>> queryChannelEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getChannelsUpdatedSince(sinceMs, limit: limit);
    final upserts = rows
        .map((row) => SyncEvent.channelEvent(channelRow: row, originDeviceId: origin))
        .toList();
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'channel',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  Future<List<SyncEvent>> queryChannelMemberEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getChannelMembersChangedSince(sinceMs, limit: limit);
    final upserts = rows
        .map((row) => SyncEvent.channelMemberEvent(memberRow: row, originDeviceId: origin))
        .toList();
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'channel_member',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  /// 应用频道成员事件批次。
  Future<SyncDomainCursor> applyMemberEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _memberCursorKey);

  /// 应用 Agent 事件批次。
  Future<SyncDomainCursor> applyAgentEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _agentCursorKey);

  /// Primary / Backup：查询 since 之后更新的 Agent。
  Future<List<SyncEvent>> queryAgentEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _db.getAgentsChangedSince(sinceMs: sinceMs, limit: limit);
    final upserts = rows.map((row) => SyncEvent.agentEvent(agentRow: row, originDeviceId: origin)).toList();
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'agent',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  Future<List<SyncEvent>> querySheMemoryEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await _sheMemoryDb.getChangedSince(sinceMs: sinceMs, limit: limit);
    final upserts = rows
        .map((row) => SyncEvent.sheMemoryEvent(row: row, originDeviceId: origin))
        .toList();
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'she_memory',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  Future<List<SyncEvent>> queryCognitionEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final selfRows = await _mindsDb.getSelfChangedSince(sinceMs: sinceMs, limit: limit);
    final userRows = await _mindsDb.getUserChangedSince(sinceMs: sinceMs, limit: limit);
    final upserts = <SyncEvent>[
      ...selfRows.map(
        (row) => SyncEvent.cognitionSelfEvent(row: row, originDeviceId: origin),
      ),
      ...userRows.map(
        (row) => SyncEvent.cognitionUserEvent(row: row, originDeviceId: origin),
      ),
    ]..sort((a, b) => a.wallTimeMs.compareTo(b.wallTimeMs));
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'cognition',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  /// 应用 She 记忆事件批次。
  Future<SyncDomainCursor> applySheMemoryEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _sheMemoryCursorKey);

  /// 应用认知事件批次。
  Future<SyncDomainCursor> applyCognitionEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _cognitionCursorKey);

  Future<List<SyncEvent>> queryAgentMemoryEvents({
    required int sinceMs,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    final rows = await AgentMemoryDbService.queryAllChangedSince(
      sinceMs: sinceMs,
      limit: limit,
    );
    final upserts = rows
        .map((row) => SyncEvent.agentMemoryEvent(row: row, originDeviceId: origin))
        .toList();
    final deletes = await _db.querySyncTombstonesSince(
      domain: 'agent_memory',
      sinceMs: sinceMs,
      limit: limit,
    );
    return _mergeEventsByWallTime(upserts: upserts, deletes: deletes, limit: limit);
  }

  /// 应用 Agent 结构化记忆事件批次。
  Future<SyncDomainCursor> applyAgentMemoryEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _agentMemoryCursorKey);

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
  Future<SyncDomainCursor> applyMessageEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _messageCursorKey);

  /// 应用频道事件批次。
  Future<SyncDomainCursor> applyChannelEvents(List<SyncEvent> events) =>
      _applyEvents(events, cursorKey: _channelCursorKey);

  Future<void> applyEvents(List<SyncEvent> events) async {
    final messages = events.where((e) => e.domain == 'message').toList();
    final channels = events.where((e) => e.domain == 'channel').toList();
    final members = events.where((e) => e.domain == 'channel_member').toList();
    final agents = events.where((e) => e.domain == 'agent').toList();
    final sheMemory = events.where((e) => e.domain == 'she_memory').toList();
    final cognition = events.where((e) => e.domain == 'cognition').toList();
    final agentMemory = events.where((e) => e.domain == 'agent_memory').toList();
    if (messages.isNotEmpty) await applyMessageEvents(messages);
    if (channels.isNotEmpty) await applyChannelEvents(channels);
    if (members.isNotEmpty) await applyMemberEvents(members);
    if (agents.isNotEmpty) await applyAgentEvents(agents);
    if (sheMemory.isNotEmpty) await applySheMemoryEvents(sheMemory);
    if (cognition.isNotEmpty) await applyCognitionEvents(cognition);
    if (agentMemory.isNotEmpty) await applyAgentMemoryEvents(agentMemory);
  }

  Future<SyncDomainCursor> _applyEvents(
    List<SyncEvent> events, {
    required String cursorKey,
  }) async {
    final cursor = await _getDomainCursor(cursorKey);
    if (events.isEmpty) return cursor;

    final role = await AccountIdentityService.instance.localDeviceRole();
    var next = cursor;

    for (final event in events) {
      try {
        await _applyOne(event, role);
        next = next.advance(event);
      } catch (e) {
        _log.warning('Failed to apply sync event ${event.eventId}: $e', tag: _tag);
        break;
      }
    }

    await _setDomainCursor(cursorKey, next);
    return next;
  }

  Future<void> _applyOne(SyncEvent event, DeviceRole role) async {
    if (event.action == SyncEventAction.delete) {
      await _applyDelete(event, role);
      await _recordTombstoneIfStorage(event, role);
      return;
    }
    await _clearTombstoneForUpsert(event);
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
      case 'agent':
        await _applyAgent(event, role);
        break;
      case 'she_memory':
        await _applySheMemory(event, role);
        break;
      case 'cognition':
        await _applyCognition(event, role);
        break;
      case 'agent_memory':
        await _applyAgentMemory(event, role);
        break;
    }
  }

  Future<void> _applyAgentMemory(SyncEvent event, DeviceRole role) async {
    final agentId = event.payload['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return;
    await AgentMemoryDbService.forAgent(agentId).upsertFromSync(event.payload);
  }

  Future<void> _applySheMemory(SyncEvent event, DeviceRole role) async {
    await _sheMemoryDb.upsertFromSync(event.payload);
  }

  Future<void> _applyCognition(SyncEvent event, DeviceRole role) async {
    final kind = event.payload['kind'] as String? ?? 'self';
    if (kind == 'user') {
      await _mindsDb.upsertUserFromSync(event.payload);
    } else {
      await _mindsDb.upsertSelfFromSync(event.payload);
    }
  }

  Future<void> _applyAgent(SyncEvent event, DeviceRole role) async {
    await _db.upsertAgentFromSync(event.payload);
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
      case 'channel':
        final id = event.payload['id'] as String?;
        if (id == null) return;
        await _db.deleteChannelFromSync(id);
        break;
      case 'channel_member':
        final channelId = event.payload['channel_id'] as String?;
        final agentId = event.payload['agent_id'] as String?;
        if (channelId == null || agentId == null) return;
        await _db.removeChannelMemberFromSync(channelId, agentId);
        break;
      case 'agent':
        final id = event.payload['id'] as String?;
        if (id == null) return;
        await _db.deleteAgentFromSync(id);
        break;
      case 'she_memory':
        final key = event.payload['key'] as String?;
        if (key == null) return;
        await _sheMemoryDb.deleteFromSync(key);
        break;
      case 'agent_memory':
        final agentId = event.payload['agent_id'] as String?;
        final syncKey = event.payload['sync_key'] as String?;
        if (agentId == null || syncKey == null) return;
        await AgentMemoryDbService.forAgent(agentId).deleteFromSync(syncKey);
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
  Future<SyncCommitResult> commitEvent(SyncEvent event) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) return SyncCommitResult.failed;

    if (event.action == SyncEventAction.delete) {
      await _applyOne(event, DeviceRole.primary);
      return SyncCommitResult.appliedOk();
    }

    if (event.domain == 'message') {
      final id = event.payload['id'] as String? ?? '';
      final existing = await _db.getMessageById(id, fetchRemote: false);
      if (existing != null) {
        final existingUpdated = existing['updated_at'] as String? ?? existing['created_at'] as String? ?? '';
        final existingMs = DateTime.tryParse(existingUpdated)?.millisecondsSinceEpoch ?? 0;
        if (event.wallTimeMs < existingMs) return SyncCommitResult.staleOk();
      }
    }

    if (event.domain == 'agent') {
      final id = event.payload['id'] as String? ?? '';
      final existing = await _db.getAgentRowById(id);
      if (existing != null) {
        final existingMs = existing['updated_at'] as int? ?? existing['created_at'] as int? ?? 0;
        if (event.wallTimeMs < existingMs) return SyncCommitResult.staleOk();
      }
    }

    if (event.domain == 'she_memory') {
      final key = event.payload['key'] as String? ?? '';
      final existing = await _sheMemoryDb.getRowByKey(key);
      if (existing != null) {
        final existingMs = existing['updated_at'] as int? ?? 0;
        if (event.wallTimeMs < existingMs) return SyncCommitResult.staleOk();
      }
    }

    if (event.domain == 'cognition') {
      final kind = event.payload['kind'] as String? ?? 'self';
      final agentId = event.payload['agent_id'] as String? ?? '';
      if (kind == 'user') {
        final existing = await _mindsDb.getUserCognition(agentId);
        if (existing != null && event.wallTimeMs < existing.lastUpdated) {
          return SyncCommitResult.staleOk();
        }
      } else {
        final existing = await _mindsDb.getSelfCognition(agentId);
        if (existing != null && event.wallTimeMs < existing.updatedAt) {
          return SyncCommitResult.staleOk();
        }
      }
    }

    if (event.domain == 'agent_memory') {
      final agentId = event.payload['agent_id'] as String? ?? '';
      final syncKey = event.payload['sync_key'] as String? ?? '';
      if (agentId.isNotEmpty && syncKey.isNotEmpty) {
        final existing = await AgentMemoryDbService.forAgent(agentId).getRowBySyncKey(syncKey);
        if (existing != null) {
          final existingMs = existing['updated_at'] as int? ?? 0;
          if (event.wallTimeMs < existingMs) return SyncCommitResult.staleOk();
        }
      }
    }

    await _applyOne(event, DeviceRole.primary);
    return SyncCommitResult.appliedOk();
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

  List<SyncEvent> _mergeEventsByWallTime({
    required List<SyncEvent> upserts,
    required List<SyncEvent> deletes,
    required int limit,
  }) {
    final all = [...upserts, ...deletes]
      ..sort((a, b) => a.wallTimeMs.compareTo(b.wallTimeMs));
    if (all.length > limit) return all.sublist(0, limit);
    return all;
  }

  Future<void> _recordTombstoneIfStorage(SyncEvent event, DeviceRole role) async {
    if (event.action != SyncEventAction.delete) return;
    if (role != DeviceRole.primary && role != DeviceRole.backup) return;
    await _db.recordSyncTombstone(event);
  }

  Future<void> _clearTombstoneForUpsert(SyncEvent event) async {
    final entityKey = SyncEvent.entityKeyForEvent(event);
    if (entityKey == null || entityKey.isEmpty) return;
    await _db.clearSyncTombstone(event.domain, entityKey);
  }

  Future<void> _trimAppCache(AppCachePolicy policy) async {
    await _db.trimMessagesToPolicy(policy.maxMessages, policy.maxDays);
  }
}
