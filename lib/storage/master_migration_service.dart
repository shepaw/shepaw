import 'dart:async';

import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_cursor_store.dart';
import 'device_identity.dart';
import 'mirror_reprotect_service.dart';
import 'mirror_seed_service.dart';
import 'store_protocol.dart';
import 'store_service.dart';
import 'sync_engine.dart';

/// master 迁移结果。
class MigrationResult {
  MigrationResult({
    required this.newMasterId,
    required this.epoch,
    required this.oldMasterReachable,
    required this.seededCursors,
    required this.broadcastPeers,
    this.seededFiles = 0,
  });

  final String newMasterId;
  final int epoch;
  final bool oldMasterReachable;
  final Map<String, int> seededCursors;
  final int broadcastPeers;

  /// 从旧 master 拷贝到本机的文件数（不可达时为 0）。
  final int seededFiles;
}

/// master 迁移编排（docs/storage_space_plan.md §6.5，M6）。
///
/// 流程：
/// 1. 新 master（本机）向旧 master 拉 `sync.cursors`；不可达则用本机游标账副本；
/// 2. 旧 master 可达时，按游标设备列表差量拉取镜像文件到本机（§6.5 种子拷贝）；
/// 3. 种子合并进本机 [DeviceCursorStore]；
/// 4. 提升 epoch、写本机 master 指针；
/// 5. 向各 owner 端广播 `master.pointer`（无 req_id）；
/// 6. 触发 [SyncEngine.syncNow]；可选再保护镜像树。
class MasterMigrationService {
  MasterMigrationService._();
  static final MasterMigrationService instance = MasterMigrationService._();

  static const _tag = 'MasterMigrate';
  static const epochKey = 'storage.master_epoch';

  final _log = LoggerService();
  final _peerStorage = PeerStorageService();
  final _manager = PeerConnectionManager.instance;

  /// 本机升为 master（方案 §6.5：新 master 驱动）。
  Future<MigrationResult> promoteSelf({bool reprotect = true}) async {
    final self = await DeviceIdentity.deviceId();
    final oldMaster = await StoreService.instance.masterDeviceId();
    final store = await StoreService.instance.localStore();
    final cursors = DeviceCursorStore(storeRoot: store.root);

    var reachable = false;
    var seed = <String, int>{};
    var seededFiles = 0;
    if (oldMaster != self) {
      final res = await StoreService.instance.callPeer(
        oldMaster,
        StoreFrame(op: StoreOp.syncCursors, payload: const {}),
      );
      if (res != null && !res.containsKey('_error') && res['cursors'] is Map) {
        reachable = true;
        seed = (res['cursors'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toInt()));
        _log.info('seeded ${seed.length} cursors from old master $oldMaster',
            tag: _tag);
        // 差量镜像种子：补齐他端历史 blob（改指前完成）
        final deviceIds = <String>{...seed.keys};
        try {
          final stats = await StoreService.instance.callPeer(
            oldMaster,
            StoreFrame(op: StoreOp.stats, payload: const {}),
          );
          final devices = (stats?['devices'] as Map?)?.keys;
          if (devices != null) {
            deviceIds.addAll(devices.cast<String>());
          }
        } catch (_) {}
        seededFiles = await MirrorSeedService.instance.seedFromOldMaster(
          oldMasterId: oldMaster,
          deviceIds: deviceIds,
          store: store,
        );
      } else {
        seed = await cursors.all();
        _log.warning(
            'old master unreachable ($oldMaster); using local cursor seed '
            '(${seed.length} entries)',
            tag: _tag);
      }
    } else {
      seed = await cursors.all();
    }

    final merged = await cursors.seed(seed);
    final epoch = await _bumpEpoch();
    await StoreService.instance.setMasterDeviceId(self);

    final broadcast = await broadcastPointer(
      masterId: self,
      epoch: epoch,
      fromDeviceId: self,
    );

    SyncEngine.instance.poke();
    if (reprotect) {
      unawaited(MirrorReprotectService.instance.runIfMaster());
    }

    _log.info(
        'promoted self as master epoch=$epoch '
        '(old=$oldMaster reachable=$reachable seededFiles=$seededFiles)',
        tag: _tag);
    return MigrationResult(
      newMasterId: self,
      epoch: epoch,
      oldMasterReachable: reachable || oldMaster == self,
      seededCursors: merged,
      broadcastPeers: broadcast,
      seededFiles: seededFiles,
    );
  }

