import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'mirror_hash_gate.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 升主时从旧 master 拉镜像种子（方案 §6.5）。
///
/// 在改指之前执行：经 peer `list`/`meta`/`read`（`seed: true`）拉取他端目录，
/// 写入本机 [LocalStore]（非本机 deviceId 不进 SyncJournal）。
class MirrorSeedService {
  MirrorSeedService._();
  static final MirrorSeedService instance = MirrorSeedService._();

  static const _tag = 'MirrorSeed';
  final _log = LoggerService();

  /// 测试注入：替代 [StoreService.callPeer]。
  Future<Map<String, dynamic>?> Function(String peerId, StoreFrame frame)?
      peerCaller;

  Future<Map<String, dynamic>?> _callPeer(String peerId, StoreFrame frame) {
    final injected = peerCaller;
    if (injected != null) return injected(peerId, frame);
    return StoreService.instance.callPeer(peerId, frame);
  }

  /// 从 [oldMasterId] 拉取 [deviceIds] 各分区文件；跳过本机目录与已一致文件。
  /// 返回成功写入的文件数，以及**完整成功**（四分区均无抛错）的设备集合。
  Future<({int written, Set<String> completedDevices})> seedFromOldMaster({
    required String oldMasterId,
    required Iterable<String> deviceIds,
    LocalStore? store,
  }) async {
    final local = store ?? await StoreService.instance.localStore();
    final self = await DeviceIdentity.deviceId();
    var written = 0;
    final completed = <String>{};
    for (final deviceId in deviceIds) {
      if (!isValidDeviceId(deviceId)) continue;
      if (deviceId == self) {
        completed.add(deviceId); // 本机目录已是权威
        continue;
      }
      var deviceOk = true;
      for (final space in StoreSpace.all) {
        try {
          written += await _seedSpace(
            oldMasterId: oldMasterId,
            deviceId: deviceId,
            space: space,
            local: local,
          );
        } catch (e, st) {
          deviceOk = false;
          _log.warning(
              'seed $deviceId/$space failed: $e', tag: _tag);
          _log.debug('$st', tag: _tag);
        }
      }
      if (deviceOk) completed.add(deviceId);
    }
    _log.info(
        'mirror seed done: wrote $written files from $oldMasterId '
        '(completed=${completed.length})',
        tag: _tag);
    return (written: written, completedDevices: completed);
  }

  Future<int> _seedSpace({
    required String oldMasterId,
    required String deviceId,
    required String space,
    required LocalStore local,
  }) async {
    final listRes = await _callPeer(
      oldMasterId,
      StoreFrame(op: StoreOp.list, payload: {
        'space': space,
        'device': deviceId,
        'path': '',
        'seed': true,
        'limit': MirrorHashGate.listLimit,
      }),
    );
    if (listRes == null || listRes.containsKey('_error')) {
      final code = listRes?['_error'];
      if (code == StoreError.notFound) return 0;
      throw StateError('list failed: $code');
    }
    final entries = (listRes['entries'] as List? ?? const [])
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    var written = 0;
    for (final e in entries) {
      final path = e['path'] as String? ?? '';
      final sha = e['sha256'] as String? ?? '';
      final size = (e['size'] as num?)?.toInt() ?? 0;
      if (path.isEmpty || sha.isEmpty) continue;
      // 跳过再保护包可选：仍应拷贝，便于新 master 持有灾难恢复副本
      if (await _localMatches(local, deviceId, space, path, sha)) {
        continue;
      }
      final bytes = await _readAll(oldMasterId, deviceId, space, path, size);
      final actual = crypto.sha256.convert(bytes).toString();
      if (actual != sha) {
        _log.warning('hash mismatch seed $deviceId/$space/$path', tag: _tag);
        continue;
      }
      await _writeLocal(local, deviceId, space, path, bytes, sha);
      written++;
    }
    return written;
  }

  Future<bool> _localMatches(
    LocalStore local,
    String deviceId,
    String space,
    String path,
    String sha,
  ) async {
    try {
      final meta = await local.meta(deviceId, space, path);
      return meta['sha256'] == sha;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return false;
      rethrow;
    }
  }

  Future<Uint8List> _readAll(
    String peerId,
    String deviceId,
    String space,
    String path,
    int size,
  ) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final res = await _callPeer(
        peerId,
        StoreFrame(op: StoreOp.read, payload: {
          'space': space,
          'device': deviceId,
          'path': path,
          'offset': offset,
          'length': LocalStore.maxReadChunk,
          'seed': true,
        }),
      );
      if (res == null || res.containsKey('_error')) {
        throw StateError('read failed: ${res?['_error']}');
      }
      final chunk = base64Decode(res['data'] as String);
      builder.add(chunk);
      offset += chunk.length;
      if (res['eof'] == true || chunk.isEmpty) break;
    }
    final bytes = builder.toBytes();
    if (size > 0 && bytes.length != size) {
      throw StateError('size mismatch: ${bytes.length} != $size');
    }
    return bytes;
  }

  Future<void> _writeLocal(
    LocalStore local,
    String deviceId,
    String space,
    String path,
    Uint8List bytes,
    String sha,
  ) async {
    final (uid, _) = await local.writeBegin(
      deviceId: deviceId,
      space: space,
      path: path,
      size: bytes.length,
      sha256: sha,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final end = offset + LocalStore.maxReadChunk > bytes.length
          ? bytes.length
          : offset + LocalStore.maxReadChunk;
      await local.writeChunk(
          deviceId, space, uid, offset, bytes.sublist(offset, end));
      offset = end;
    }
    final (committed, failed) = await local.commit(deviceId, space, [uid]);
    if (failed.isNotEmpty || committed.isEmpty) {
      throw StateError('seed commit failed: $failed');
    }
  }
}
