import 'dart:convert';
import 'dart:typed_data';

import '../models/agent_memory_entry.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/memory_paths.dart';
import '../storage/pouch_scope.dart';
import '../storage/pouch_scope_store.dart';
import '../storage/runtime_mirror_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'agent_memory_db_service.dart';
import 'logger_service.dart';
import 'minds_database_service.dart';
import 'she_memory_db_service.dart';

/// Agent 结构化记忆：权威落在 v3 的 `agent:<agentId>` scope。
///
/// - Soul / profile / 人脸向量：`identity/…`
/// - 本机结构化记忆：`memory/entries/*.json`、`memory/meta.json`
/// - Peer 中继（按配对设备隔离）：`memory/peers/<peerId>/…`
///
/// 首次访问会把旧 v2 `cognition/`（及 legacy `memory/` 空间）里的文件一次性
/// 映射进 v3，并标记在 `memory/meta.json`。旧 `agent_memory_*.db` 也在首次
/// 访问时导入（仅本机根目录；peer 子树不做 SQLite 迁移）。
class AgentMemoryStoreService {
  AgentMemoryStoreService._(this._agentId, {String? peerClientId})
      : _peerClientId = _normalizePeer(peerClientId);

  static final Map<String, AgentMemoryStoreService> _instances = {};

  static String? _normalizePeer(String? peerClientId) {
    final p = peerClientId?.trim();
    if (p == null || p.isEmpty) return null;
    return p;
  }

  static String _instanceKey(String agentId, String? peerClientId) {
    final peer = _normalizePeer(peerClientId);
    if (peer == null) return agentId;
    return '$agentId::peer::$peer';
  }

  /// [peerClientId]：配对客户端的 peerId；非空时读写 peers 子目录。
  static AgentMemoryStoreService forAgent(
    String agentId, {
    String? peerClientId,
  }) {
    final key = _instanceKey(agentId, peerClientId);
    return _instances.putIfAbsent(
      key,
      () => AgentMemoryStoreService._(agentId, peerClientId: peerClientId),
    );
  }

  static Future<void> closeAll() async {
    _instances.clear();
  }

