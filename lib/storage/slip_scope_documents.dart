import 'dart:io';
import 'dart:typed_data';

import 'host_pouch_documents.dart';
import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_scope_store.dart';
import 'store_protocol.dart';

/// 玉简的 v3 权威读写面（[G4]）：一条玉简一个 scope `slip:<id>`。
///
/// 落点（hub 的 `layout::slip_path` / `slip_file_path`）：
/// - 记录：`slip:<id>` / `slip.json`
/// - 附件：`slip:<id>` / `files/<file>`
///
/// 调用方仍按 v2 的 slips 分区相对路径说话（`<id>.json`、
/// `<id>/files/<file>`）：映射只在这一层做，所以 JadeSlipService 的读改写
/// 逻辑和已有记录里的 path 字段都不用动。地址经 uri() 出，是 v3 三段式
/// （`pouch://<pouch_id>/slip:<id>/files/<file>`）。
class SlipScopeDocuments implements HostPouchDocuments {
  SlipScopeDocuments({
    required PouchScopeStore store,
    required this.deviceId,
    int cacheEntries = 128,
  })  : _store = store,
        _cacheLimit = cacheEntries;

  final PouchScopeStore _store;
  final int _cacheLimit;

  /// 最近读过的记录（相对路径 → 字节）。
  ///
  /// 列表是「先列 scope 再读每条记录」：读到的字节顺手留着，紧接着的
  /// `read` 不必再走一趟帧。任何写入/删除都清空（内容可能已变）。
  final Map<String, Uint8List> _cache = <String, Uint8List>{};

  /// 权威副本所在设备（v3 里只作为玉简记录里的 device_id 元数据）。
  @override
  final String deviceId;

  @override
  String uri(String space, String path) {
    final target = _target(space, path);
    return _store.uriFor(target.scope, target.path).format();
  }

  @override
  Future<List<StoreEntry>> list(String space, {String? prefix}) async {
    _requireSlips(space);
    final scopes = await _store.scopes('slip:');
    final out = <StoreEntry>[];
    for (final scopeId in scopes) {
      final slipId = scopeId.substring('slip:'.length);
      if (slipId.isEmpty) continue;
      final rel = '$slipId.json';
      final trimmedPrefix = (prefix ?? '').replaceFirst(RegExp(r'^/+'), '');
      if (trimmedPrefix.isNotEmpty && !rel.startsWith(trimmedPrefix)) {
        continue;
      }
      final bytes = await _readRecord(PouchScope.slip(slipId));
      if (bytes == null) continue;
      out.add(StoreEntry(
        path: rel,
        size: bytes.length,
        sha256: '',
        mtimeMs: 0,
      ));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<Uint8List?> read(
    String space,
    String path, {
    String? knownHash,
    int? knownSize,
  }) async {
    final target = _target(space, path);
    final cached = _cache[path];
    if (cached != null) return cached;
    final bytes = await _store.read(target.scope, target.path);
    if (bytes == null) return null;
    _remember(path, bytes);
    return bytes;
  }

  /// 写一份文档：先读当前版本再写（v3 的 `put` 必须声明期望版本）。
  ///
  /// 帧里带的是刚读到的 `expected_version`：真被别人改过就当冲突报错，
  /// 不静默覆盖。文件本来不存在时按新建（`Missing`）写。
  @override
  Future<void> writeBytes(String space, String path, Uint8List bytes) async {
    final target = _target(space, path);
    final current = await _store.meta(target.scope, target.path);
    await _store.write(
      target.scope,
      target.path,
      bytes,
      expectedVersion: current?.version,
    );
    _cache.remove(path);
  }

  @override
  Future<int> writeFile(String space, String path, File file) async {
    final bytes = await file.readAsBytes();
    await writeBytes(space, path, bytes);
    return bytes.length;
  }

  @override
  Future<void> delete(String space, String path, {bool folder = false}) async {
    final target = _target(space, path);
    if (!folder) {
      try {
        await _store.delete(target.scope, target.path);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
      _cache.remove(path);
      return;
    }
    // 目录删除：先按前缀列这一层，再逐个删。玉简只在清附件时用得到。
    final children = await _store.listChildren(target.scope, path: target.path);
    for (final child in children) {
      await _store.delete(target.scope, child.path);
      _cache.remove(child.path);
    }
  }

  /// `slips` 分区相对路径 → `(scope, scope 内路径)`。
  ({PouchScope scope, String path}) _target(String space, String path) {
    _requireSlips(space);
    final rel = path.replaceFirst(RegExp(r'^/+'), '').trim();
    if (rel.isEmpty) {
      throw ArgumentError('empty slips path');
    }
    final slash = rel.indexOf('/');
    if (slash < 0) {
      // 记录：`<id>.json`
      if (!rel.endsWith('.json') || rel.length <= '.json'.length) {
        throw ArgumentError('not a jade slip record: $path');
      }
      final id = rel.substring(0, rel.length - '.json'.length);
      return (scope: PouchScope.slip(id), path: 'slip.json');
    }
    // 附件：`<id>/files/<file>`
    final id = rel.substring(0, slash);
    final rest = rel.substring(slash + 1);
    if (!rest.startsWith('files/')) {
      throw ArgumentError('not a jade slip attachment: $path');
    }
    return (scope: PouchScope.slip(id), path: rest);
  }

  void _requireSlips(String space) {
    if (space != StoreSpace.slips) {
      throw ArgumentError('slip scope documents only handle slips: $space');
    }
  }

  Future<Uint8List?> _readRecord(PouchScope scope) async {
    final rel = '${scope.ownerId}.json';
    final cached = _cache[rel];
    if (cached != null) return cached;
    final bytes = await _store.read(scope, 'slip.json');
    if (bytes == null) return null;
    _remember(rel, bytes);
    return bytes;
  }

  void _remember(String path, Uint8List bytes) {
    if (_cacheLimit <= 0) return;
    _cache.remove(path);
    _cache[path] = bytes;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }
}