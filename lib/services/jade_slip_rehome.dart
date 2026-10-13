import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/jade_slip.dart';
import '../storage/device_identity.dart';
import '../storage/host_pouch_documents.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';

/// 把「各 device 目录各存一份、读时 merge」时代的玉简，回迁到主机权威目录。
///
/// 玉简改成主机唯一权威之前，手机建的简写在 `slips/<手机指纹>/`，桌面端靠
/// `mergeCopies` 才看得到（见 docs/jade_slip_host_authority_decision.md）。切到
/// 「只读主机目录」后这些会一起消失，所以在第一次读到某台主机的玉简目录时，
/// 先把残留搬过去。
///
/// - 幂等：按主机指纹记标记（[markerKey]），换主机自然重跑。
/// - 只在 [ensure] 里跑一次，失败不抛给调用方——迁移不该挡住列表和编辑。
class JadeSlipRehome {
  JadeSlipRehome._();

  static const _tag = 'JadeSlipRehome';

  /// 已经回迁到哪台主机（Noise 指纹）。
  static const markerKey = 'storage.slips_rehomed_device';

  static final _log = LoggerService();

  /// 本进程内已处理（含「无可迁」和「失败」）的主机，避免每次 list 都重跑。
  static String? _settled;
  static String? _inflightHost;
  static Future<void>? _inflight;

  /// 测试注入：绕过 sqflite（纯单元测试里没有插件）。
  @visibleForTesting
  static Future<String?> Function()? debugReadMarker;

  @visibleForTesting
  static Future<void> Function(String hostId)? debugWriteMarker;

  @visibleForTesting
  static void resetForTest() {
    _settled = null;
    _inflightHost = null;
    _inflight = null;
    debugReadMarker = null;
    debugWriteMarker = null;
  }

  /// 幂等入口。同一进程内同一台主机只跑一次。
  ///
  /// 唯一不落定的情形是「主机不在线」：客户端读到离线是常态，要等连上再试。
  static Future<void> ensure({required HostPouchDocuments docs}) {
    final hostId = docs.deviceId;
    if (!isValidDeviceId(hostId) || _settled == hostId) {
      return Future<void>.value();
    }
    final running = _inflight;
    if (running != null && _inflightHost == hostId) return running;
    late final Future<void> run;
    run = _run(docs, hostId).whenComplete(() {
      if (identical(_inflight, run)) {
        _inflight = null;
        _inflightHost = null;
      }
    });
    _inflight = run;
    _inflightHost = hostId;
    return run;
  }

  static Future<void> _run(HostPouchDocuments docs, String hostId) async {
    if (await _readMarker() == hostId) {
      _settled = hostId;
      return;
    }
    try {
      final moved = docs.isRemote
          ? await _rehomeClient(docs, hostId)
          : await _rehomeHost(docs, hostId);
      _settled = hostId;
      await _writeMarker(hostId);
      if (moved > 0) {
        _log.info('rehomed $moved 玉简 into $hostId', tag: _tag);
      }
    } on HostOfflineException {
      // 主机不在线：不落标记，也不落定，等下次连上再试。
    } catch (e) {
      // 迁移不该挡住列表；本进程不再重试，下次启动再说。
      _log.warning('rehome slips -> $hostId: $e', tag: _tag);
      _settled = hostId;
    }
  }

  /// 主机侧：把本机磁盘上别的 device 目录里的简并进主机目录。
  static Future<int> _rehomeHost(
    HostPouchDocuments docs,
    String hostId,
  ) async {
    final store = docs.localStore;
    if (store == null) return 0;
    var moved = 0;
    for (final device in await store.listDeviceIds()) {
      if (device == hostId) continue;
      final entries = await store.list(
        device,
        StoreSpace.slips,
        depth: 1,
        computeHash: false,
      );
      for (final entry in entries) {
        final id = JadeSlip.idFromRecordPath(entry.path);
        if (id == null) continue;
        if (await _mergeInto(docs, store, from: device, id: id, hostId: hostId)) {
          moved++;
        }
      }
    }
    return moved;
  }

  /// 客户端侧：只搬自己 `slips/<self>/` 的残留，且只在主机在线时做。
  ///
  /// 不去碰本机镜像里别端的目录——那些是历史读缓存，权威在各自设备上。
  static Future<int> _rehomeClient(
    HostPouchDocuments docs,
    String hostId,
  ) async {
    final self = await DeviceIdentity.deviceId();
    if (self.isEmpty || self == hostId) return 0;
    if (!await StoreService.instance.isDeviceOnline(hostId)) {
      // 抛出去让 [_run] 知道「稍后再试」，不要当成功落定。
      throw const HostOfflineException('连不上这台主机');
    }
    final LocalStore store;
    try {
      store = await StoreService.instance.localStore();
    } catch (_) {
      return 0; // 还没有本机 store：没有残留可迁
    }
    final entries = await store.list(
      self,
      StoreSpace.slips,
      depth: 1,
      computeHash: false,
    );
    var moved = 0;
    for (final entry in entries) {
      final id = JadeSlip.idFromRecordPath(entry.path);
      if (id == null) continue;
      if (await _mergeInto(docs, store, from: self, id: id, hostId: hostId)) {
        moved++;
      }
    }
    return moved;
  }

