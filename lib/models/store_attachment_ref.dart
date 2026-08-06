import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

/// 储物袋 store 内文件的引用（聊天附件引用模式，不复制）。
class StoreAttachmentRef {
  const StoreAttachmentRef({
    required this.deviceId,
    required this.space,
    required this.path,
    required this.displayName,
    required this.sizeBytes,
  });

  final String deviceId;
  final String space;
  /// space 内相对路径（`/` 分隔）。
  final String path;
  final String displayName;
  final int sizeBytes;

  String get storeUri => storeUriWithRef(space, deviceId, path);

  factory StoreAttachmentRef.fromEntry({
    required String deviceId,
    required String space,
    required StoreEntry entry,
  }) {
    final parts = entry.path.split('/');
    final name = parts.isNotEmpty ? parts.last : entry.path;
    return StoreAttachmentRef(
      deviceId: deviceId,
      space: space,
      path: entry.path,
      displayName: name,
      sizeBytes: entry.size,
    );
  }

  /// 解析为本机绝对路径 [File]（仅 latest 版本；不存在则 null）。
  Future<File?> resolveLocalFile() async {
    try {
      final store = await StoreService.instance.localStore();
      final abs = p.joinAll([
        store.root.path,
        deviceId,
        space,
        ...path.split('/'),
      ]);
      final file = File(abs);
      if (await file.exists()) return file;
    } catch (_) {}
    return null;
  }

  static Future<File?> fileFromStoreUri(String storeUri) async {
    try {
      final parsed = parseStoreUri(storeUri);
      if (!parsed.ref.isLatest) return null;
      final store = await StoreService.instance.localStore();
      final abs = p.joinAll([
        store.root.path,
        parsed.device,
        parsed.space,
        ...parsed.path.split('/'),
      ]);
      final file = File(abs);
      if (await file.exists()) return file;
    } catch (_) {}
    return null;
  }
}