  /// 清除全部 Agent 的认知（v3 `identity` / `memory` / App 派生记忆）与
  /// 旧 v2 `cognition`、`memory` 空间。
  static Future<void> deleteAllAgentMemories() async {
    await closeAll();
    try {
      final scoped = await StoreService.instance.scopeStoreOrNull();
      if (scoped != null) {
        final ids = await scoped.scopes('agent:');
        for (final id in ids) {
          final scope = PouchScope.tryParse(id);
          if (scope == null || scope.kind != PouchScopeKind.agent) continue;
          await _deleteScopePrefix(scoped, scope, 'identity');
          await _deleteScopePrefix(scoped, scope, 'memory');
          await _deleteScopePrefix(scoped, scope, 'derived/app-memory');
        }
      }
    } catch (e) {
      LoggerService().error(
        'Failed to delete agent cognition from scoped pouch',
        tag: 'AgentMemoryStore',
        error: e,
      );
    }
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      for (final space in StoreSpace.cognitionAliases) {
        final roots = await store.list(
          deviceId,
          space,
          depth: 1,
          limit: 5000,
        );
        for (final e in roots) {
          if (!e.isDir) continue;
          try {
            await store.delete(deviceId, space, e.path);
          } catch (_) {}
        }
      }
    } catch (e) {
      LoggerService().error(
        'Failed to delete legacy cognition spaces',
        tag: 'AgentMemoryStore',
        error: e,
      );
    }
    // 顺带清遗留 SQLite
    await AgentMemoryDbService.deleteAllDatabases();
  }

  /// 删除 scope 下某个前缀的所有文件（hub 的 delete 只认单路径）。
  static Future<void> _deleteScopePrefix(
    PouchScopeStore scoped,
    PouchScope scope,
    String prefix,
  ) async {
    String? cursor;
    final paths = <String>[];
    do {
      final page = await scoped.transport.list(
        pouchId: scoped.pouchId,
        scope: scope,
        prefix: prefix,
        limit: 1000,
        cursor: cursor,
      );
      for (final e in page.entries) {
        if (!e.isDir) paths.add(e.path);
      }
      if (page.entries.isEmpty) break;
      cursor = page.nextCursor;
    } while (cursor != null && cursor.isNotEmpty);
    for (final path in paths) {
      try {
        await scoped.delete(scope, path);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
    }
  }

  final String _agentId;
  /// 非空表示这是某配对设备的子记忆命名空间。
  final String? _peerClientId;
  static const _tag = 'AgentMemoryStore';
  final _log = LoggerService();

  bool _ensured = false;

  String get agentId => _agentId;
  String? get peerClientId => _peerClientId;
  bool get _isPeerScoped => _peerClientId != null;

  String get _scopeTag =>
      _isPeerScoped ? '$_agentId/peers/$_peerClientId' : _agentId;

  Future<void> _ensure() async {
    if (_ensured) return;
    await _migrateV2ToScopedIfNeeded();
    if (!_isPeerScoped) {
      await _migrateFromSqliteIfNeeded();
      await _migrateSoulFromSqliteIfNeeded();
    }
    _ensured = true;
  }

  /// 人脸向量等其他入口在访问 v3 前先触发同一份 v2 迁移。
  Future<void> ensureV2Migration() => _ensure();

  Future<LocalStore> _store() => StoreService.instance.localStore();

  Future<PouchScopeStore> _scopes() => StoreService.instance.scopeStore();

  Future<String> _deviceId() => DeviceIdentity.deviceId();

  PouchScope get _scope => MemoryPaths.scopeFor(_agentId);

  /// 把 v2 `cognition/`（以及更早的 `memory/`）一次性映射进 v3 agent scope。
  ///
  /// 只处理当前实例的范围：本机根跳过 `peers/`，peer 实例只看自己的子树。
  /// 目标已存在就不覆盖；迁移完成写 `v3_migrated`，之后不再扫 v2。
  Future<void> _migrateV2ToScopedIfNeeded() async {
    final meta = await _loadMeta();
    if (meta.v3Migrated) return;
    try {
      final deviceId = await _deviceId();
      final store = await _store();
      final scoped = await _scopes();
      final prefix =
          '${MemoryPaths.legacyScopedRoot(_agentId, peerClientId: _peerClientId)}/';
      var copied = 0;
      // legacy memory 先扫，cognition 后扫；同名目标已存在就跳过，所以
      // cognition 里的权威副本会赢。
      for (final space in StoreSpace.cognitionAliases.reversed) {
        final files = await store.list(
          deviceId,
          space,
          prefix: prefix,
          limit: 10000,
          computeHash: false,
        );
        for (final e in files) {
          if (e.isDir) continue;
          final target = MemoryPaths.v3PathForLegacy(
            _agentId,
            e.path,
            peerClientId: _peerClientId,
          );
          if (target == null || target.isEmpty) continue;
          if (await scoped.meta(_scope, target) != null) continue;
          final bytes = await _readLegacyBytes(space, e.path);
          if (bytes == null) continue;
          await scoped.write(_scope, target, bytes);
          copied++;
        }
      }
      // v2 的 meta.json 也可能刚被搬过来，重新读一次再标记，避免把
      // 迁移进来的 next_id 用旧默认值覆盖掉。
      final current = await _loadMeta();
      await _saveMeta(current.copyWith(v3Migrated: true));
      if (copied > 0) {
        _log.info(
          'migrated $copied files v2 → ${_scope.id} for $_scopeTag',
          tag: _tag,
        );
      }
    } catch (e) {
      _log.warning(
        'v2 → scoped cognition migrate skipped: $e',
        tag: '$_tag[$_scopeTag]',
      );
      rethrow;
    }
  }

  Future<void> _writeBytes(String relPath, Uint8List content) async {
    final scoped = await _scopes();
    await scoped.write(_scope, normalizeStorePath(relPath), content);
  }

  /// 只给迁移读 v2 文件用（v3 读取走 [PouchScopeStore.read]）。
  Future<Uint8List?> _readLegacyBytes(String space, String relPath) async {
    try {
      final deviceId = await _deviceId();
      final store = await _store();
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await store.read(
          deviceId,
          space,
          relPath,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      final bytes = buf.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
  }

  Future<void> _writeJson(String relPath, Map<String, dynamic> json) async {
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
    await _writeBytes(relPath, bytes);
  }

  Future<Uint8List?> _readBytes(String relPath) async {
    final scoped = await _scopes();
    return scoped.read(_scope, normalizeStorePath(relPath));
  }

  Future<Map<String, dynamic>?> _readJson(String relPath) async {
    final bytes = await _readBytes(relPath);
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> _writeText(String relPath, String text) async {
    await _writeBytes(relPath, Uint8List.fromList(utf8.encode(text)));
  }

  Future<String?> _readText(String relPath) async {
    final bytes = await _readBytes(relPath);
    if (bytes == null) return null;
    return utf8.decode(bytes);
  }

  Future<_MemoryMeta> _loadMeta() async {
    final raw = await _readJson(
      MemoryPaths.metaPath(peerClientId: _peerClientId),
    );
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
      v3Migrated: raw['v3_migrated'] == true,
      schemaVersion: (raw['schema_version'] as num?)?.toInt() ?? 2,
    );
  }

  Future<void> _saveMeta(_MemoryMeta meta) async {
    await _writeJson(
      MemoryPaths.metaPath(peerClientId: _peerClientId),
      meta.toJson(),
    );
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
          MemoryPaths.entryPath(id, peerClientId: _peerClientId),
          e.toJson(),
        );
      }
      await _saveMeta(meta.copyWith(
        nextId: maxId + 1,
        migratedFromSqlite: true,
      ));
      await _exportMemoryMarkdown();
      await db.close();
      _log.info(
        'migrated ${rows.length} memories from SQLite → store',
        tag: '$_tag[$_scopeTag]',
      );
    } catch (e) {
      _log.warning(
        'sqlite migrate skipped/failed: $e',
        tag: '$_tag[$_scopeTag]',
      );
      // 仍标记，避免每次打开重试失败迁移阻塞
      await _saveMeta(meta.copyWith(migratedFromSqlite: true));
    }
  }

  Future<List<StoreEntry>> _listEntryFiles({int limit = 5000}) async {
    final scoped = await _scopes();
    final entries = await scoped.listChildren(
      _scope,
      path: MemoryPaths.entriesDir(peerClientId: _peerClientId),
      limit: limit,
    );
    return [
      for (final e in entries)
        if (!e.isDir && e.path.endsWith('.json')) e,
    ];
  }

  Future<AgentMemoryEntry?> _readEntry(int memoryId) async {
    final json = await _readJson(
      MemoryPaths.entryPath(memoryId, peerClientId: _peerClientId),
    );
    if (json == null) return null;
    return AgentMemoryEntry.fromJson(json);
  }

  Future<void> _exportMemoryMarkdown() async {
    if (_isPeerScoped) return; // peer 子记忆不镜像到宿主 runtime/memory.md
    try {
      final entries = await getAllMemories(limit: 200);
      final buf = StringBuffer('# Memory export\n\n');
      for (final e in entries) {
        buf.writeln('- (${e.memoryType.name}) ${e.memoryContent}');
      }
      await RuntimeMirrorService.instance
          .mirrorMemory(_agentId, buf.toString());
    } catch (e) {
      _log.warning('memory.md export failed: $e', tag: '$_tag[$_scopeTag]');
    }
  }

  void _afterMutation() {
    if (!_isPeerScoped) {
      RuntimeMirrorService.instance.scheduleMemoryMirror(_agentId);
      // ignore: unawaited_futures
      _exportMemoryMarkdown();
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
      MemoryPaths.entryPath(id, peerClientId: _peerClientId),
      effective.toJson(),
    );
    _log.info('Memory added: #$id', tag: '$_tag[$_scopeTag]');
    _afterMutation();
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
      MemoryPaths.entryPath(id, peerClientId: _peerClientId),
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
      MemoryPaths.entryPath(id, peerClientId: _peerClientId),
      effective.toJson(),
    );
    _afterMutation();
  }

  Future<void> _deletePath(String relPath) async {
    final scoped = await _scopes();
    try {
      await scoped.delete(_scope, relPath);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
  }

  Future<void> deleteMemory(int memoryId) async {
    await _ensure();
    await _deletePath(
      MemoryPaths.entryPath(memoryId, peerClientId: _peerClientId),
    );
    _afterMutation();
  }

  Future<void> clearAllMemories() async {
    await _ensure();
    final files = await _listEntryFiles();
    for (final f in files) {
      await _deletePath(f.path);
    }
    final meta = await _loadMeta();
    await _saveMeta(meta.copyWith(nextId: 1));
    _afterMutation();
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
    _instances.remove(_instanceKey(_agentId, _peerClientId));
    _ensured = false;
  }

  // ── Soul ──────────────────────────────────────────────────────────────

  /// 读取 Soul 权威（`cognition/<agent>/soul.md`）。
  Future<String?> getSoul() async {
    await _ensure();
    return peekSoul();
  }

  /// 只读 `soul.md`，不做 legacy 迁移。Peer 中继用，避免 `_ensure` 卡死不回包。
  Future<String?> peekSoul() async {
    final text = await _readText(MemoryPaths.soulPath());
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
    await _writeText(MemoryPaths.soulPath(), '$header$soul\n');
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
    final existing = await _readText(MemoryPaths.soulPath());
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
            MemoryPaths.soulPath(), '$header${fromMinds.trim()}\n');
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

  /// 删除该作用域在 v3 里的认知数据，并清掉同名 v2 旧目录（避免下次迁移
  /// 把删掉的数据又搬回来）。
  ///
  /// 本机根：`identity`、`memory`、`derived/app-memory`；peer 子树：仅
  /// `memory/peers/<peerId>` 下的内容。简历 `derived/resume.md` 不在清理范围。
  Future<void> deleteAll() async {
    await close();
    try {
      final scoped = await _scopes();
      if (_isPeerScoped) {
        await _deleteScopePrefix(
          scoped,
          _scope,
          MemoryPaths.memoryRoot(peerClientId: _peerClientId),
        );
      } else {
        await _deleteScopePrefix(scoped, _scope, 'identity');
        await _deleteScopePrefix(scoped, _scope, 'memory');
        await _deleteScopePrefix(scoped, _scope, 'derived/app-memory');
      }
      final deviceId = await _deviceId();
      final store = await _store();
      final root = MemoryPaths.legacyScopedRoot(
        _agentId,
        peerClientId: _peerClientId,
      );
      for (final space in StoreSpace.cognitionAliases) {
        try {
          await store.delete(deviceId, space, root);
        } catch (_) {}
      }
      if (!_isPeerScoped) {
        try {
          await AgentMemoryDbService.forAgent(_agentId).deleteDatabase();
        } catch (_) {}
      }
      _log.info('Memory store deleted for $_scopeTag', tag: _tag);
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
    this.v3Migrated = false,
    this.schemaVersion = 2,
  });

  final int nextId;
  final bool migratedFromSqlite;
  final bool soulMigratedFromSqlite;
  final bool v3Migrated;
  final int schemaVersion;

  _MemoryMeta copyWith({
    int? nextId,
    bool? migratedFromSqlite,
    bool? soulMigratedFromSqlite,
    bool? v3Migrated,
    int? schemaVersion,
  }) =>
      _MemoryMeta(
        nextId: nextId ?? this.nextId,
        migratedFromSqlite: migratedFromSqlite ?? this.migratedFromSqlite,
        soulMigratedFromSqlite:
            soulMigratedFromSqlite ?? this.soulMigratedFromSqlite,
        v3Migrated: v3Migrated ?? this.v3Migrated,
        schemaVersion: schemaVersion ?? this.schemaVersion,
      );

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'next_id': nextId,
        'migrated_from_sqlite': migratedFromSqlite,
        'soul_migrated_from_sqlite': soulMigratedFromSqlite,
        'v3_migrated': v3Migrated,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
