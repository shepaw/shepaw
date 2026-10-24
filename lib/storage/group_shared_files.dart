import 'dart:typed_data';

import 'device_identity.dart';
import 'group_workspace_service.dart';
import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_scope_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'store_uri_reader.dart';

/// 群共享文件（[G4]）：`group:<gid>:shared` 下的 `files/<rel>`。
///
/// 只认群 id：群会话怎么切都不影响这里 —— 共享面是群的，不是会话的
/// （会话自己的附件在 `group:<gid>:session:<sid>/attachments/`）。
///
/// 过渡回退：没有 v3 袋子（本机还没有 active_pouch）时，仍读写旧的
/// `workspaces/<gid>/shared/files/<rel>`。两条路对外是同一套 API，调用方不用
/// 判断；[usesScope] 只用于展示与测试。
class GroupSharedFiles {
  GroupSharedFiles({
    required PouchScopeStore? scopes,
    GroupSharedLegacy? legacy,
  })  : _scopes = scopes,
        _legacy = legacy ?? WorkspaceSpaceLegacy();

  final PouchScopeStore? _scopes;
  final GroupSharedLegacy _legacy;

  /// scope 里文件所在的子目录。
  static const filesDir = 'files';

  /// 当前是否走 v3（false = 过渡期的 workspaces 旧目录）。
  bool get usesScope => _scopes != null;

  /// 有 v3 袋子就用 scope，否则退回 workspaces 旧路径。
  static Future<GroupSharedFiles> resolve() async => GroupSharedFiles(
        scopes: await StoreService.instance.scopeStoreOrNull(),
      );

  /// 群共享面的 scope（`group:<gid>:shared`）。
  static PouchScope scopeOf(String groupId) => PouchScope.groupShared(groupId);

  /// 列一层：[path] 相对 `files/`，空串是共享根。
  ///
  /// 返回的条目路径已去掉 `files/` 前缀（`docs/a.md`），调用方只看共享根之下的
  /// 相对路径。
  Future<List<StoreEntry>> list(String groupId, {String path = ''}) async {
    final rel = _rel(path);
    final scopes = _scopes;
    if (scopes != null) {
      final scope = scopeOf(groupId);
      final full = rel.isEmpty ? filesDir : '$filesDir/$rel';
      final entries = await scopes.listChildren(scope, path: full);
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
    return _legacy.list(groupId, rel);
  }

  /// 读一份共享文件；不存在返回 null。
  Future<Uint8List?> read(String groupId, String path) async {
    final rel = _rel(path);
    final scopes = _scopes;
    if (scopes != null) {
      return scopes.read(scopeOf(groupId), '$filesDir/$rel');
    }
    return _legacy.read(groupId, rel);
  }

  /// 写一份共享文件，返回它的地址（v3 是 `pouch://<id>/group:<gid>:shared/...`）。
  Future<String> write(String groupId, String path, Uint8List bytes) async {
    final rel = _rel(path);
    final scopes = _scopes;
    if (scopes != null) {
      final scope = scopeOf(groupId);
      final target = '$filesDir/$rel';
      // 文档读–改–写：带上当前版本；新建（没有 meta）按 Missing 写。
      final current = await scopes.meta(scope, target);
      return scopes.write(
        scope,
        target,
        bytes,
        expectedVersion: current?.version,
      );
    }
    return _legacy.write(groupId, rel, bytes);
  }

  Future<void> delete(String groupId, String path) async {
    final rel = _rel(path);
    final scopes = _scopes;
    if (scopes != null) {
      await scopes.delete(scopeOf(groupId), '$filesDir/$rel');
      return;
    }
    await _legacy.delete(groupId, rel);
  }

  /// 一份共享文件的地址。
  Future<String> uri(String groupId, String path) async {
    final rel = _rel(path);
    final scopes = _scopes;
    if (scopes != null) {
      return scopes.uriFor(scopeOf(groupId), '$filesDir/$rel').format();
    }
    return _legacy.uri(groupId, rel);
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

/// 过渡期（没有 v3 袋子）的共享文件读写面：`workspaces/<gid>/shared/files/…`。
///
/// 这一层只是为了让 [GroupSharedFiles] 的两条路形状一致；G2 之后所有机器都
/// 有 active_pouch，可以整块删掉。
abstract class GroupSharedLegacy {
  Future<List<StoreEntry>> list(String groupId, String relPath);

  Future<Uint8List?> read(String groupId, String relPath);

  Future<String> write(String groupId, String relPath, Uint8List bytes);

  Future<void> delete(String groupId, String relPath);

  Future<String> uri(String groupId, String relPath);
}

/// 走 v2 的 workspaces 分区（旧路径）。
class WorkspaceSpaceLegacy implements GroupSharedLegacy {
  String _pathOf(String groupId, String relPath) {
    final root = GroupWorkspaceService.instance.workspaceRoot(groupId);
    final base = '$root/shared/files';
    return relPath.isEmpty ? base : '$base/$relPath';
  }

  @override
  Future<List<StoreEntry>> list(String groupId, String relPath) async {
    final path = _pathOf(groupId, relPath);
    final base = '$path/';
    final entries = await StoreService.instance.listDevice(
      deviceId: await _device(groupId),
      space: StoreSpace.workspaces,
      prefix: path,
      depth: 1,
      computeHash: false,
      preferLocalCache: true,
    );
    return <StoreEntry>[
      for (final entry in entries)
        if (entry.path.startsWith(base))
          StoreEntry(
            path: entry.path.substring(base.length),
            size: entry.size,
            sha256: entry.sha256,
            mtimeMs: entry.mtimeMs,
            kind: entry.kind,
          ),
    ];
  }

  @override
  Future<Uint8List?> read(String groupId, String relPath) async {
    try {
      return await StoreUriReader.instance
          .read(storeUriWithRef(StoreSpace.workspaces, _pathOf(groupId, relPath)));
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<String> write(
    String groupId,
    String relPath,
    Uint8List bytes,
  ) async =>
      StoreService.instance.writeWorkspaceFile(
        homeDeviceId: await _device(groupId),
        relPath: _pathOf(groupId, relPath),
        content: bytes,
      );

  @override
  Future<void> delete(String groupId, String relPath) async {
    await StoreService.instance.deleteDevicePath(
      deviceId: await _device(groupId),
      space: StoreSpace.workspaces,
      path: _pathOf(groupId, relPath),
    );
  }

  @override
  Future<String> uri(String groupId, String relPath) async =>
      storeUriWithRef(StoreSpace.workspaces, _pathOf(groupId, relPath));

  /// workspaces 目录的 owner：元数据里记的 home device，没有就本机。
  Future<String> _device(String groupId) async {
    final meta = await GroupWorkspaceService.instance.loadMeta(groupId);
    final home = meta?.homeDevice ?? '';
    if (home.isNotEmpty) return home;
    return DeviceIdentity.deviceId();
  }
}