import 'dart:io';
import 'dart:typed_data';

import 'host_pouch_target.dart';
import 'local_store.dart';
import 'slip_scope_documents.dart';
import 'store_service.dart';

/// 主机连不上：权威副本读写不了，也不该在本机留一份。
///
/// UI 把它翻成「连不上这台主机」，不要当成普通保存失败。
class HostOfflineException implements Exception {
  const HostOfflineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 储物袋里「权威在 hub」的那份文档的读写面。
///
/// 玉简（`slips`）用它：v3 的权威是 hub 上的 `slip:<id>` scope，客户端经
/// [StoreService.scopeStore] 直读直写。
abstract class HostPouchDocuments {
  /// 玉简记录里的 device_id 元数据。
  String get deviceId;

  String uri(String space, String path);

  /// 列一层目录。
  Future<List<StoreEntry>> list(String space, {String? prefix});

  /// 读一份文档；不存在返回 null。
  Future<Uint8List?> read(
    String space,
    String path, {
    String? knownHash,
    int? knownSize,
  });

  Future<void> writeBytes(String space, String path, Uint8List bytes);

  /// 从磁盘流式写入。返回字节数。
  Future<int> writeFile(String space, String path, File file);

  Future<void> delete(String space, String path, {bool folder = false});
}

/// 按当前登录的袋子解析读写面。
class HostPouchDocumentsFactory {
  HostPouchDocumentsFactory._();

  /// 玉简权威在 `slip:<id>` scope；没有袋子时按未配对报错。
  static Future<HostPouchDocuments> resolve() async {
    final target = await HostPouchTarget.resolve();
    return SlipScopeDocuments(
      store: await StoreService.instance.scopeStore(),
      deviceId: target.deviceId,
    );
  }
}
