import 'dart:typed_data';

import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';

/// 测试用的 scope 传输：文件存在内存 Map 里，写入顺便记账。
class MemoryScopeTransport implements PouchScopeTransport {
  final writes = <({String scope, String path, Uint8List bytes})>[];
  final files = <String, Uint8List>{};

  static String keyOf(PouchScope scope, String path) => '${scope.id}/$path';

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async {
    final head = '${scope.id}/';
    final entries = <StoreEntry>[];
    for (final entry in files.entries) {
      if (!entry.key.startsWith(head)) continue;
      final path = entry.key.substring(head.length);
      final dir = prefix?.trim() ?? '';
      if (dir.isNotEmpty && path != dir && !path.startsWith('$dir/')) {
        continue;
      }
      entries.add(StoreEntry(
        path: path,
        size: entry.value.length,
        sha256: '',
        mtimeMs: 0,
      ));
    }
    return PouchListPage(entries: entries);
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      files[keyOf(scope, path)];

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async {
    final ids = <String>{};
    for (final key in files.keys) {
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      final id = key.substring(0, slash);
      if (prefix.isEmpty || id.startsWith(prefix)) ids.add(id);
    }
    final list = ids.toList()..sort();
    return list;
  }

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      files.containsKey(keyOf(scope, path))
          ? PouchFileMeta(path: path, size: 1, version: 1, mtimeMs: 0)
          : null;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    writes.add((scope: scope.id, path: path, bytes: bytes));
    files[keyOf(scope, path)] = bytes;
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    files.remove(keyOf(scope, path));
  }
}
