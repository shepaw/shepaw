import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'local_store.dart';
import 'snapshot_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 换机快照下载（docs/storage_space_plan.md §5.4，M3 路径 A/B 通用）。
///
/// 凭有效导入授权，从服务侧设备（旧设备或 master）把一个快照目录
/// 整体拉到本机 `<self>/backups/` 下，之后走标准 [RestoreService] 流程。
class SnapshotImportService {
  SnapshotImportService._();
  static final SnapshotImportService instance = SnapshotImportService._();

  static const _tag = 'SnapshotImport';
  final _log = LoggerService();

  /// 列出服务侧设备上某设备目录下的快照 id（新→旧）。
  Future<List<String>> listRemoteSnapshots({
    required String serverDeviceId,
    required String oldDeviceId,
    required String grantId,
  }) async {
    final res = await StoreService.instance.callPeer(
      serverDeviceId,
      StoreFrame(op: StoreOp.list, payload: {
        'space': 'backups',
        'device': oldDeviceId,
        'path': '',
        'grant': grantId,
      }),
    );
    if (res == null || res.containsKey('_error')) {
      throw StateError('list failed: ${res?['_error']}');
    }
    final ids = <String>{};
    for (final e in (res['entries'] as List).cast<Map>()) {
      final path = e['path'] as String;
      final first = path.split('/').first;
      if (first.isNotEmpty) ids.add(first);
    }
    final list = ids.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  /// 下载一个快照目录到本机 backups，返回本地 [SnapshotInfo]。
  ///
  /// 逐文件 SHA-256 校验（协议层完整性）；解密校验在恢复时进行。
  /// 旧格式（manifest 无 kdf_salt）无法换机恢复，直接报错。
  Future<SnapshotInfo> downloadSnapshot({
    required String serverDeviceId,
    required String oldDeviceId,
    required String snapshotId,
    required String grantId,
  }) async {
    // 安全：snapshotId 与 list 返回的路径全部来自远端服务侧，
    // 必须客户端校验（恶意服务侧可路径注入覆盖本地任意文件）。
    if (!RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(snapshotId)) {
      throw ArgumentError('invalid snapshot id');
    }
    // 1. 列目录
    final listing = await StoreService.instance.callPeer(
      serverDeviceId,
      StoreFrame(op: StoreOp.list, payload: {
        'space': 'backups',
        'device': oldDeviceId,
        'path': '$snapshotId/',
        'grant': grantId,
      }),
    );
    if (listing == null || listing.containsKey('_error')) {
      throw StateError('list failed: ${listing?['_error']}');
    }
    final entries = (listing['entries'] as List).cast<Map<String, dynamic>>();
    if (entries.isEmpty) throw StateError('snapshot not found');

    // 2. 下载到本地 backups/<ts>（重名加 -import 后缀）
    final backupsRoot = await SnapshotService.instance.deviceStoreRoot();
    var localId = snapshotId;
    var destDir = Directory(p.join(backupsRoot.path, 'backups', localId));
    if (await destDir.exists()) {
      localId = '$snapshotId-import';
      destDir = Directory(p.join(backupsRoot.path, 'backups', localId));
      if (await destDir.exists()) await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);

    try {
      for (final e in entries) {
        // list 返回相对 space 根的路径（含 snapshotId/ 前缀）；
        // destDir 已是 backups/<localId>/，落盘时必须剥掉前缀，否则嵌套一层。
        final spaceRel = e['path'] as String;
        final fileRel = _stripSnapshotPrefix(spaceRel, snapshotId);
        if (fileRel.isEmpty) continue;
        // 安全：剥前缀后再规范化并做包含检查（防 ../../ 逃逸）
        final normalized = normalizeStorePath(fileRel);
        final outPath = p.normalize(p.join(destDir.path, normalized));
        if (!p.isWithin(p.normalize(destDir.path), outPath)) {
          throw StateError('path escapes dest dir: $spaceRel');
        }
        final expectedHash = e['sha256'] as String;
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
          throw StateError('invalid sha256 from server');
        }
        final bytes = await _readAll(
            serverDeviceId, oldDeviceId, spaceRel, grantId, e['size'] as int);
        final actualHash = crypto.sha256.convert(bytes).toString();
        if (actualHash != expectedHash) {
          throw StateError('hash mismatch on $spaceRel');
        }
        final out = File(outPath);
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      await destDir.delete(recursive: true);
      rethrow;
    }

    // 3. 组装 SnapshotInfo（v2 格式校验）
    final manifestFile = File(p.join(destDir.path, 'manifest.json'));
    final manifest = SnapshotManifest.fromJson(
        jsonDecode(await manifestFile.readAsString())
            as Map<String, dynamic>);
    if (manifest.kdfSalt == null) {
      await destDir.delete(recursive: true);
      throw StateError('旧格式快照（无 kdf_salt）不支持换机恢复，'
          '请在旧设备上重新生成一份快照');
    }
    if (manifest.deviceId != oldDeviceId) {
      _log.warning(
          'snapshot device ${manifest.deviceId} != old $oldDeviceId',
          tag: _tag);
    }

    var total = 0;
    await for (final f in destDir.list(recursive: true)) {
      if (f is File) total += await f.length();
    }
    _log.info('snapshot $snapshotId imported as $localId ($total bytes)',
        tag: _tag);
    return SnapshotInfo(
      id: localId,
      path: destDir.path,
      manifest: manifest,
      totalBytes: total,
    );
  }

  /// list/meta 路径相对 space 根；下载目标目录已含 snapshotId，需剥前缀。
  @visibleForTesting
  static String stripSnapshotPrefix(String spaceRel, String snapshotId) {
    final prefix = '$snapshotId/';
    if (spaceRel.startsWith(prefix)) {
      return spaceRel.substring(prefix.length);
    }
    if (spaceRel == snapshotId) return '';
    return spaceRel;
  }

  static String _stripSnapshotPrefix(String spaceRel, String snapshotId) =>
      stripSnapshotPrefix(spaceRel, snapshotId);

  Future<List<int>> _readAll(String serverDeviceId, String oldDeviceId,
      String relPath, String grantId, int size) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final res = await StoreService.instance.callPeer(
        serverDeviceId,
        StoreFrame(op: StoreOp.read, payload: {
          'space': 'backups',
          'device': oldDeviceId,
          'path': relPath,
          'offset': offset,
          'length': LocalStore.maxReadChunk,
          'grant': grantId,
        }),
      );
      if (res == null || res.containsKey('_error')) {
        throw StateError('read failed: ${res?['_error']}');
      }
      final chunk = base64Decode(res['data'] as String);
      builder.add(chunk);
      offset += chunk.length;
      // 恶意服务侧永不置 eof：超出声明 size 即中止（内存防护）
      if (builder.length > size) {
        throw StateError('server sent more than declared size');
      }
      if (res['eof'] == true || chunk.isEmpty) break;
    }
    final bytes = builder.toBytes();
    if (bytes.length != size) {
      throw StateError('size mismatch: got ${bytes.length} want $size');
    }
    return bytes;
  }
}
