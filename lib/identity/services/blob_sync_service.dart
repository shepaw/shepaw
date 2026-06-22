import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../models/device_role.dart';
import 'account_identity_service.dart';
import 'storage_device_service.dart';
import 'sync_protocol_service.dart';

/// P2P 附件 blob 按需同步（256KB 分块，Noise 加密通道内传输）。
class BlobSyncService {
  BlobSyncService._();
  static final BlobSyncService instance = BlobSyncService._();

  static const _tag = 'BlobSync';
  static const chunkSize = 256 * 1024;

  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _files = LocalFileStorageService();
  final _uuid = const Uuid();

  final _partialUploads = <String, _PartialBlobUpload>{};

  /// blob_key 默认等于 metadata.path（相对存储路径）。
  static String blobKeyFromRelativePath(String relativePath) => relativePath;

  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 本地是否已有该附件。
  Future<bool> hasLocalBlob(String relativePath) async {
    final f = await _files.getFile(relativePath);
    return f != null;
  }

  /// 从 Primary 拉取附件到本地（App / Backup 按需）。
  Future<String?> fetchBlob(String relativePath) async {
    if (await hasLocalBlob(relativePath)) {
      await _db.touchBlobCacheAccess(blobKeyFromRelativePath(relativePath));
      return relativePath;
    }

    for (final peerId in await _storagePeerIdsInOrder()) {
      try {
        return await _fetchBlobFromPeer(peerId, relativePath);
      } catch (e) {
        _log.warning('Blob fetch failed via $peerId: $e', tag: _tag);
      }
    }
    throw StateError('No storage device available for blob sync');
  }

