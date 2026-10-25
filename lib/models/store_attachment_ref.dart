import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/host_pouch_target.dart';
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
  })  : pouchId = null,
        scope = null;

  /// v3 袋子里的文件：地址是 `pouch://<pouch_id>/<scope>/<path>`。
  const StoreAttachmentRef.scoped({
    required String this.pouchId,
    required String this.scope,
    required this.path,
    required this.displayName,
    required this.sizeBytes,
  })  : deviceId = '',
        space = '';

  final String deviceId;
  final String space;
  /// space 内相对路径（`/` 分隔）。
  final String path;
  final String displayName;
  final int sizeBytes;

  /// v3 袋子 id / scope；非空时 [storeUri] 生成三段式地址。
  final String? pouchId;
  final String? scope;

  bool get isScoped => pouchId != null && scope != null;

  /// 地址不带设备段（docs/pouch_uri_no_device_decision.md）；[deviceId] 只
  /// 用于本机物理路径。
  String get storeUri => isScoped
      ? PouchV2Uri(pouchId: pouchId!, scope: scope!, path: path).format()
      : storeUriWithRef(space, path);

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
  ///
  /// v3 袋子里的文件不在 v2 本机树里，统一交给 [StoreUriReader.copyTo] 物化。
  Future<File?> resolveLocalFile() async {
    if (isScoped) return null;
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
        await resolveStoreDevice(parsed.space),
        parsed.space,
        ...parsed.path.split('/'),
      ]);
      final file = File(abs);
      if (await file.exists()) return file;
    } catch (_) {}
    return null;
  }
}
