import 'dart:convert';

import '../../services/agent_memory_db_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../services/minds_database_service.dart';
import '../../services/she_memory_db_service.dart';
import '../models/app_cache_policy.dart';
import '../models/device_role.dart';
import '../models/sync_apply_outcome.dart';
import '../models/sync_commit_result.dart';
import '../models/sync_domain_cursor.dart';
import '../utils/sync_lww.dart';
import '../utils/app_cache_utils.dart';
import '../utils/sync_tombstone_utils.dart';
import '../models/sync_push_apply_result.dart';
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

  static const syncDomains = [
    'message',
    'channel',
    'channel_member',
    'agent',
    'she_memory',
    'cognition',
    'agent_memory',
  ];

  final _db = LocalDatabaseService();
  final _log = LoggerService();
  final _sheMemoryDb = SheMemoryDbService.instance;
  final _mindsDb = MindsDatabaseService();

  Future<SyncDomainCursor> getDomainCursor(String domain) =>
      _getDomainCursor(_cursorKeyForDomain(domain));

  /// 重置所有分域游标（全量 resync 前调用）。
  Future<void> resetAllDomainCursors() async {
    for (final domain in syncDomains) {
      await _setDomainCursor(_cursorKeyForDomain(domain), SyncDomainCursor.zero);
    }
    _log.info('Reset all sync domain cursors', tag: _tag);
  }

  /// 全量 resync 前：重置游标并清空 entity LWW 状态。
  Future<void> resetForFullResync() async {
    await resetAllDomainCursors();
    await _db.clearAllEntitySyncState();
    _log.info('Reset sync cursors and entity state for full resync', tag: _tag);
  }

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

  /// Primary / Backup：查询 cursor 之后的消息事件。
  Future<List<SyncEvent>> queryMessageEvents({
    required int sinceMs,
    String sinceEventId = '',
    String? channelId,
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _db.getMessagesChangedSince(
          sinceMs: ms,
          channelId: channelId,
          limit: fetchLimit,
          offset: offset,
        );
        return rows
            .map((row) => SyncEvent.messageEvent(messageRow: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) async {
        var deletes = await _db.querySyncTombstonesSince(
          domain: 'message',
          sinceMs: ms,
          limit: fetchLimit,
          offset: offset,
        );
        if (channelId != null) {
          deletes = deletes.where((e) => e.payload['channel_id'] == channelId).toList();
        }
        return deletes;
      },
    );
  }

  /// Primary / Backup：查询 cursor 之后的频道事件。
  Future<List<SyncEvent>> queryChannelEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _db.getChannelsUpdatedSince(ms, limit: fetchLimit, offset: offset);
        return rows
            .map((row) => SyncEvent.channelEvent(channelRow: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'channel',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  Future<List<SyncEvent>> queryChannelMemberEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _db.getChannelMembersChangedSince(ms, limit: fetchLimit, offset: offset);
        return rows
            .map((row) => SyncEvent.channelMemberEvent(memberRow: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'channel_member',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  /// 应用频道成员事件批次。
  Future<SyncDomainCursor> applyMemberEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _memberCursorKey);
    return cursor;
  }

  /// 应用 Agent 事件批次。
  Future<SyncDomainCursor> applyAgentEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _agentCursorKey);
    return cursor;
  }

  /// Primary / Backup：查询 cursor 之后更新的 Agent。
  Future<List<SyncEvent>> queryAgentEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _db.getAgentsChangedSince(sinceMs: ms, limit: fetchLimit, offset: offset);
        return rows
            .map((row) => SyncEvent.agentEvent(agentRow: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'agent',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  Future<List<SyncEvent>> querySheMemoryEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _sheMemoryDb.getChangedSince(sinceMs: ms, limit: fetchLimit, offset: offset);
        return rows
            .map((row) => SyncEvent.sheMemoryEvent(row: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'she_memory',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  Future<List<SyncEvent>> queryCognitionEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await _mindsDb.getCognitionChangedSince(
          sinceMs: ms,
          limit: fetchLimit,
          offset: offset,
        );
        return rows.map((row) {
          final kind = row['kind'] as String? ?? 'self';
          if (kind == 'user') {
            return SyncEvent.cognitionUserEvent(row: row, originDeviceId: origin);
          }
          return SyncEvent.cognitionSelfEvent(row: row, originDeviceId: origin);
        }).toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'cognition',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  /// 应用 She 记忆事件批次。
  Future<SyncDomainCursor> applySheMemoryEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _sheMemoryCursorKey);
    return cursor;
  }

  /// 应用认知事件批次。
  Future<SyncDomainCursor> applyCognitionEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _cognitionCursorKey);
    return cursor;
  }

  Future<List<SyncEvent>> queryAgentMemoryEvents({
    required int sinceMs,
    String sinceEventId = '',
    int limit = 50,
    String? originDeviceId,
  }) async {
    final since = SyncDomainCursor(wallTimeMs: sinceMs, lastEventId: sinceEventId);
    final origin = originDeviceId ?? (await AccountIdentityService.instance.localDevice())?.deviceId ?? 'local';
    return _queryDualStreamEvents(
      since: since,
      limit: limit,
      fetchUpserts: (ms, fetchLimit, offset) async {
        final rows = await AgentMemoryDbService.queryAllChangedSince(
          sinceMs: ms,
          limit: fetchLimit,
          offset: offset,
        );
        return rows
            .map((row) => SyncEvent.agentMemoryEvent(row: row, originDeviceId: origin))
            .toList();
      },
      fetchDeletes: (ms, fetchLimit, offset) => _db.querySyncTombstonesSince(
        domain: 'agent_memory',
        sinceMs: ms,
        limit: fetchLimit,
        offset: offset,
      ),
    );
  }

  /// 应用 Agent 结构化记忆事件批次。
  Future<SyncDomainCursor> applyAgentMemoryEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _agentMemoryCursorKey);
    return cursor;
  }

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
  Future<SyncDomainCursor> applyMessageEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _messageCursorKey);
    return cursor;
  }

  /// 应用频道事件批次。
  Future<SyncDomainCursor> applyChannelEvents(List<SyncEvent> events) async {
    final (cursor, _) = await _applyEvents(events, cursorKey: _channelCursorKey);
    return cursor;
  }

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

  /// 应用多域 push 批次；按 wall_time + event_id 全局排序后逐条 apply。
  /// 单条失败不阻塞其余事件；返回失败 event_id 供 Primary ack 修剪 outbox。
  Future<SyncPushApplyResult> applyPushEvents(List<SyncEvent> events) async {
    if (events.isEmpty) return SyncPushApplyResult.ok;
    final sorted = events.toList()
      ..sort((a, b) {
        final byTime = a.wallTimeMs.compareTo(b.wallTimeMs);
        if (byTime != 0) return byTime;
        return a.eventId.compareTo(b.eventId);
      });
    final failed = <String>[];
    for (final event in sorted) {
      final key = _cursorKeyForDomain(event.domain);
      try {
        final (_, allApplied) = await _applyEvents([event], cursorKey: key);
        if (!allApplied) failed.add(event.eventId);
      } catch (e) {
        _log.warning('Failed to apply push event ${event.eventId}: $e', tag: _tag);
        failed.add(event.eventId);
      }
    }
    return SyncPushApplyResult(
      allApplied: failed.isEmpty,
      failedEventIds: failed,
    );
  }

  Future<(SyncDomainCursor cursor, bool allApplied)> _applyEvents(
    List<SyncEvent> events, {
    required String cursorKey,
  }) async {
    final cursor = await _getDomainCursor(cursorKey);
    if (events.isEmpty) return (cursor, true);

    final role = await AccountIdentityService.instance.localDeviceRole();
    var next = cursor;
    var allApplied = true;

    for (final event in events) {
      try {
        final outcome = await _applyOne(event, role);
        switch (outcome) {
          case SyncApplyOutcome.applied:
            await _recordEntitySyncState(event);
            next = next.advance(event);
          case SyncApplyOutcome.staleSkipped:
          case SyncApplyOutcome.invalidSkipped:
            next = next.advance(event);
        }
      } catch (e) {
        _log.warning('Failed to apply sync event ${event.eventId}: $e', tag: _tag);
        allApplied = false;
        break;
      }
    }

    await _setDomainCursor(cursorKey, next);
    return (next, allApplied);
  }

  Future<SyncApplyOutcome> _applyOne(SyncEvent event, DeviceRole role) async {
    if (await _isStaleUpsert(event)) return SyncApplyOutcome.staleSkipped;
    if (event.action == SyncEventAction.delete) {
      return await _applyDelete(event, role)
          ? SyncApplyOutcome.applied
          : SyncApplyOutcome.invalidSkipped;
    }
    await _clearTombstoneForUpsert(event);
    switch (event.domain) {
      case 'message':
        return await _applyMessage(event, role)
            ? SyncApplyOutcome.applied
            : SyncApplyOutcome.invalidSkipped;
      case 'channel':
        await _applyChannel(event, role);
        return SyncApplyOutcome.applied;
      case 'channel_member':
        await _applyChannelMember(event, role);
        return SyncApplyOutcome.applied;
      case 'agent':
        await _applyAgent(event, role);
        return SyncApplyOutcome.applied;
      case 'she_memory':
        await _applySheMemory(event, role);
        return SyncApplyOutcome.applied;
      case 'cognition':
        await _applyCognition(event, role);
        return SyncApplyOutcome.applied;
      case 'agent_memory':
        return await _applyAgentMemory(event, role)
            ? SyncApplyOutcome.applied
            : SyncApplyOutcome.invalidSkipped;
      default:
        return SyncApplyOutcome.invalidSkipped;
    }
  }

  Future<bool> _applyAgentMemory(SyncEvent event, DeviceRole role) async {
    final agentId = event.payload['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return false;
    await AgentMemoryDbService.forAgent(agentId).upsertFromSync(event.payload);
    return true;
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

  Future<bool> _applyDelete(SyncEvent event, DeviceRole role) async {
    switch (event.domain) {
      case 'message':
        final id = event.payload['id'] as String?;
        if (id == null) return false;
        await _db.deleteMessageFromSync(id);
        await _db.deleteMessageIndex(id);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'channel':
        final id = event.payload['id'] as String?;
        if (id == null) return false;
        await _db.deleteChannelFromSync(id);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'channel_member':
        final channelId = event.payload['channel_id'] as String?;
        final agentId = event.payload['agent_id'] as String?;
        if (channelId == null || agentId == null) return false;
        await _db.removeChannelMemberFromSync(channelId, agentId);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'agent':
        final id = event.payload['id'] as String?;
        if (id == null) return false;
        await _db.deleteAgentFromSync(id);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'she_memory':
        final key = event.payload['key'] as String?;
        if (key == null) return false;
        await _sheMemoryDb.deleteFromSync(key);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'agent_memory':
        final agentId = event.payload['agent_id'] as String?;
        final syncKey = event.payload['sync_key'] as String?;
        if (agentId == null || syncKey == null) return false;
        await AgentMemoryDbService.forAgent(agentId).deleteFromSync(syncKey);
        await _recordTombstoneIfStorage(event, role);
        return true;
      case 'cognition':
        final kind = event.payload['kind'] as String? ?? 'self';
        final agentId = event.payload['agent_id'] as String?;
        if (agentId == null) return false;
        if (kind == 'user') {
          await _mindsDb.deleteUserCognitionFromSync(agentId);
        } else {
          await _mindsDb.deleteSelfCognitionFromSync(agentId);
        }
        await _recordTombstoneIfStorage(event, role);
        return true;
      default:
        return false;
    }
  }

  Future<bool> _applyMessage(SyncEvent event, DeviceRole role) async {
    final row = event.payload;
    final id = row['id'] as String?;
    if (id == null) return false;

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
      if (existing == null && await _shouldCacheMessage(policy, wallTime, row: row)) {
        await _db.upsertMessageFromSync(row);
      } else if (existing != null) {
        await _db.upsertMessageFromSync(row);
      }
      await _trimAppCache(policy);
    } else {
      await _db.upsertMessageFromSync(row);
    }
    return true;
  }

  Future<void> _applyChannel(SyncEvent event, DeviceRole role) async {
    await _db.upsertChannelFromSync(event.payload);
  }

  /// Primary：持久化来自 App 的 commit（含更新与删除）。
  Future<SyncCommitResult> commitEvent(SyncEvent event) async {
    if (!await AccountIdentityService.instance.isCanonicalPrimary()) {
      return SyncCommitResult.failed;
    }
    final outcome = await _applyOne(event, DeviceRole.primary);
    return _commitOutcome(outcome, event);
  }

  /// Backup：Primary 离线时暂存 App commit（供 sync_query 与后续 relay）。
  Future<SyncCommitResult> commitEventAsStorageRelay(SyncEvent event) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.backup) return SyncCommitResult.failed;
    final outcome = await _applyOne(event, DeviceRole.backup);
    return _commitOutcome(outcome, event);
  }

  Future<SyncCommitResult> _commitOutcome(SyncApplyOutcome outcome, SyncEvent event) async {
    switch (outcome) {
      case SyncApplyOutcome.applied:
        await _recordEntitySyncState(event);
        return SyncCommitResult.appliedOk();
      case SyncApplyOutcome.staleSkipped:
        return SyncCommitResult.staleOk();
      case SyncApplyOutcome.invalidSkipped:
        return SyncCommitResult.failed;
    }
  }

  /// 本地 entity/行状态是否已新于该事件（relay stale 后可安全丢弃队列行）。
  Future<bool> isEventSupersededByLocalState(SyncEvent event) =>
      _isStaleUpsert(event);

  Future<bool> _isStaleUpsert(SyncEvent event) async {
    final state = await _entitySyncState(event);
    final stateMs = (state?['wall_time_ms'] as int?) ?? 0;
    final stateEventId = state?['event_id'] as String? ?? '';
    final stateOrigin = state?['origin_device_id'] as String? ?? '';

    int rowMs = 0;
    switch (event.domain) {
      case 'message':
        final id = event.payload['id'] as String? ?? '';
        if (id.isEmpty) return false;
        final existing = await _db.getMessageById(id, fetchRemote: false);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null
            ? 0
            : SyncLww.isoRowTimeMs(existing, ['updated_at', 'created_at']);
      case 'channel':
        final id = event.payload['id'] as String? ?? '';
        if (id.isEmpty) return false;
        final existing = await _db.getChannelRowById(id);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null
            ? 0
            : SyncLww.isoRowTimeMs(existing, ['updated_at', 'created_at']);
      case 'channel_member':
        final channelId = event.payload['channel_id'] as String? ?? '';
        final agentId = event.payload['agent_id'] as String? ?? '';
        if (channelId.isEmpty || agentId.isEmpty) return false;
        final existing = await _db.getChannelMemberRow(channelId, agentId);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null
            ? 0
            : SyncLww.isoRowTimeMs(existing, ['updated_at', 'joined_at']);
      case 'agent':
        final id = event.payload['id'] as String? ?? '';
        if (id.isEmpty) return false;
        final existing = await _db.getAgentRowById(id);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null
            ? 0
            : SyncLww.intRowTimeMs(existing, ['updated_at', 'created_at']);
      case 'she_memory':
        final key = event.payload['key'] as String? ?? '';
        if (key.isEmpty) return false;
        final existing = await _sheMemoryDb.getRowByKey(key);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null ? 0 : SyncLww.intRowTimeMs(existing, ['updated_at']);
      case 'cognition':
        final kind = event.payload['kind'] as String? ?? 'self';
        final agentId = event.payload['agent_id'] as String? ?? '';
        if (agentId.isEmpty) return false;
        if (kind == 'user') {
          final existing = await _mindsDb.getUserCognition(agentId);
          if (existing == null && stateMs == 0) return false;
          rowMs = existing?.lastUpdated ?? 0;
        } else {
          final existing = await _mindsDb.getSelfCognition(agentId);
          if (existing == null && stateMs == 0) return false;
          rowMs = existing?.updatedAt ?? 0;
        }
      case 'agent_memory':
        final agentId = event.payload['agent_id'] as String? ?? '';
        final syncKey = event.payload['sync_key'] as String? ?? '';
        if (agentId.isEmpty || syncKey.isEmpty) return false;
        final existing = await AgentMemoryDbService.forAgent(agentId).getRowBySyncKey(syncKey);
        if (existing == null && stateMs == 0) return false;
        rowMs = existing == null ? 0 : SyncLww.intRowTimeMs(existing, ['updated_at']);
      default:
        return false;
    }

    final effectiveMs = rowMs > stateMs ? rowMs : stateMs;
    if (effectiveMs == 0) return false;
    final useStateMeta = stateMs >= rowMs && stateMs > 0;
    return SyncLww.isIncomingStale(
      incomingWallTimeMs: event.wallTimeMs,
      existingWallTimeMs: effectiveMs,
      incomingEventId: event.eventId,
      existingEventId: useStateMeta ? stateEventId : '',
      incomingOriginDeviceId: event.originDeviceId,
      existingOriginDeviceId: useStateMeta ? stateOrigin : '',
    );
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

  Future<bool> _shouldCacheMessage(
    AppCachePolicy policy,
    int wallTimeMs, {
    Map<String, dynamic>? row,
  }) async {
    final age = DateTime.now().millisecondsSinceEpoch - wallTimeMs;
    if (age > policy.maxDays * 86400000) return false;
    final count = await _db.countCachedMessages();
    if (count >= policy.maxMessages) return false;
    if (policy.maxBytes > 0 && row != null) {
      final incoming = AppCacheUtils.estimateMessageRowBytes(row);
      final total = await _db.totalCachedMessageBytes();
      if (total + incoming > policy.maxBytes) return false;
    }
    return true;
  }

  /// upsert 与 tombstone 各自维护 offset，避免双路分页漏事件。
  Future<List<SyncEvent>> _queryDualStreamEvents({
    required SyncDomainCursor since,
    required int limit,
    required Future<List<SyncEvent>> Function(int sinceMs, int batchSize, int offset) fetchUpserts,
    required Future<List<SyncEvent>> Function(int sinceMs, int batchSize, int offset) fetchDeletes,
  }) async {
    final acc = <SyncEvent>[];
    var upsertOffset = 0;
    var deleteOffset = 0;
    const batch = 80;
    const maxIterations = 60;

    for (var i = 0; i < maxIterations; i++) {
      final upserts = await fetchUpserts(since.wallTimeMs, batch, upsertOffset);
      final deletes = await fetchDeletes(since.wallTimeMs, batch, deleteOffset);
      upsertOffset += upserts.length;
      deleteOffset += deletes.length;

      if (upserts.isEmpty && deletes.isEmpty) break;

      acc.addAll(upserts);
      acc.addAll(deletes);
      final page = SyncDomainCursor.pageEventsAfter(events: acc, cursor: since, limit: limit);
      if (page.length >= limit) return page;
      if (upserts.length < batch && deletes.length < batch) {
        return SyncDomainCursor.pageEventsAfter(events: acc, cursor: since, limit: limit);
      }
    }

    return SyncDomainCursor.pageEventsAfter(events: acc, cursor: since, limit: limit);
  }

  /// Primary 本地写入 fan-out 前记录实体 LWW 状态。
  Future<void> recordEntitySyncState(SyncEvent event) => _recordEntitySyncState(event);

  Future<void> _recordEntitySyncState(SyncEvent event) async {
    final entityKey = SyncEvent.entityKeyForEvent(event);
    if (entityKey == null || entityKey.isEmpty) return;
    await _db.upsertEntitySyncState(
      domain: event.domain,
      entityKey: entityKey,
      wallTimeMs: event.wallTimeMs,
      eventId: event.eventId,
      originDeviceId: event.originDeviceId,
    );
  }

  Future<Map<String, dynamic>?> _entitySyncState(SyncEvent event) async {
    final entityKey = SyncEvent.entityKeyForEvent(event);
    if (entityKey == null || entityKey.isEmpty) return null;
    return _db.getEntitySyncState(event.domain, entityKey);
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
    await _db.trimMessagesToPolicy(
      policy.maxMessages,
      policy.maxDays,
      maxBytes: policy.maxBytes,
    );
  }

  /// 清理超过保留期的 delete tombstone（Primary / Backup）。
  /// 保留窗口 = clamp(max(30天, 各设备离线时长), 90天)，避免长期离线设备收不到 delete。
  Future<void> pruneOldTombstones() async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary && role != DeviceRole.backup) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final devices = await AccountIdentityService.instance.ownedDevices();
    final cutoff = SyncTombstoneUtils.pruneCutoffWallTimeMs(
      nowMs: now,
      deviceLastSeenMs: devices.map((d) => d.lastSeenAt ?? d.trustedAt),
    );

    final pruned = await _db.pruneSyncTombstonesOlderThan(cutoff);
    if (pruned > 0) {
      _log.info('Pruned $pruned sync tombstones older than $cutoff', tag: _tag);
    }
  }
}
