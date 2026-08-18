import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/store_attachment_ref.dart';
import '../peer/services/peer_storage_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'remote_read_service.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// `store://` 指向的是文件还是目录。
enum StoreUriKind { file, directory }

/// 按 `store://` URI 读取内容（Agent CLI / 附件引用共用）。
///
/// - `workspaces` / `files` / `public`（及 legacy `artifacts`）：本机直读；他端优先直连属主，属主离线再走 master 镜像；
/// - 私有分区（`runtime` / `attachments` / `backups` 等）：仅本机自身 device 可读（或显式分享/授权）；
///   但 peer 隧道附件在本机留有同 URI 缓存（device=对端），读取/预览前先命中该本地文件，未命中再按 ACL 拒绝。
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
      final local =
          await _localCacheHit(space: space, device: device, path: path);
      if (local != null) return local.readAsBytes();
      await _assertReadable(space, device, path, self);
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

  /// 轻量判断 URI 是文件还是目录。
  ///
  /// 本机 device → 本地树；他端 device → [preferredReadServer]（属主/master），
  /// 不把对端在本机的空 cache 当成权威。
  Future<StoreUriKind> kindOf(String uriString) async {
    final parsed = parseStoreUri(uriString, allowEmptyPath: true);
    if (!parsed.ref.isLatest) {
      throw ArgumentError(
          'versioned store URI not supported yet: $uriString');
    }
    if (parsed.path.isEmpty) return StoreUriKind.directory;

    final localHit = await _localCacheHit(
        space: parsed.space, device: parsed.device, path: parsed.path);
    if (localHit != null) return StoreUriKind.file;
    final self = await DeviceIdentity.deviceId();
    await _assertReadable(parsed.space, parsed.device, parsed.path, self);

    if (parsed.device == self) {
      final store = await StoreService.instance.localStore();
      final kind =
          await store.entityKind(parsed.device, parsed.space, parsed.path);
      return kind == 'dir' ? StoreUriKind.directory : StoreUriKind.file;
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

  /// 最长已存在的目录前缀。
  ///
  /// 共享分区本机 miss 时保留原始 path，由浏览器向 master/属主 list，
  /// 不要把远端工作空间裁成空的本机分区根。
  Future<String> existingDirectoryPrefix(String uriString) async {
    final parsed = parseStoreUri(uriString, allowEmptyPath: true);
    final original = parsed.path;
    if (original.isEmpty) return '';
    final store = await StoreService.instance.localStore();
    try {
      final kind =
          await store.entityKind(parsed.device, parsed.space, original);
      if (kind == 'dir') return original;
      return _parentStorePath(original);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound && e.code != StoreError.badPath) {
        rethrow;
      }
      if (StoreSpace.sharedReadable.contains(parsed.space)) return original;
    } catch (_) {
      if (StoreSpace.sharedReadable.contains(parsed.space)) return original;
    }
    var current = _parentStorePath(original);
    while (true) {
      try {
        final kind =
            await store.entityKind(parsed.device, parsed.space, current);
        if (kind == 'dir') return current;
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound && e.code != StoreError.badPath) {
          rethrow;
        }
      } catch (_) {}
      if (current.isEmpty) return '';
      current = _parentStorePath(current);
    }
  }

  static String _parentStorePath(String path) {
    if (path.isEmpty) return '';
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// 仅查文件大小（本机 `stat` / 远端 meta，不拉内容）。
  Future<int> sizeOf(String uriString) async {
    final parsed = _parseLatest(uriString);
    final localHit = await _localCacheHit(
        space: parsed.space, device: parsed.device, path: parsed.path);
    if (localHit != null) return localHit.length();
    final self = await DeviceIdentity.deviceId();
    await _assertReadable(parsed.space, parsed.device, parsed.path, self);

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

    // 本地文件（含 peer 隧道本机缓存）先命中，未命中再走 ACL/远端。
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

    await _assertReadable(parsed.space, parsed.device, parsed.path, self);

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

  /// 私有分区 + 他端 device 的 URI：本机缓存命中时返回本地 [File]。
  ///
  /// Peer 隧道附件在本机留有与宿主权威同 URI 的缓存
  /// （`AttachmentStoreWriter` 写入对端 device 目录，见
  /// `peer_attachment_placement.dart`），因此跨端私有 URI 的字节可能就在
  /// 本机。共享分区（workspaces/files/…）保持远端校验读，不回退本地镜像，
  /// 避免绕过 hash 校验读到旧版本。
  Future<File?> _localCacheHit({
    required String space,
    required String device,
    required String path,
  }) async {
    if (path.isEmpty) return null;
    final self = await DeviceIdentity.deviceId();
    if (device == self) return null;
    if (StoreSpace.sharedReadable.contains(space)) return null;
    final local =
        await StoreAttachmentRef.fileFromStoreUri(storeUriWithRef(
      space,
      device,
      path,
    ));
    if (local == null) return null;
    if (await local.stat().then((s) => s.type == FileSystemEntityType.directory)) {
      return null;
    }
    return local;
  }

  /// 私有分区 + 他端 device：本机缓存未命中时，仅当对端显式分享（入站
  /// 白名单命中，runtime 另有敏感清单预过滤）才放行远端读。服务端仍按
  /// share 行 + 细粒度策略做权威判定。
  Future<void> _assertReadable(
      String space, String device, String path, String self) async {
    final isOwn = device == self;
    final isShared = StoreSpace.sharedReadable.contains(space);
    if (isOwn || isShared) return;
    if (await inboundShareAllows(space: space, device: device, path: path)) {
      return;
    }
    throw ArgumentError(
        'acl_denied: space "$space" is only readable for own device');
  }

  /// 对端是否已把 [space]/[path] 前缀分享给本机（入站 announce 缓存）。
  ///
  /// 客户端只做快速失败预过滤；实际读由服务端分享行 + 细粒度策略把关。
  @visibleForTesting
  Future<bool> inboundShareAllows({
    required String space,
    required String device,
    required String path,
  }) async {
    final peerStorage = PeerStorageService();
    final peer = await peerStorage.getPeerByDeviceId(device);
    if (peer == null) return false;
    final allowlist = await peerStorage.getInboundStoreAllowlist(peer.id);
    if (!allowlist.allows(space, path)) return false;
    if (space == StoreSpace.runtime) {
      return !RuntimeSharePolicy.isSensitivePath(path);
    }
    return true;
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