  /// 把 `<from>` 设备上的 `<id>.json` 并进主机目录：附件一并搬，旧副本进回收站。
  ///
  /// 返回是否真的写了一条（用于日志计数）。
  static Future<bool> _mergeInto(
    HostPouchDocuments docs,
    LocalStore store, {
    required String from,
    required String id,
    required String hostId,
  }) async {
    final legacy = await _readSlipFrom(store, from, '$id.json', hostId);
    final existing = legacy == null ? null : await _readSlipFromDocs(docs, '$id.json');
    if (legacy != null) {
      final merged = (existing == null
              ? legacy
              : JadeSlip.mergeCopies(existing, legacy))
          .copyWith(deviceId: hostId);
      await docs.writeBytes(StoreSpace.slips, merged.relPath, _encode(merged));
    }
    // 记录缺失（上次迁到一半）时附件目录仍要搬。
    await _moveAttachments(docs, store, from: from, id: id);
    await _recycle(store, from, id);
    return legacy != null;
  }

  /// 搬 `<from>/slips/<id>/files/*`。附件名含 attId，主机已有同名就跳过。
  static Future<void> _moveAttachments(
    HostPouchDocuments docs,
    LocalStore store, {
    required String from,
    required String id,
  }) async {
    final dir = '$id/files';
    final src = await store.list(
      from,
      StoreSpace.slips,
      prefix: dir,
      depth: 1,
      computeHash: false,
    );
    if (src.isEmpty) return;
    final dst = await docs.list(StoreSpace.slips, prefix: dir);
    final have = {for (final e in dst) e.path};
    for (final entry in src) {
      if (entry.isDir || have.contains(entry.path)) continue;
      final bytes = await _readAll(store, from, StoreSpace.slips, entry.path);
      if (bytes == null) continue;
      await docs.writeBytes(StoreSpace.slips, entry.path, bytes);
    }
  }

  /// 旧副本进主机自己的回收站（可恢复）。记录与附件目录分开删。
  static Future<void> _recycle(
    LocalStore store,
    String device,
    String id,
  ) async {
    for (final path in [id, '$id.json']) {
      try {
        await store.delete(device, StoreSpace.slips, path);
      } on StoreException catch (e) {
        if (e.code != StoreError.notFound) rethrow;
      }
    }
  }

  static Future<JadeSlip?> _readSlipFrom(
    LocalStore store,
    String device,
    String path,
    String deviceId,
  ) async {
    final bytes = await _readAll(store, device, StoreSpace.slips, path);
    return bytes == null ? null : _decode(bytes, deviceId);
  }

  static Future<JadeSlip?> _readSlipFromDocs(
    HostPouchDocuments docs,
    String path,
  ) async {
    final bytes = await docs.read(StoreSpace.slips, path);
    return bytes == null ? null : _decode(bytes, docs.deviceId);
  }

  static Future<Uint8List?> _readAll(
    LocalStore store,
    String device,
    String space,
    String path,
  ) async {
    const chunk = LocalStore.maxBinaryReadChunk;
    final pieces = <int>[];
    var offset = 0;
    try {
      while (true) {
        final (data, _, eof) =
            await store.read(device, space, path, offset, chunk);
        pieces.addAll(data);
        if (eof || data.isEmpty) break;
        offset += data.length;
      }
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
    return Uint8List.fromList(pieces);
  }

  static JadeSlip? _decode(Uint8List bytes, String deviceId) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final slip = JadeSlip.fromJson(
        decoded.cast<String, dynamic>(),
        deviceId: deviceId,
      );
      return slip.id.isEmpty ? null : slip;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encode(JadeSlip slip) => Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(slip.toJson())),
      );

  static Future<String?> _readMarker() async {
    final injected = debugReadMarker;
    if (injected != null) return injected();
    try {
      return await LocalDatabaseService().getUserValue(markerKey);
    } catch (_) {
      return null; // 没有本地库（首启 / 测试）：当没做过
    }
  }

  static Future<void> _writeMarker(String hostId) async {
    final injected = debugWriteMarker;
    if (injected != null) {
      await injected(hostId);
      return;
    }
    await LocalDatabaseService().setUserValue(markerKey, hostId);
  }
}
