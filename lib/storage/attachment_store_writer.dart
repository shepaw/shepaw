/// 聊天附件写入 runtime store 的共享实现（本机 DM / peer 入站共用）。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'device_identity.dart';
import 'local_store.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 将附件 bytes 写入 `runtime/<owner>/<channel>/attachments/<sha256>`（hash 去重）。
class AttachmentStoreWriter {
  AttachmentStoreWriter._();

  /// 写入本机 store，返回 `store://runtime/…` URI。
  static Future<String> storeBytes(
    Uint8List bytes, {
    required String ownerId,
    required String channelId,
    LocalStore? store,
    String? deviceId,
  }) async {
    final hash = crypto.sha256.convert(bytes).toString();
    final relPath = RuntimePaths.attachmentBlob(ownerId, channelId, hash);
    final local = store ?? await StoreService.instance.localStore();
    final device = deviceId ?? await DeviceIdentity.deviceId();
    try {
      await local.meta(device, StoreSpace.runtime, relPath);
      return storeUriWithRef(StoreSpace.runtime, device, relPath);
    } on StoreException {
      // not_found → 写入
    }
    final (uploadId, _) = await local.writeBegin(
      deviceId: device,
      space: StoreSpace.runtime,
      path: relPath,
      size: bytes.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + LocalStore.maxReadChunk) > bytes.length
          ? bytes.length
          : offset + LocalStore.maxReadChunk;
      await local.writeChunk(
        device,
        StoreSpace.runtime,
        uploadId,
        offset,
        bytes.sublist(offset, end),
      );
      offset = end;
    }
    final (committed, failed) =
        await local.commit(device, StoreSpace.runtime, [uploadId]);
    if (failed.isNotEmpty || committed.isEmpty) {
      throw StateError('attachment commit failed: $failed');
    }
    return storeUriWithRef(StoreSpace.runtime, device, relPath);
  }
}
