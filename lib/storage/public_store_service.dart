import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// `public/` 薄实现：可写真实文件，或写引用清单指向 `files` URI（不复制字节）。
class PublicStoreService {
  PublicStoreService._();
  static final PublicStoreService instance = PublicStoreService._();

  static const _tag = 'PublicStore';
  final _log = LoggerService();

  /// 写入公开文本文件，返回 store URI。
  Future<String> writeText({
    required String relPath,
    required String content,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    return writeBytes(relPath: relPath, content: bytes);
  }

  /// 写入公开二进制文件。
  Future<String> writeBytes({
    required String relPath,
    required Uint8List content,
  }) async {
    final deviceId = await DeviceIdentity.deviceId();
    final path = normalizeStorePath(relPath);
    final hash = crypto.sha256.convert(content).toString();
    final store = await StoreService.instance.localStore();
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.public_,
      path: path,
      size: content.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < content.length) {
      final end = (offset + LocalStore.maxReadChunk) > content.length
          ? content.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(
          deviceId, StoreSpace.public_, uploadId, offset, content.sublist(offset, end));
      offset = end;
    }
    final (ok, failed) =
        await store.commit(deviceId, StoreSpace.public_, [uploadId]);
    if (failed.isNotEmpty || ok.isEmpty) {
      throw StateError('public write failed: $failed');
    }
    final uri = storeUriWithRef(StoreSpace.public_, deviceId, path);
    _log.info('public written: $uri', tag: _tag);
    return uri;
  }

  /// 写引用清单（Markdown），条目为已有 `store://files/...`（或其它 URI），不复制。
  Future<String> writeReferenceList({
    required String listName,
    required List<String> storeUris,
    String? title,
  }) async {
    final safe = p.basename(listName).replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final name = safe.endsWith('.md') ? safe : '$safe.md';
    final buf = StringBuffer('# ${title ?? name}\n\n');
    buf.writeln('引用清单（不复制字节；请用 store read 拉取）：\n');
    for (final u in storeUris) {
      if (u.startsWith('store://')) {
        buf.writeln('- `$u`');
      }
    }
    return writeText(relPath: name, content: buf.toString());
  }
}
