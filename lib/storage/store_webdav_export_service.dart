import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'webdav_uploader.dart';

/// WebDAV 导出结果（危险区兜底，方案 §7.5 / §13）。
class StoreWebdavExportResult {
  StoreWebdavExportResult({
    required this.remoteRoot,
    required this.fileCount,
    required this.totalBytes,
  });

  final String remoteRoot;
  final int fileCount;
  final int totalBytes;
}

/// 将本机四分区正式文件上传到 WebDAV（跳过 `.staging` / 点目录）。
class StoreWebdavExportService {
  StoreWebdavExportService._();
  static final StoreWebdavExportService instance = StoreWebdavExportService._();

  static const _tag = 'StoreWebdavExport';
  final _log = LoggerService();

  /// [remotePrefix] 为服务器上的相对根（可空）；最终路径
  /// `{prefix}/{device_id}/{space}/...`。
  Future<StoreWebdavExportResult> exportSelfTree({
    required WebdavUploader uploader,
    String remotePrefix = '',
  }) async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final source = Directory(p.join(store.root.path, self));
    if (!await source.exists()) {
      throw StateError('local device store missing');
    }

    final prefix = remotePrefix
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    final rootRemote = prefix.isEmpty ? self : '$prefix/$self';
    await uploader.ensureCollection(rootRemote);

    var files = 0;
    var bytes = 0;
    for (final space in StoreSpace.all) {
      final srcSpace = Directory(p.join(source.path, space));
      if (!await srcSpace.exists()) continue;
      final spaceRemote = '$rootRemote/$space';
      await uploader.ensureCollection(spaceRemote);
      await for (final entity
          in srcSpace.list(recursive: true, followLinks: false)) {
        final rel = p.relative(entity.path, from: srcSpace.path);
        final parts = rel.split(p.separator);
        if (parts.any((s) => s.startsWith('.'))) continue;
        final remoteRel = parts.join('/');
        if (entity is Directory) {
          await uploader.ensureCollection('$spaceRemote/$remoteRel');
          continue;
        }
        if (entity is! File) continue;
        final data = await entity.readAsBytes();
        await uploader.putBytes('$spaceRemote/$remoteRel', data);
        files++;
        bytes += data.length;
      }
    }

    _log.info(
        'exported self store to webdav $rootRemote ($files files, $bytes bytes)',
        tag: _tag);
    return StoreWebdavExportResult(
      remoteRoot: rootRemote,
      fileCount: files,
      totalBytes: bytes,
    );
  }
}