  Future<String?> _fetchBlobFromPeer(String peerId, String relativePath) async {
    final requestId = _uuid.v4();
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'sync_blob_req',
      'request_id': requestId,
      'blob_key': relativePath,
      'offset': 0,
      'limit': chunkSize,
    });

    final meta = await SyncProtocolService.instance.waitBlobResponse(
      requestId,
      timeout: const Duration(seconds: 30),
    );
    if (meta == null || meta['error'] != null) {
      throw StateError(meta?['error']?.toString() ?? 'blob meta failed');
    }

    final totalSize = meta['total_size'] as int? ?? 0;
    final sha256Expected = meta['sha256'] as String? ?? '';
    final buffer = BytesBuilder(copy: false);

    void appendChunk(Map<String, dynamic> chunk) {
      if (chunk['data_b64'] != null && (chunk['data_b64'] as String).isNotEmpty) {
        buffer.add(base64.decode(chunk['data_b64'] as String));
      }
    }

    appendChunk(meta);
    if (meta['done'] != true && totalSize > 0) {
      var offset = buffer.length;
      while (offset < totalSize) {
        final chunkReqId = _uuid.v4();
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_blob_req',
          'request_id': chunkReqId,
          'blob_key': relativePath,
          'offset': offset,
          'limit': chunkSize,
        });
        final chunk = await SyncProtocolService.instance.waitBlobResponse(
          chunkReqId,
          timeout: const Duration(seconds: 60),
        );
        if (chunk == null) throw StateError('blob chunk timeout at offset $offset');
        appendChunk(chunk);
        offset = buffer.length;
        if (chunk['done'] == true) break;
      }
    }

    final bytes = buffer.takeBytes();
    if (sha256Expected.isNotEmpty) {
      final got = sha256.convert(bytes).toString();
      if (got != sha256Expected) {
        throw StateError('blob sha256 mismatch');
      }
    }

    final saved = await _writeBytesToRelativePath(relativePath, bytes);
    await _registerCache(relativePath, sha256Expected, bytes.length);
    await _trimBlobCacheIfNeeded();
    return saved;
  }

  /// App 设备：将本地附件推送到 Primary。
  Future<void> pushBlobToPrimary(String relativePath, {String? peerId}) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role == DeviceRole.primary) return;

    final file = await _files.getFile(relativePath);
    if (file == null) return;

    final targetPeerId = peerId ?? await _primaryOnlyPeerId();
    if (targetPeerId == null) return;

    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    var offset = 0;

    while (offset < bytes.length) {
      final end = (offset + chunkSize < bytes.length) ? offset + chunkSize : bytes.length;
      final slice = bytes.sublist(offset, end);
      final reqId = _uuid.v4();
      await PeerConnectionManager.instance.sendControl(targetPeerId, {
        'type': 'sync_blob_push',
        'request_id': reqId,
        'blob_key': relativePath,
        'offset': offset,
        'total_size': bytes.length,
        'sha256': hash,
        'data_b64': base64.encode(slice),
        'done': end >= bytes.length,
      });
      final ack = await SyncProtocolService.instance.waitBlobPushAck(
        reqId,
        timeout: const Duration(seconds: 60),
      );
      if (ack?['ok'] != true) {
        _log.warning('blob push ack failed at $offset', tag: _tag);
        return;
      }
      offset = end;
    }
  }

  /// Primary / Backup：响应 blob 拉取请求。
  Future<Map<String, dynamic>?> readBlobChunk(String blobKey, int offset, int limit) async {
    final file = await _files.getFile(blobKey);
    if (file == null) return null;

    final total = await file.length();
    if (offset >= total) {
      return {'total_size': total, 'offset': offset, 'bytes': 0, 'data_b64': '', 'done': true};
    }

    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      final toRead = (offset + limit > total) ? total - offset : limit;
      final data = await raf.read(toRead);
      return {
        'total_size': total,
        'sha256': await sha256OfFile(file),
        'offset': offset,
        'bytes': data.length,
        'data_b64': base64.encode(data),
        'done': offset + data.length >= total,
      };
    } finally {
      await raf.close();
    }
  }

  /// Primary：接收 blob 分块写入（严格顺序校验）。
  Future<bool> receiveBlobPush({
    required String blobKey,
    required int offset,
    required int totalSize,
    required String sha256Expected,
    required Uint8List chunk,
    required bool done,
  }) async {
    final partial = _partialUploads[blobKey];
    if (offset == 0) {
      _partialUploads[blobKey] = _PartialBlobUpload(
        totalSize: totalSize,
        sha256Expected: sha256Expected,
        receivedBytes: 0,
      );
    } else {
      if (partial == null || partial.receivedBytes != offset) {
        _log.warning('Blob push out-of-order for $blobKey at offset $offset', tag: _tag);
        _partialUploads.remove(blobKey);
        return false;
      }
    }

    final fullPath = await _files.getFullPath(blobKey);
    final file = File(fullPath);
    await file.parent.create(recursive: true);

    if (offset == 0) {
      await file.writeAsBytes(chunk, flush: true);
    } else {
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      await raf.writeFrom(chunk);
      await raf.close();
    }

    final state = _partialUploads[blobKey];
    if (state != null) {
      state.receivedBytes = offset + chunk.length;
    }

    if (!done) return true;

    _partialUploads.remove(blobKey);
    if (sha256Expected.isEmpty) return true;
    final hash = await sha256OfFile(file);
    if (hash != sha256Expected) {
      await file.delete();
      return false;
    }
    return true;
  }

  Future<void> _registerCache(String relativePath, String sha256hex, int size) async {
    await _db.upsertBlobCacheEntry(
      blobKey: blobKeyFromRelativePath(relativePath),
      relativePath: relativePath,
      sha256: sha256hex,
      sizeBytes: size,
    );
  }

  Future<void> _trimBlobCacheIfNeeded() async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.app) return;

    final policy = await _db.getAppCachePolicy();
    var total = await _db.totalBlobCacheBytes();
    if (total <= policy.maxBlobBytes) return;

    final rows = await _db.listBlobCacheEntriesOldestFirst();
    for (final row in rows) {
      if (total <= policy.maxBlobBytes) break;
      final key = row['blob_key'] as String;
      final path = row['relative_path'] as String;
      final size = row['size_bytes'] as int? ?? 0;
      await _files.deleteFile(path);
      await _db.deleteBlobCacheEntry(key);
      total -= size;
    }
  }

  Future<String> _writeBytesToRelativePath(String relativePath, Uint8List bytes) async {
    final fullPath = await _files.getFullPath(relativePath);
    final file = File(fullPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return relativePath;
  }

  Future<List<String>> _storagePeerIdsInOrder() async {
    final peerIds = <String>[];
    for (final device in await StorageDeviceService.devicesInFetchOrder()) {
      final peerId = await StorageDeviceService.peerIdForDevice(device.deviceId);
      if (peerId != null) peerIds.add(peerId);
    }
    return peerIds;
  }

  Future<String?> _primaryOnlyPeerId() async {
    final primary = await AccountIdentityService.instance.primaryDevice();
    if (primary == null) return null;
    return StorageDeviceService.peerIdForDevice(primary.deviceId);
  }
}

class _PartialBlobUpload {
  final int totalSize;
  final String sha256Expected;
  int receivedBytes;

  _PartialBlobUpload({
    required this.totalSize,
    required this.sha256Expected,
    required this.receivedBytes,
  });
}
