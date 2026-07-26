import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 本机 store 设备树导出结果（方案 §7.5 危险区兜底）。
class StoreExportResult {
  StoreExportResult({
    required this.directory,
    required this.fileCount,
    required this.totalBytes,
  });

  final Directory directory;
  final int fileCount;
  final int totalBytes;
}

/// 导出本机 `<device_id>/{artifacts,files,attachments,backups}/` 正式区树。
///
/// 跳过 `.staging` 与一切 `.` 开头目录；不做 WebDAV（§13 可选）。
class StoreExportService {
  StoreExportService._();
  static final StoreExportService instance = StoreExportService._();

  static const _tag = 'StoreExport';
  final _log = LoggerService();

  /// 将本机设备目录导出到 [targetDir]/device_id>/`。
  Future<StoreExportResult> exportSelfTree(String targetDir) async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final source = Directory(p.join(store.root.path, self));
    if (!await source.exists()) {
      throw StateError('local device store missing');
    }
    final dest = Directory(p.join(targetDir, self));
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await dest.create(recursive: true);

    var files = 0;
    var bytes = 0;
    for (final space in StoreSpace.all) {
      final srcSpace = Directory(p.join(source.path, space));
      if (!await srcSpace.exists()) continue;
      final destSpace = Directory(p.join(dest.path, space));
      final copied = await _copySpace(srcSpace, destSpace);
      files += copied.files;
      bytes += copied.bytes;
    }

    _log.info(
        'exported self store to ${dest.path} ($files files, $bytes bytes)',
        tag: _tag);
    return StoreExportResult(
      directory: dest,
      fileCount: files,
      totalBytes: bytes,
    );
  }

  Future<({int files, int bytes})> _copySpace(
      Directory source, Directory dest) async {
    var files = 0;
    var bytes = 0;
    await dest.create(recursive: true);
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: source.path);
      final parts = rel.split(p.separator);
      if (parts.any((s) => s.startsWith('.'))) continue;
      if (entity is Directory) {
        await Directory(p.join(dest.path, rel)).create(recursive: true);
        continue;
      }
      if (entity is! File) continue;
      final out = File(p.join(dest.path, rel));
      await out.parent.create(recursive: true);
      await entity.copy(out.path);
      files++;
      bytes += await entity.length();
    }
    return (files: files, bytes: bytes);
  }
}
