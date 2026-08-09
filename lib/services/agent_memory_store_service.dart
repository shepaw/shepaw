import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../models/agent_memory_entry.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/memory_paths.dart';
import '../storage/runtime_mirror_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'agent_memory_db_service.dart';
import 'logger_service.dart';
import 'minds_database_service.dart';
import 'she_memory_db_service.dart';

/// Agent 结构化记忆：权威落在储物袋 `memory/<agentId>/entries/*.json`。
///
/// 首次访问若发现旧 `agent_memory_*.db` 且 store 为空，会一次性迁移后标记。
class AgentMemoryStoreService {
  AgentMemoryStoreService._(this._agentId);

  static final Map<String, AgentMemoryStoreService> _instances = {};

  static AgentMemoryStoreService forAgent(String agentId) {
    return _instances.putIfAbsent(
      agentId,
      () => AgentMemoryStoreService._(agentId),
    );
  }

  static Future<void> closeAll() async {
    _instances.clear();
  }

  /// 清除全部 Agent 的 memory 空间目录（设置「清除数据」用）。
  static Future<void> deleteAllAgentMemories() async {
    await closeAll();
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      final roots = await store.list(
        deviceId,
        StoreSpace.memory,
        depth: 1,
        limit: 5000,
      );
      for (final e in roots) {
        if (!e.isDir) continue;
        try {
          await store.delete(deviceId, StoreSpace.memory, e.path);
        } catch (_) {}
      }
      // 顺带清遗留 SQLite
      await AgentMemoryDbService.deleteAllDatabases();
    } catch (e) {
      LoggerService().error(
        'Failed to delete all agent memories from store',
        tag: 'AgentMemoryStore',
        error: e,
      );
    }
  }

  final String _agentId;
  static const _tag = 'AgentMemoryStore';
  final _log = LoggerService();

  bool _ensured = false;

  String get agentId => _agentId;

  Future<void> _ensure() async {
    if (_ensured) return;
    await _migrateFromSqliteIfNeeded();
    await _migrateSoulFromSqliteIfNeeded();
    _ensured = true;
  }

  Future<LocalStore> _store() => StoreService.instance.localStore();

  Future<String> _deviceId() => DeviceIdentity.deviceId();

  Future<void> _writeBytes(String relPath, Uint8List content) async {
    final deviceId = await _deviceId();
    final store = await _store();
    final path = normalizeStorePath(relPath);
    final hash = crypto.sha256.convert(content).toString();
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.memory,
      path: path,
      size: content.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(
        deviceId,
        StoreSpace.memory,
        uploadId,
        offset,
        content.sublist(offset, end),
      );
      offset = end;
    }
    final (ok, failed) =
        await store.commit(deviceId, StoreSpace.memory, [uploadId]);
    if (failed.isNotEmpty || ok.isEmpty) {
      throw StateError('memory write failed: $failed');
    }
  }

  Future<void> _writeJson(String relPath, Map<String, dynamic> json) async {
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
    await _writeBytes(relPath, bytes);
  }

  Future<Map<String, dynamic>?> _readJson(String relPath) async {
    try {
      final deviceId = await _deviceId();
      final store = await _store();
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await store.read(
          deviceId,
          StoreSpace.memory,
          relPath,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      final bytes = buf.takeBytes();
      if (bytes.isEmpty) return null;
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
  }

  Future<void> _writeText(String relPath, String text) async {
    await _writeBytes(relPath, Uint8List.fromList(utf8.encode(text)));
  }

  Future<String?> _readText(String relPath) async {
    try {
      final deviceId = await _deviceId();
      final store = await _store();
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await store.read(
          deviceId,
          StoreSpace.memory,
          relPath,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      final bytes = buf.takeBytes();
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes);
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
  }

  Future<_MemoryMeta> _loadMeta() async {
    final raw = await _readJson(MemoryPaths.metaJson(_agentId));
    if (raw == null) {
      return const _MemoryMeta(
        nextId: 1,
        migratedFromSqlite: false,
        soulMigratedFromSqlite: false,
      );
    }
    return _MemoryMeta(
      nextId: (raw['next_id'] as num?)?.toInt() ?? 1,
      migratedFromSqlite: raw['migrated_from_sqlite'] == true,
      soulMigratedFromSqlite: raw['soul_migrated_from_sqlite'] == true,
      schemaVersion: (raw['schema_version'] as num?)?.toInt() ?? 1,
    );
  }

  Future<void> _saveMeta(_MemoryMeta meta) async {
    await _writeJson(MemoryPaths.metaJson(_agentId), meta.toJson());
  }

  Future<int> _allocId() async {
    final meta = await _loadMeta();
    final id = meta.nextId;
    await _saveMeta(meta.copyWith(nextId: id + 1));
    return id;
  }

  Future<void> _migrateFromSqliteIfNeeded() async {
    final meta = await _loadMeta();
    if (meta.migratedFromSqlite) {
      return;
    }
    // store 已有条目则只打标，避免覆盖
    final existing = await _listEntryFiles(limit: 1);
    if (existing.isNotEmpty) {
      await _saveMeta(meta.copyWith(migratedFromSqlite: true));
      return;
    }

    try {
      final db = AgentMemoryDbService.forAgent(_agentId);
      final rows = await db.getAllMemories(limit: 100000);
      if (rows.isEmpty) {
        await _saveMeta(meta.copyWith(migratedFromSqlite: true));
        await db.close();
        return;
      }
      var maxId = 0;
      for (final e in rows) {
        final id = e.memoryId;
        if (id == null) continue;
        if (id > maxId) maxId = id;
        await _writeJson(
          MemoryPaths.entryJson(_agentId, id),
          e.toJson(),
        );
      }
      await _saveMeta(_MemoryMeta(
        nextId: maxId + 1,
        migratedFromSqlite: true,
      ));
      await _exportMemoryMarkdown();
      await db.close();
      _log.info(
        'migrated ${rows.length} memories from SQLite → store',
        tag: '$_tag[$_agentId]',
      );
    } catch (e) {
      _log.warning(
        'sqlite migrate skipped/failed: $e',
        tag: '$_tag[$_agentId]',
      );
      // 仍标记，避免每次打开重试失败迁移阻塞
      await _saveMeta(meta.copyWith(migratedFromSqlite: true));
    }
  }

  Future<List<StoreEntry>> _listEntryFiles({int limit = 5000}) async {
    final deviceId = await _deviceId();
    final store = await _store();
    final prefix = '${MemoryPaths.entriesDir(_agentId)}/';
    final entries = await store.list(
      deviceId,
      StoreSpace.memory,
      prefix: prefix,
      limit: limit,
    );
    return [
      for (final e in entries)
        if (!e.isDir && e.path.endsWith('.json')) e,
    ];
  }

  Future<AgentMemoryEntry?> _readEntry(int memoryId) async {
    final json =
        await _readJson(MemoryPaths.entryJson(_agentId, memoryId));
    if (json == null) return null;
    return AgentMemoryEntry.fromJson(json);
  }

  Future<void> _exportMemoryMarkdown() async {
    try {
      final entries = await getAllMemories(limit: 200);
      final buf = StringBuffer('# Memory export\n\n');
      for (final e in entries) {
        buf.writeln('- (${e.memoryType.name}) ${e.memoryContent}');
      }
      await RuntimeMirrorService.instance
          .mirrorMemory(_agentId, buf.toString());
    } catch (e) {
      _log.warning('memory.md export failed: $e', tag: '$_tag[$_agentId]');
    }
  }

  // ── CRUD ──────────────────────────────────────────────────────────────

  Future<int> addMemory(AgentMemoryEntry entry) async {
    await _ensure();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _allocId();
    final effective = entry.copyWith(
      memoryId: id,
      createdAt: entry.createdAt == 0 ? now : entry.createdAt,
      updatedAt: now,
    );
    await _writeJson(
      MemoryPaths.entryJson(_agentId, id),
      effective.toJson(),
    );
    _log.info('Memory added: #$id', tag: '$_tag[$_agentId]');
    RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
    // ignore: unawaited_futures
    _exportMemoryMarkdown();
    return id;
  }

  /// 导入带固定 memory_id 的条目（备份恢复）；会抬高 next_id。
  Future<void> importEntry(AgentMemoryEntry entry) async {
    await _ensure();
    final id = entry.memoryId;
    if (id == null) {
      await addMemory(entry);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final effective = entry.copyWith(
      memoryId: id,
      createdAt: entry.createdAt == 0 ? now : entry.createdAt,
      updatedAt: now,
    );
    await _writeJson(
      MemoryPaths.entryJson(_agentId, id),
      effective.toJson(),
    );
    final meta = await _loadMeta();
    if (id >= meta.nextId) {
      await _saveMeta(meta.copyWith(nextId: id + 1));
    }
  }

  Future<AgentMemoryEntry?> getMemory(int memoryId) async {
    await _ensure();
    return _readEntry(memoryId);
  }

  Future<List<AgentMemoryEntry>> getAllMemories({
    MemoryType? type,
    String? sourceType,
    int limit = 200,
  }) async {
    await _ensure();
    final files = await _listEntryFiles(limit: 10000);
    final out = <AgentMemoryEntry>[];
    for (final f in files) {
      final name = f.path.split('/').last;
      final id = int.tryParse(name.replaceAll('.json', ''));
      if (id == null) continue;
      final e = await _readEntry(id);
      if (e == null) continue;
      if (type != null && e.memoryType != type) continue;
      if (sourceType != null && e.sourceType != sourceType) continue;
      out.add(e);
    }
    out.sort((a, b) => b.memoryTime.compareTo(a.memoryTime));
    if (out.length > limit) return out.sublist(0, limit);
    return out;
  }

  Future<void> updateMemory(AgentMemoryEntry entry) async {
    await _ensure();
    final id = entry.memoryId;
    if (id == null) {
      throw ArgumentError('memoryId required for update');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final effective = entry.copyWith(updatedAt: now);
    await _writeJson(
      MemoryPaths.entryJson(_agentId, id),
      effective.toJson(),
    );
    RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
    // ignore: unawaited_futures
    _exportMemoryMarkdown();
  }

  Future<void> deleteMemory(int memoryId) async {
    await _ensure();
    final deviceId = await _deviceId();
    final store = await _store();
    try {
      await store.delete(
        deviceId,
        StoreSpace.memory,
        MemoryPaths.entryJson(_agentId, memoryId),
      );
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
    RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
    // ignore: unawaited_futures
    _exportMemoryMarkdown();
  }

  Future<void> clearAllMemories() async {
    await _ensure();
    final deviceId = await _deviceId();
    final store = await _store();
    final files = await _listEntryFiles();
    for (final f in files) {
      try {
        await store.delete(deviceId, StoreSpace.memory, f.path);
      } catch (_) {}
    }
    final meta = await _loadMeta();
    await _saveMeta(meta.copyWith(nextId: 1));
    RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
    // ignore: unawaited_futures
    _exportMemoryMarkdown();
  }

  Future<List<AgentMemoryEntry>> queryByKeyword(
    String keyword, {
    int limit = 50,
  }) async {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) return getAllMemories(limit: limit);
    final all = await getAllMemories(limit: 10000);
    final hit = all.where((e) {
      if (e.memoryContent.toLowerCase().contains(q)) return true;
      return e.memoryKeywords.any((k) => k.toLowerCase().contains(q));
    }).toList();
    if (hit.length > limit) return hit.sublist(0, limit);
    return hit;
  }

  Future<List<AgentMemoryEntry>> queryBySource(
    String sourceType, {
    String? sourceId,
    int limit = 100,
  }) async {
    final all = await getAllMemories(
      sourceType: sourceType,
      limit: 10000,
    );
    final hit = sourceId == null
        ? all
        : all.where((e) => e.sourceId == sourceId).toList();
    if (hit.length > limit) return hit.sublist(0, limit);
    return hit;
  }

  Future<int> getMemoryCount({MemoryType? type}) async {
    final all = await getAllMemories(type: type, limit: 100000);
    return all.length;
  }

  Future<Map<MemoryType, int>> getMemoryCountByType() async {
    final all = await getAllMemories(limit: 100000);
    final map = <MemoryType, int>{};
    for (final e in all) {
      map[e.memoryType] = (map[e.memoryType] ?? 0) + 1;
    }
    return map;
  }

  Future<void> close() async {
    _instances.remove(_agentId);
    _ensured = false;
  }

  // ── Soul ──────────────────────────────────────────────────────────────

  /// 读取 Soul 权威（`memory/<agent>/soul.md`）。
  Future<String?> getSoul() async {
    await _ensure();
    final text = await _readText(MemoryPaths.soulMd(_agentId));
    if (text == null) return null;
    // Strip optional HTML comment header from mirrored exports.
    return text
        .replaceFirst(RegExp(r'^<!--[\s\S]*?-->\s*'), '')
        .trimRight();
  }

  /// 写入 Soul 权威，并镜像到 runtime/soul.md。
  Future<void> setSoul(String soul) async {
    await _ensure();
    final header =
        '<!-- updated_at: ${DateTime.now().toUtc().toIso8601String()} -->\n';
    await _writeText(MemoryPaths.soulMd(_agentId), '$header$soul\n');
    final meta = await _loadMeta();
    if (!meta.soulMigratedFromSqlite) {
      await _saveMeta(meta.copyWith(soulMigratedFromSqlite: true));
    }
    // ignore: unawaited_futures
    RuntimeMirrorService.instance.mirrorSoul(_agentId, soul);
    _log.info('Soul written to store', tag: '$_tag[$_agentId]');
  }

  Future<void> _migrateSoulFromSqliteIfNeeded() async {
    final meta = await _loadMeta();
    if (meta.soulMigratedFromSqlite) return;
    final existing = await _readText(MemoryPaths.soulMd(_agentId));
    if (existing != null && existing.trim().isNotEmpty) {
      await _saveMeta(meta.copyWith(soulMigratedFromSqlite: true));
      return;
    }
    try {
      // Avoid hard dep cycle: minds via Cognition would recurse; read DB lightly.
      final fromMinds = await _readSoulFromMinds(_agentId);
      if (fromMinds != null && fromMinds.trim().isNotEmpty) {
        final header =
            '<!-- migrated_from_minds: ${DateTime.now().toUtc().toIso8601String()} -->\n';
        await _writeText(
            MemoryPaths.soulMd(_agentId), '$header${fromMinds.trim()}\n');
        await RuntimeMirrorService.instance.mirrorSoul(_agentId, fromMinds);
        _log.info('migrated soul from minds → store', tag: '$_tag[$_agentId]');
      }
    } catch (e) {
      _log.warning('soul migrate skipped: $e', tag: '$_tag[$_agentId]');
    }
    await _saveMeta(meta.copyWith(soulMigratedFromSqlite: true));
  }

  Future<String?> _readSoulFromMinds(String agentId) async {
    try {
      final self = await MindsDatabaseService().getSelfCognition(agentId);
      final soul = self?.soul.trim();
      if (soul != null && soul.isNotEmpty) return soul;
    } catch (_) {}
    // She 旧 KV
    if (agentId == 'she-builtin-agent-001') {
      try {
        final v = await SheMemoryDbService.instance.getSheMemory('soul');
        if (v != null && v.trim().isNotEmpty) return v;
      } catch (_) {}
    }
    return null;
  }

  /// 删除该 Agent 在 memory 空间下的整棵目录（含 meta + entries + soul）。
  Future<void> deleteAll() async {
    await close();
    try {
      final deviceId = await _deviceId();
      final store = await _store();
      final root = MemoryPaths.agentRoot(_agentId);
      try {
        await store.delete(deviceId, StoreSpace.memory, root);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
      // 清理遗留 SQLite
      try {
        await AgentMemoryDbService.forAgent(_agentId).deleteDatabase();
      } catch (_) {}
      _log.info('Memory store deleted for $_agentId', tag: _tag);
    } catch (e) {
      _log.error('Failed to delete memory store', tag: _tag, error: e);
    }
  }
}

class _MemoryMeta {
  const _MemoryMeta({
    required this.nextId,
    required this.migratedFromSqlite,
    this.soulMigratedFromSqlite = false,
    this.schemaVersion = 1,
  });

  final int nextId;
  final bool migratedFromSqlite;
  final bool soulMigratedFromSqlite;
  final int schemaVersion;

  _MemoryMeta copyWith({
    int? nextId,
    bool? migratedFromSqlite,
    bool? soulMigratedFromSqlite,
    int? schemaVersion,
  }) =>
      _MemoryMeta(
        nextId: nextId ?? this.nextId,
        migratedFromSqlite: migratedFromSqlite ?? this.migratedFromSqlite,
        soulMigratedFromSqlite:
            soulMigratedFromSqlite ?? this.soulMigratedFromSqlite,
        schemaVersion: schemaVersion ?? this.schemaVersion,
      );

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'next_id': nextId,
        'migrated_from_sqlite': migratedFromSqlite,
        'soul_migrated_from_sqlite': soulMigratedFromSqlite,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
