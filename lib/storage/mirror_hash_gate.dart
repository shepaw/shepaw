import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 单条路径对账差异（方案 §6.5 哈希门闩）。
class HashMismatch {
  HashMismatch({
    required this.deviceId,
    required this.space,
    required this.path,
    required this.kind,
    this.remoteSha,
    this.localSha,
  });

  final String deviceId;
  final String space;
  final String path;

  /// `missing_local` | `missing_remote` | `hash_mismatch`
  final String kind;
  final String? remoteSha;
  final String? localSha;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device': deviceId,
        'space': space,
        'path': path,
        'kind': kind,
        if (remoteSha != null) 'remote_sha256': remoteSha,
        if (localSha != null) 'local_sha256': localSha,
      };
}

/// 单设备内容摘要（跨分区）。
class DeviceHashDigest {
  DeviceHashDigest({
    required this.deviceId,
    required this.remoteDigest,
    required this.localDigest,
  });

  final String deviceId;
  final String remoteDigest;
  final String localDigest;

  bool get matched => remoteDigest == localDigest;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device': deviceId,
        'remote_digest': remoteDigest,
        'local_digest': localDigest,
        'matched': matched,
      };
}

/// 升主前内容哈希门闩结果（软校验：默认不阻断升主）。
class HashGateResult {
  HashGateResult({
    required this.ran,
    required this.devices,
    required this.mismatches,
  });

  /// 未跑（旧 master 不可达 / 跳过）时为 false。
  final bool ran;
  final List<DeviceHashDigest> devices;
  final List<HashMismatch> mismatches;

  bool get ok => !ran || mismatches.isEmpty;

  static HashGateResult skipped() =>
      HashGateResult(ran: false, devices: const [], mismatches: const []);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ran': ran,
        'ok': ok,
        'devices': [for (final d in devices) d.toJson()],
        'mismatches': [for (final m in mismatches) m.toJson()],
        'mismatch_count': mismatches.length,
      };
}

/// 升主前逐设备内容哈希门闩（方案 §6.5 / §13）。
///
/// 旧 master 可达且种子拷贝之后、改指之前：对每个他端目录对比
/// 旧 master `list(seed:true)` 与本机 `list` 的 path→sha256；
/// 默认只报告，不阻断升主（附录 A：去掉硬「哈希一致才改指」）。
class MirrorHashGate {
  MirrorHashGate._();
  static final MirrorHashGate instance = MirrorHashGate._();

  static const _tag = 'MirrorHashGate';

  /// list 上限（避免默认 1000 截断导致假缺口）。
  static const listLimit = 50000;

  /// 结果中最多带回的 mismatch 条数。
  static const maxReportedMismatches = 50;

  final _log = LoggerService();

  /// 测试注入：替代 [StoreService.callPeer]。
  Future<Map<String, dynamic>?> Function(String peerId, StoreFrame frame)?
      peerCaller;

  Future<Map<String, dynamic>?> _callPeer(String peerId, StoreFrame frame) {
    final injected = peerCaller;
    if (injected != null) return injected(peerId, frame);
    return StoreService.instance.callPeer(peerId, frame);
  }

  /// 对账 [deviceIds]；跳过本机目录。
  Future<HashGateResult> verify({
    required String oldMasterId,
    required Iterable<String> deviceIds,
    LocalStore? store,
  }) async {
    final local = store ?? await StoreService.instance.localStore();
    final self = await DeviceIdentity.deviceId();
    final digests = <DeviceHashDigest>[];
    final mismatches = <HashMismatch>[];

    for (final deviceId in deviceIds) {
      if (!isValidDeviceId(deviceId)) continue;
      if (deviceId == self) continue;
      final remoteMap = <String, String>{}; // key: space/path
      final localMap = <String, String>{};
      for (final space in StoreSpace.all) {
        try {
          final remote = await _listRemote(oldMasterId, deviceId, space);
          for (final e in remote.entries) {
            remoteMap['$space/${e.key}'] = e.value;
          }
        } catch (e, st) {
          _log.warning('remote list $deviceId/$space failed: $e', tag: _tag);
          _log.debug('$st', tag: _tag);
        }
        try {
          final localEntries = await local.list(
            deviceId,
            space,
            limit: listLimit,
          );
          for (final e in localEntries) {
            localMap['$space/${e.path}'] = e.sha256;
          }
        } catch (e, st) {
          _log.warning('local list $deviceId/$space failed: $e', tag: _tag);
          _log.debug('$st', tag: _tag);
        }
      }

      digests.add(DeviceHashDigest(
        deviceId: deviceId,
        remoteDigest: _digestOf(remoteMap),
        localDigest: _digestOf(localMap),
      ));

      final keys = {...remoteMap.keys, ...localMap.keys}.toList()..sort();
      for (final key in keys) {
        if (mismatches.length >= maxReportedMismatches) break;
        final slash = key.indexOf('/');
        final space = slash < 0 ? key : key.substring(0, slash);
        final path = slash < 0 ? '' : key.substring(slash + 1);
        final r = remoteMap[key];
        final l = localMap[key];
        if (r != null && l == null) {
          mismatches.add(HashMismatch(
            deviceId: deviceId,
            space: space,
            path: path,
            kind: 'missing_local',
            remoteSha: r,
          ));
        } else if (r == null && l != null) {
          mismatches.add(HashMismatch(
            deviceId: deviceId,
            space: space,
            path: path,
            kind: 'missing_remote',
            localSha: l,
          ));
        } else if (r != null && l != null && r != l) {
          mismatches.add(HashMismatch(
            deviceId: deviceId,
            space: space,
            path: path,
            kind: 'hash_mismatch',
            remoteSha: r,
            localSha: l,
          ));
        }
      }
    }

    final result = HashGateResult(
      ran: true,
      devices: digests,
      mismatches: mismatches,
    );
    _log.info(
        'hash gate: devices=${digests.length} '
        'mismatches=${mismatches.length} ok=${result.ok}',
        tag: _tag);
    return result;
  }

  Future<Map<String, String>> _listRemote(
    String peerId,
    String deviceId,
    String space,
  ) async {
    final res = await _callPeer(
      peerId,
      StoreFrame(op: StoreOp.list, payload: {
        'space': space,
        'device': deviceId,
        'path': '',
        'seed': true,
        'limit': listLimit,
      }),
    );
    if (res == null || res.containsKey('_error')) {
      final code = res?['_error'];
      if (code == StoreError.notFound) return {};
      throw StateError('list failed: $code');
    }
    final entries = (res['entries'] as List? ?? const [])
        .cast<Map>()
        .map((e) => e.cast<String, dynamic>());
    final out = <String, String>{};
    for (final e in entries) {
      final path = e['path'] as String? ?? '';
      final sha = e['sha256'] as String? ?? '';
      if (path.isEmpty || sha.isEmpty) continue;
      out[path] = sha;
    }
    return out;
  }

  /// 稳定内容摘要：排序后的 `key\\0sha\\n` 拼接再 sha256。
  static String _digestOf(Map<String, String> pathToSha) {
    final keys = pathToSha.keys.toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf.write(k);
      buf.write('\x00');
      buf.write(pathToSha[k]);
      buf.write('\n');
    }
    return crypto.sha256.convert(utf8.encode(buf.toString())).toString();
  }
}
