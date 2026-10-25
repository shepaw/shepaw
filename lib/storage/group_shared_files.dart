import 'dart:typed_data';

import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_scope_store.dart';
import 'store_service.dart';

/// 群共享文件（[G4]）：`group:<gid>:shared` 下的 `files/<rel>`。
///
/// 只认群 id：群会话怎么切都不影响这里 —— 共享面是群的，不是会话的
/// （会话自己的附件在 `group:<gid>:session:<sid>/attachments/`）。
class GroupSharedFiles {
  GroupSharedFiles({required PouchScopeStore scopes}) : _scopes = scopes;

  final PouchScopeStore _scopes;

  /// scope 里文件所在的子目录。
  static const filesDir = 'files';

  /// 取当前袋子的写入口；没有袋子时抛未配对错误。
  static Future<GroupSharedFiles> resolve() async => GroupSharedFiles(
        scopes: await StoreService.instance.scopeStore(),
      );

  /// 群共享面的 scope（`group:<gid>:shared`）。
  static PouchScope scopeOf(String groupId) => PouchScope.groupShared(groupId);

  /// 列一层：[path] 相对 `files/`，空串是共享根。
  ///
  /// 返回的条目路径已去掉 `files/` 前缀（`docs/a.md`），调用方只看共享根之下的
  /// 相对路径。
  Future<List<StoreEntry>> list(String groupId, {String path = ''}) async {
    final rel = _rel(path);
    final scope = scopeOf(groupId);
    final full = rel.isEmpty ? filesDir : '$filesDir/$rel';
    final entries = await _scopes.listChildren(scope, path: full);
    return <StoreEntry>[
      for (final entry in entries)
        StoreEntry(
          path: _stripFiles(entry.path),
          size: entry.size,
          sha256: entry.sha256,
          mtimeMs: entry.mtimeMs,
          kind: entry.kind,
        ),
    ];
  }

  /// 读一份共享文件；不存在返回 null。
  Future<Uint8List?> read(String groupId, String path) async {
    final rel = _rel(path);
    return _scopes.read(scopeOf(groupId), '$filesDir/$rel');
  }

  /// 写一份共享文件，返回它的地址（`pouch://<id>/group:<gid>:shared/...`）。
  Future<String> write(String groupId, String path, Uint8List bytes) async {
    final rel = _rel(path);
    final scope = scopeOf(groupId);
    final target = '$filesDir/$rel';
    // 文档读–改–写：带上当前版本；新建（没有 meta）按 Missing 写。
    final current = await _scopes.meta(scope, target);
    return _scopes.write(
      scope,
      target,
      bytes,
      expectedVersion: current?.version,
    );
  }

  Future<void> delete(String groupId, String path) async {
    final rel = _rel(path);
    await _scopes.delete(scopeOf(groupId), '$filesDir/$rel');
  }

  /// 一份共享文件的地址。
  Future<String> uri(String groupId, String path) async {
    final rel = _rel(path);
    return _scopes.uriFor(scopeOf(groupId), '$filesDir/$rel').format();
  }

  static String _rel(String path) {
    var rel = path.trim().replaceFirst(RegExp(r'^/+'), '');
    if (rel == filesDir) return '';
    if (rel.startsWith('$filesDir/')) {
      rel = rel.substring(filesDir.length + 1);
    }
    return rel.replaceAll(RegExp(r'/+$'), '');
  }

  static String _stripFiles(String path) {
    final value = path.replaceFirst(RegExp(r'^/+'), '');
    if (value == filesDir) return '';
    if (value.startsWith('$filesDir/')) {
      return value.substring(filesDir.length + 1);
    }
    return value;
  }
}
