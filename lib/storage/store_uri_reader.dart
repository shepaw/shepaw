import 'dart:io';
import 'dart:typed_data';

import '../models/store_attachment_ref.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'remote_read_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// `store://` 指向的是文件还是目录。
enum StoreUriKind { file, directory }

/// 按 `store://` URI 读取内容（Agent CLI / 附件引用共用）。
///
/// - `workspaces` / `files` / `public`（及 legacy `artifacts`）：本机直读；他端优先直连属主，属主离线再走 master 镜像；
/// - 私有分区（`runtime` / `attachments` / `backups` 等）：仅本机自身 device 可读（或显式分享/授权）。
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

    final preferred =
        await StoreService.instance.preferredReadServer(device);
    try {
      final result = await RemoteReadService.instance.readVerified(
        serverDeviceId: preferred,
        deviceId: device,
        space: space,
        path: path,
        allowOwnerFallback: false,
      );
      return result.bytes;
    } catch (e) {
      final masterId = await StoreService.instance.masterDeviceId();
      // 属主直读失败时回退 master 镜像（备份路径）。
      if (preferred != masterId) {
        final result = await RemoteReadService.instance.readVerified(
          serverDeviceId: masterId,
          deviceId: device,
          space: space,
          path: path,
          allowOwnerFallback: false,
        );
        return result.bytes;
      }
      rethrow;
    }
  }

  /// 轻量判断 URI 是文件还是目录（本机 `entityKind`；他端先看本地镜像再 meta）。
  Future<StoreUriKind> kindOf(String uriString) async {
    final parsed = parseStoreUri(uriString, allowEmptyPath: true);
    if (!parsed.ref.isLatest) {
      throw ArgumentError(
          'versioned store URI not supported yet: $uriString');
    }
    if (parsed.path.isEmpty) return StoreUriKind.directory;

    final self = await DeviceIdentity.deviceId();
    _assertReadable(parsed.space, parsed.device, self);

    final store = await StoreService.instance.localStore();
    try {
      final kind =
          await store.entityKind(parsed.device, parsed.space, parsed.path);
      return kind == 'dir' ? StoreUriKind.directory : StoreUriKind.file;
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
      if (parsed.device == self) rethrow;
    }

    final server =
        await StoreService.instance.preferredReadServer(parsed.device);
    final metaRes = await StoreService.instance.callPeer(
      server,
      StoreFrame(op: StoreOp.meta, payload: {
        'space': parsed.space,
        'device': parsed.device,
        'path': parsed.path,
      }),
    );
    if (metaRes == null ||
        metaRes['_error'] == StoreError.masterOffline ||
        metaRes['_error'] == StoreError.notPaired) {
      throw StateError('master_offline');
    }
    if (metaRes.containsKey('_error')) {
      final code = metaRes['_error'] as String;
      if (code == StoreError.notFound) {
        throw StoreException(StoreError.notFound, parsed.path);
      }
      throw StateError('meta failed: $code');
    }
    return metaRes['kind'] == 'dir'
        ? StoreUriKind.directory
        : StoreUriKind.file;
  }

  /// 仅查文件大小（本机 `stat` / 远端 meta，不拉内容）。
  Future<int> sizeOf(String uriString) async {
    final parsed = _parseLatest(uriString);
    final self = await DeviceIdentity.deviceId();
    _assertReadable(parsed.space, parsed.device, self);

    if (parsed.device == self) {
      final local = await StoreAttachmentRef.fileFromStoreUri(uriString);
      if (local != null) return local.length();
      final store = await StoreService.instance.localStore();
      final meta = await store.meta(parsed.device, parsed.space, parsed.path);
      final size = meta['size'] as int?;
      if (size == null) {
        throw StateError('not a file: $uriString');
      }
      return size;
    }

    final server =
        await StoreService.instance.preferredReadServer(parsed.device);
    return RemoteReadService.instance.probeSize(
      serverDeviceId: server,
      deviceId: parsed.device,
      space: parsed.space,
      path: parsed.path,
    );
  }

  /// 流式/拷贝物化到 [dest]，避免整文件 [Uint8List]。
  Future<void> copyTo(
    String uriString,
    File dest, {
    int? maxBytes,
    void Function(int done, int total)? onProgress,
  }) async {
    final parsed = _parseLatest(uriString);
    final self = await DeviceIdentity.deviceId();
    _assertReadable(parsed.space, parsed.device, self);

    final local = await StoreAttachmentRef.fileFromStoreUri(uriString);
    if (local != null) {
      final size = await local.length();
      if (maxBytes != null && size > maxBytes) {
        throw StoreException(
            StoreError.badOp, 'file too large: $size > $maxBytes');
      }
      await dest.parent.create(recursive: true);
      if (onProgress == null || size < 4 * 1024 * 1024) {
        await local.copy(dest.path);
        onProgress?.call(size, size);
        return;
      }
      await _copyFileWithProgress(local, dest, size, onProgress);
      return;
    }

    if (parsed.device == self) {
      final store = await StoreService.instance.localStore();
      final meta = await store.meta(parsed.device, parsed.space, parsed.path);
      final size = meta['size'] as int? ?? 0;
      if (maxBytes != null && size > maxBytes) {
        throw StoreException(
            StoreError.badOp, 'file too large: $size > $maxBytes');
      }
      await dest.parent.create(recursive: true);
      final sink = dest.openWrite();
      var offset = 0;
      try {
        while (true) {
          final (chunk, _, eof) = await store.read(
            parsed.device,
            parsed.space,
            parsed.path,
            offset,
            LocalStore.maxReadChunk,
          );
          if (chunk.isNotEmpty) sink.add(chunk);
          offset += chunk.length;
          onProgress?.call(offset, size > 0 ? size : offset);
          if (eof || chunk.isEmpty) break;
        }
      } finally {
        await sink.close();
      }
      return;
    }

    final server =
        await StoreService.instance.preferredReadServer(parsed.device);
    await RemoteReadService.instance.materializeToFile(
      serverDeviceId: server,
      deviceId: parsed.device,
      space: parsed.space,
      path: parsed.path,
      dest: dest,
      maxBytes: maxBytes,
      onProgress: onProgress,
      allowOwnerFallback: server != parsed.device,
    );
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

  static ({String space, String device, String path, StoreUriRef ref})
      _parseLatest(String uriString) {
    final parsed = parseStoreUri(uriString);
    if (!parsed.ref.isLatest) {
      throw ArgumentError(
          'versioned store URI not supported yet: $uriString');
    }
    return parsed;
  }

  static void _assertReadable(String space, String device, String self) {
    final isOwn = device == self;
    final isShared = StoreSpace.sharedReadable.contains(space);
    if (!isOwn && !isShared) {
      throw ArgumentError(
          'acl_denied: space "$space" is only readable for own device');
    }
  }

  static Future<void> _copyFileWithProgress(
    File source,
    File dest,
    int total,
    void Function(int done, int total) onProgress,
  ) async {
    final sink = dest.openWrite();
    var done = 0;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        done += chunk.length;
        onProgress(done, total);
      }
    } finally {
      await sink.close();
    }
  }
}
