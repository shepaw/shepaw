import 'dart:typed_data';

import 'device_identity.dart';
import 'local_store.dart';
import 'remote_read_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 按 `store://` URI 读取内容（Agent CLI / 附件引用共用）。
///
/// - `artifacts` / `files`：本机直读或经 [RemoteReadService] 缓存校验；
/// - 私有分区（`attachments` / `backups` 等）：仅本机自身 device 可读。
/// - 当前仅支持 latest（无 `@ref`）；版本引用后续扩展。
class StoreUriReader {
  StoreUriReader._();
  static final instance = StoreUriReader._();

  Future<Uint8List> read(String uriString) async {
    final parsed = parseStoreUri(uriString);
    if (!parsed.ref.isLatest) {
      throw ArgumentError(
          'versioned store URI not supported yet: $uriString');
    }
    final self = await DeviceIdentity.deviceId();
    final space = parsed.space;
    final device = parsed.device;
    final path = parsed.path;
    final isOwn = device == self;
    final isShared = StoreSpace.sharedReadable.contains(space);

    if (!isOwn && !isShared) {
      throw ArgumentError(
          'acl_denied: space "$space" is only readable for own device');
    }

    if (isOwn) {
      return _readLocal(device, space, path);
    }

    final masterId = await StoreService.instance.masterDeviceId();
    final result = await RemoteReadService.instance.readVerified(
      serverDeviceId: masterId,
      deviceId: device,
      space: space,
      path: path,
    );
    return result.bytes;
  }

  Future<Uint8List> _readLocal(
      String deviceId, String space, String path) async {
    final store = await StoreService.instance.localStore();
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final (chunk, _, eof) = await store.read(
        deviceId,
        space,
        path,
        offset,
        LocalStore.maxReadChunk,
      );
      builder.add(chunk);
      offset += chunk.length;
      if (eof || chunk.isEmpty) break;
    }
    return builder.takeBytes();
  }
}
