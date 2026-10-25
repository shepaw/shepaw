/// 聊天附件写入 runtime store 的共享实现（本机 DM / peer 入站共用）。
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'device_identity.dart';
import 'local_store.dart';
import 'pouch_scope.dart';
import 'pouch_scope_store.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 将附件 bytes 写入 `runtime/<owner>/<channel>/attachments/<sha256>`（hash 去重）。
///
/// 过渡期还提供 [storeScopedBytes]：同一份 bytes 再写进 v3 袋子的 scope。
class AttachmentStoreWriter {
  AttachmentStoreWriter._();

  /// 写入本机 store，返回 `pouch://runtime/…` URI（地址不带设备段）。
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
      return storeUriWithRef(StoreSpace.runtime, relPath);
    } on StoreException {
      // not_found → 写入
    }
    await local.putBytes(
      deviceId: device,
      space: StoreSpace.runtime,
      path: relPath,
      bytes: bytes,
      sha256Hex: hash,
    );
    return storeUriWithRef(StoreSpace.runtime, relPath);
  }

  /// 把附件写进当前袋子的 [scope] 的 [directory] 下，文件名取内容 sha256
  /// （同一份已经在盘上就不重复写）。返回 v3 地址。
  ///
  /// 落点由 [PouchAttachmentScopes.messageAttachmentTarget] 算好；没有可用
  /// 袋子（未登录、本机没有 hub）时抛 `notPaired`，调用方按「只写 v2」处理。
  static Future<String> storeScopedBytes(
    Uint8List bytes, {
    required PouchScope scope,
    required String directory,
    PouchScopeStore? store,
  }) async {
    final hash = crypto.sha256.convert(bytes).toString();
    final dir = directory.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final path = dir.isEmpty ? hash : '$dir/$hash';
    final scoped = store ?? await StoreService.instance.scopeStore();
    if (await scoped.meta(scope, path) != null) {
      return scoped.uriFor(scope, path).format();
    }
    return scoped.write(scope, path, bytes);
  }
}