  /// 请求对方设备执行 [promoteSelf]（UI 选择他端为新 master）。
  Future<MigrationResult?> requestPromote(String targetDeviceId) async {
    final self = await DeviceIdentity.deviceId();
    if (targetDeviceId == self) return promoteSelf();
    final res = await StoreService.instance.callPeer(
      targetDeviceId,
      StoreFrame(op: StoreOp.masterMigrate, payload: const {}),
    );
    if (res == null || res.containsKey('_error')) {
      throw StateError('migrate failed: ${res?['_error']}');
    }
    // 对端升主后也会广播；本机仍应用一次以防广播丢失
    final epoch = res['epoch'] as int? ?? 0;
    final master = res['master'] as String? ?? targetDeviceId;
    await applyPointer(
      masterId: master,
      epoch: epoch,
      fromDeviceId: targetDeviceId,
    );
    return MigrationResult(
      newMasterId: master,
      epoch: epoch,
      oldMasterReachable: res['old_master_reachable'] as bool? ?? false,
      seededCursors: (res['cursors'] as Map? ?? const {})
          .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      broadcastPeers: res['broadcast_peers'] as int? ?? 0,
    );
  }

  Future<int> currentEpoch() async {
    final raw = await LocalDatabaseService().getUserValue(epochKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<int> _bumpEpoch() async {
    final next = (await currentEpoch()) + 1;
    await LocalDatabaseService().setUserValue(epochKey, '$next');
    return next;
  }

  Future<void> _setEpoch(int epoch) async {
    await LocalDatabaseService().setUserValue(epochKey, '$epoch');
  }

  /// 向所有 owner 级配对端广播指针（无 req_id 通知帧）。
  Future<int> broadcastPointer({
    required String masterId,
    required int epoch,
    required String fromDeviceId,
  }) async {
    final peers = await _peerStorage.loadAllPeers();
    var n = 0;
    for (final peer in peers) {
      if (peer.trustLevel != TrustLevel.owner) continue;
      if (peer.fingerprint == fromDeviceId) continue;
      try {
        final ok = await _manager.sendControl(
          peer.id,
          StoreFrame(op: StoreOp.masterPointer, payload: <String, dynamic>{
            'master': masterId,
            'epoch': epoch,
            'from': fromDeviceId,
          }).toJson(),
        );
        if (ok) n++;
      } catch (e) {
        _log.warning('broadcast to ${peer.fingerprint} failed: $e', tag: _tag);
      }
    }
    return n;
  }

  /// 应用指针（广播入站 / query 响应）。仅当 [epoch] 更新时改指。
  Future<bool> applyPointer({
    required String masterId,
    required int epoch,
    required String fromDeviceId,
  }) async {
    if (!isValidDeviceId(masterId) || epoch <= 0) return false;
    final localEpoch = await currentEpoch();
    if (epoch < localEpoch) {
      _log.info(
          'ignore stale pointer epoch=$epoch < local=$localEpoch from $fromDeviceId',
          tag: _tag);
      return false;
    }
    if (epoch == localEpoch) {
      final current = await StoreService.instance.masterDeviceId();
      if (current == masterId) return false;
      // 同 epoch 不同 master：取广播为准（罕见竞态）
    }
    await _setEpoch(epoch);
    await StoreService.instance.setMasterDeviceId(masterId);
    _log.info('master pointer → $masterId epoch=$epoch (from $fromDeviceId)',
        tag: _tag);
    SyncEngine.instance.poke();
    return true;
  }

  /// 向指定设备查询当前指针。
  Future<({String master, int epoch})?> queryPointer(String peerDeviceId) async {
    final res = await StoreService.instance.callPeer(
      peerDeviceId,
      StoreFrame(op: StoreOp.masterPointerQuery, payload: const {}),
    );
    if (res == null || res.containsKey('_error')) return null;
    final master = res['master'] as String?;
    final epoch = res['epoch'] as int? ?? 0;
    if (master == null || !isValidDeviceId(master)) return null;
    return (master: master, epoch: epoch);
  }
}
