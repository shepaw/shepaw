import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'local_cas.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 缓存校验读取的结果。
class RemoteReadResult {
  RemoteReadResult({required this.bytes, required this.stale});

  final Uint8List bytes;

  /// true = 来自缓存且 master 离线，可能不是最新（spec §7-3）。
  final bool stale;
}

/// 读路径缓存校验（docs/storage_protocol_spec.md §7，方案 §6.4 读路径）。
///
/// 1. 有缓存 → meta 比对 hash：一致零内容流量；不一致重下并更新缓存。
/// 2. 无缓存且在线 → 拉取并写缓存。
/// 3. 离线：有缓存标注 stale 使用；无缓存报错。
/// 4. `not_found`：有限退避重试（URI 可能先于镜像送达 master，方案 §12）。
///
/// 缓存布局：`<store>/.cache/<device>/<space>/<path>`（硬链接到 CAS blob）
/// + `<path>.meta.json`（hash/size/fetched_at）。
class RemoteReadService {
  RemoteReadService._();
  static final RemoteReadService instance = RemoteReadService._();

  static const _tag = 'RemoteRead';

  /// not_found 最多额外重试次数（总尝试 = 1 + 本值）。
  static const maxNotFoundRetries = 4;

  final _log = LoggerService();

  LocalCas? _cas;
  Directory? _cacheRoot;

  /// 测试注入点：自定义 server 调用（默认经 StoreService 到 master）。
  Future<Map<String, dynamic>?> Function(String serverDeviceId, StoreFrame frame)?
      serverCaller;

  /// 测试注入：重试等待；生产默认 200ms × 2^attempt，上限 2s。
  Future<void> Function(int attempt)? retryWait;

  Future<LocalCas> _localCas() async {
    final existing = _cas;
    if (existing != null) return existing;
    final root = await StoreService.instance.storeRoot();
    _cacheRoot = Directory(p.join(root.path, '.cache'));
    return _cas = LocalCas(storeRoot: root);
  }

  Future<Map<String, dynamic>?> _callServer(
      String serverDeviceId, StoreFrame frame) {
    final injected = serverCaller;
    if (injected != null) return injected(serverDeviceId, frame);
    return StoreService.instance.callPeer(serverDeviceId, frame);
  }

  Future<void> _waitBeforeRetry(int attempt) async {
    final custom = retryWait;
    if (custom != null) {
      await custom(attempt);
      return;
    }
    final ms = 200 * (1 << attempt);
    await Future<void>.delayed(
        Duration(milliseconds: ms > 2000 ? 2000 : ms));
  }

  /// 缓存校验读取。master 无缓存且离线时抛 StateError('master_offline')。
  /// 短暂 not_found（镜像未送达）会退避重试。
  Future<RemoteReadResult> readVerified({
    required String serverDeviceId,
    required String deviceId,
    required String space,
    required String path,
    String? grantId,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= maxNotFoundRetries; attempt++) {
      try {
        return await _readVerifiedOnce(
          serverDeviceId: serverDeviceId,
          deviceId: deviceId,
          space: space,
          path: path,
          grantId: grantId,
        );
      } on StoreException catch (e) {
        lastError = e;
        if (e.code != StoreError.notFound || attempt == maxNotFoundRetries) {
          rethrow;
        }
        _log.info(
            'not_found retry ${attempt + 1}/$maxNotFoundRetries '
            'for $deviceId/$space/$path',
            tag: _tag);
        await _waitBeforeRetry(attempt);
      }
    }
    throw lastError!;
  }

  Future<RemoteReadResult> _readVerifiedOnce({
    required String serverDeviceId,
    required String deviceId,
    required String space,
    required String path,
    String? grantId,
  }) async {
    final cas = await _localCas();
    final cacheFile = File(p.join(
        _cacheRoot!.path, deviceId, space, path));
    final metaFile = File('${cacheFile.path}.meta.json');

    // 1. meta 校验（在线时）
    final metaRes = await _callServer(
        serverDeviceId,
        StoreFrame(op: StoreOp.meta, payload: {
          'space': space,
          'device': deviceId,
          'path': path,
          if (grantId != null) 'grant': grantId,
        }));
    final offline = metaRes == null ||
        metaRes['_error'] == StoreError.masterOffline ||
        metaRes['_error'] == StoreError.notPaired;

    if (offline) {
      // 3. 离线：有缓存则 stale 使用
      if (await cacheFile.exists() && await metaFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        return RemoteReadResult(bytes: bytes, stale: true);
      }
      throw StateError('master_offline');
    }
    if (metaRes.containsKey('_error')) {
      final code = metaRes['_error'] as String;
      if (code == StoreError.notFound) {
        throw StoreException(StoreError.notFound, path);
      }
      throw StateError('meta failed: $code');
    }

    final remoteHash = metaRes['sha256'] as String;
    final remoteSize = metaRes['size'] as int;

    // 2. 缓存命中且 hash 一致 → 零内容流量
    if (await cacheFile.exists() && await metaFile.exists()) {
      final cachedMeta = jsonDecode(await metaFile.readAsString());
      if (cachedMeta['sha256'] == remoteHash) {
        await cas.touch(remoteHash);
        return RemoteReadResult(
            bytes: await cacheFile.readAsBytes(), stale: false);
      }
    }

    // 2b. CAS 里有同 hash blob → 免下载直接物化
    final blob = await cas.get(remoteHash);
    if (blob != null) {
      final bytes = await blob.readAsBytes();
      await _writeCache(cacheFile, metaFile, remoteHash, bytes);
      return RemoteReadResult(bytes: bytes, stale: false);
    }

    // 2c. 下载并更新缓存
    final bytes = await _readAll(
        serverDeviceId, deviceId, space, path, remoteSize, grantId);
    final actualHash = crypto.sha256.convert(bytes).toString();
    if (actualHash != remoteHash) {
      throw StateError('hash mismatch after download');
    }
    await cas.put(bytes, synced: true);
    await _writeCache(cacheFile, metaFile, remoteHash, bytes);
    // 容量控制（LRU，仅 synced 可淘汰）
    await cas.evict();
    return RemoteReadResult(bytes: bytes, stale: false);
  }

  Future<void> _writeCache(
      File cacheFile, File metaFile, String hash, Uint8List bytes) async {
    final cas = await _localCas();
    await cas.materialize(hash, cacheFile.path);
    await metaFile.writeAsString(jsonEncode({
      'sha256': hash,
      'size': bytes.length,
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  Future<Uint8List> _readAll(String serverDeviceId, String deviceId,
      String space, String path, int size, String? grantId) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final res = await _callServer(
          serverDeviceId,
          StoreFrame(op: StoreOp.read, payload: {
            'space': space,
            'device': deviceId,
            'path': path,
            'offset': offset,
            'length': LocalStore.maxReadChunk,
            if (grantId != null) 'grant': grantId,
          }));
      if (res == null || res.containsKey('_error')) {
        throw StateError('read failed: ${res?['_error']}');
      }
      final chunk = base64Decode(res['data'] as String);
      builder.add(chunk);
      offset += chunk.length;
      if (res['eof'] == true || chunk.isEmpty) break;
    }
    final bytes = builder.toBytes();
    if (bytes.length != size) {
      throw StateError('size mismatch: ${bytes.length} != $size');
    }
    return bytes;
  }
}
