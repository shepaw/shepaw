import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../services/app_lifecycle_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../services/network_monitor_service.dart';
import '../services/password_service.dart';
import 'device_identity.dart';
import 'gfs_retention.dart';
import 'mirror_reprotect_service.dart';
import 'snapshot_crypto.dart';
import 'snapshot_service.dart';
import 'store_service.dart';
import 'background_snapshot_scheduler.dart';

/// 定期快照状态（UI 告警数据源）。
class ScheduledSnapshotStatus {
  ScheduledSnapshotStatus({
    required this.enabled,
    required this.lastSuccessMs,
    required this.consecutiveFailures,
    required this.keyCached,
    required this.enabledAtMs,
  });

  final bool enabled;
  final int lastSuccessMs;
  final int consecutiveFailures;

  /// 自动快照密钥（缓存的密码哈希 H）是否就位。
  final bool keyCached;

  /// 最近一次开启自动快照的时间（ms）；用于「从未成功」锚点。
  final int enabledAtMs;

  /// 距上次成功（或从未成功则距启用）超过 3 天 → 显著告警（§5.1 / §12）。
  ///
  /// 按墙钟毫秒差计算，与「连续失败次数」解耦（同日多次触发不会误报）。
  bool needsAttentionAt([DateTime? clock]) {
    if (!enabled || !keyCached) return false;
    final nowMs = (clock ?? DateTime.now()).millisecondsSinceEpoch;
    final anchorMs = lastSuccessMs > 0 ? lastSuccessMs : enabledAtMs;
    if (anchorMs <= 0) return false;
    return nowMs - anchorMs > const Duration(days: 3).inMilliseconds;
  }

  bool get needsAttention => needsAttentionAt();
}

/// 定期快照服务（docs/storage_space_plan.md §5.1，M3）。
///
/// 触发点：
/// - App 启动（[ensureStarted] 立即 [checkNow]）；
/// - 运行中每 6h Timer；
/// - 从后台回到前台（[AppLifecycleService.onResume]）；
/// - WiFi/以太网恢复稳定（[NetworkMonitorService.onNetworkSettled]，避免蜂窝流量）；
/// - 移动端系统 BG：WorkManager / BGAppRefresh（[BackgroundSnapshotScheduler]，与上列同一入口去重）。
///
/// 说明：`ForegroundTaskService` 仅用于 Agent 保活，不接入日快照。
///
/// - 密钥：用 [SnapshotCrypto.cachedPasswordHash]（手动验密时已缓存），
///   无缓存则跳过并等待用户手动快照一次；
/// - 每次成功后执行本机 GFS 清理（删除经 sync 镜像）；
/// - 改密事件：失效旧缓存 → 派生新 H 缓存 → 立即全量快照（§5.2）。
class ScheduledSnapshotService {
  ScheduledSnapshotService._();
  static final ScheduledSnapshotService instance =
      ScheduledSnapshotService._();

  static const _tag = 'ScheduledSnapshot';
  static const _enabledKey = 'storage.snapshot.enabled';
  static const _enabledAtKey = 'storage.snapshot.enabled_at_ms';
  static const _lastSuccessKey = 'storage.snapshot.last_success_ms';
  static const _failuresKey = 'storage.snapshot.consecutive_failures';
  static const _passwordChangedAtKey = 'storage.password_changed_at';
  static const _checkInterval = Duration(hours: 6);

  final _log = LoggerService();
  Timer? _timer;
  StreamSubscription<String>? _pwSub;
  StreamSubscription<Duration>? _resumeSub;
  StreamSubscription<void>? _netSub;
  bool _running = false;

  /// 是否应在「网络恢复」路径上跑快照（仅 WiFi/以太网，避免蜂窝灌库）。
  static bool isPreferredNetwork(List<ConnectivityResult> results) {
    return results.any((r) =>
        r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet);
  }

  Future<void> ensureStarted() async {
    if (_timer != null) return;
    await _ensureEnabledAt();
    // 改密 → 新密钥全量快照（§5.2）
    _pwSub ??= PasswordService().passwordChangedEvents.listen((newPassword) {
      unawaited(onPasswordChanged(newPassword));
    });
    // 回前台：隔夜/多日后台后最可靠的移动端触发点
    _resumeSub ??= AppLifecycleService().onResume.listen((_) {
      unawaited(checkNow());
    });
    // WiFi/以太网稳定后再检查（同步镜像更友好）
    _netSub ??= NetworkMonitorService().onNetworkSettled.listen((_) {
      unawaited(checkNowOnPreferredNetwork());
    });
    _timer = Timer.periodic(_checkInterval, (_) => unawaited(checkNow()));
    unawaited(checkNow());
    // 系统 BG（不替代上列前台路径）
    unawaited(BackgroundSnapshotScheduler.ensureRegistered());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _pwSub?.cancel();
    _pwSub = null;
    await _resumeSub?.cancel();
    _resumeSub = null;
    await _netSub?.cancel();
    _netSub = null;
  }

  // ────────────────────────────── 主流程 ──

  /// 网络恢复路径：仅 WiFi/以太网时执行 [checkNow]。
  Future<bool> checkNowOnPreferredNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!isPreferredNetwork(results)) {
        _log.debug('skip network-triggered snapshot: not wifi/ethernet',
            tag: _tag);
        return false;
      }
    } catch (e) {
      _log.debug('connectivity check failed: $e', tag: _tag);
      // 查不到就按「允许」走，避免误伤桌面/无插件环境
    }
    return checkNow();
  }

  /// 到期检查：今天还没有成功快照就生成一份，然后 GFS 清理。
  Future<bool> checkNow() async {
    if (_running) return false;
    _running = true;
    try {
      if (!await _isEnabled()) return false;
      final h = await SnapshotCrypto.cachedPasswordHash();
      if (h == null) {
        _log.debug('no cached key; waiting for a manual snapshot',
            tag: _tag);
        return false;
      }
      final last = await _lastSuccessMs();
      final now = DateTime.now();
      if (last > 0) {
        final lastDay = DateTime.fromMillisecondsSinceEpoch(last);
        if (_sameDay(lastDay, now)) return false;
      }
      await _createAndPrune(h);
      return true;
    } catch (e, st) {
      _log.error('scheduled snapshot failed', tag: _tag, error: e, stackTrace: st);
      await _recordFailure();
      return false;
    } finally {
      _running = false;
    }
  }

  /// 改密事件（§5.2）：旧缓存失效 → 新 H 缓存 → 全量快照。
  /// 由 PasswordService.passwordChangedEvents 触发；测试可直接调用。
  Future<void> onPasswordChanged(String newPassword) async {
    try {
      await SnapshotCrypto.clearCachedPasswordHash();
      final h = await SnapshotCrypto.hashPassword(newPassword);
      await SnapshotCrypto.cachePasswordHash(h);
      final db = LocalDatabaseService();
      await db.setUserValue(_passwordChangedAtKey,
          '${DateTime.now().millisecondsSinceEpoch}');
      _log.info('password changed; creating new-key snapshot', tag: _tag);
      await _createAndPrune(h);
    } catch (e, st) {
      _log.error('post-password-change snapshot failed',
          tag: _tag, error: e, stackTrace: st);
    }
  }

  Future<void> _createAndPrune(Uint8List passwordHash) async {
    await SnapshotService.instance
        .createSnapshot(passwordHash: passwordHash);
    await _recordSuccess();
    // GFS 已在 snapshot commit.retention 内执行；此处再跑一遍作幂等兜底。
    await pruneGfs();
    // §6.6：master 对本机镜像树再保护（与日快照同节奏，有密钥才跑）
    if (await StoreService.instance.isMaster()) {
      try {
        await MirrorReprotectService.instance.run(passwordHash: passwordHash);
      } catch (e, st) {
        _log.warning('mirror reprotect failed: $e', tag: _tag);
        _log.debug('$st', tag: _tag);
      }
    }
  }

  /// GFS 清理（本机 backups；删除经 sync 镜像到 master，§5.1 / §6.4）。
  Future<int> pruneGfs() async {
    final snapshots = await SnapshotService.instance.listSnapshots();
    if (snapshots.isEmpty) return 0;
    final selection = selectGfs([
      for (final s in snapshots) (s.id, s.manifest.createdAtMs),
    ]);
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    var removed = 0;
    for (final s in snapshots) {
      if (selection.deleteIds.contains(s.id)) {
        try {
          await store.delete(deviceId, 'backups', s.id);
        } catch (e) {
          _log.warning('GFS delete ${s.id} failed: $e', tag: _tag);
        }
        removed++;
      }
    }
    if (removed > 0) {
      _log.info('GFS pruned $removed snapshots', tag: _tag);
    }
    return removed;
  }

  // ────────────────────────────── 状态 ──

  Future<ScheduledSnapshotStatus> status() async {
    return ScheduledSnapshotStatus(
      enabled: await _isEnabled(),
      lastSuccessMs: await _lastSuccessMs(),
      consecutiveFailures: await _failures(),
      keyCached: await SnapshotCrypto.cachedPasswordHash() != null,
      enabledAtMs: await _ensureEnabledAt(),
    );
  }

  /// 上次改密时间（UI 标注"需旧密码"用）；从未改密为 0。
  Future<int> passwordChangedAtMs() async {
    final v = await LocalDatabaseService().getUserValue(_passwordChangedAtKey);
    return int.tryParse(v ?? '') ?? 0;
  }

  Future<void> setEnabled(bool enabled) async {
    final db = LocalDatabaseService();
    await db.setUserValue(_enabledKey, enabled ? 'true' : 'false');
    if (enabled) {
      await db.setUserValue(
          _enabledAtKey, '${DateTime.now().millisecondsSinceEpoch}');
    }
  }

  // ────────────────────────────── KV ──

  Future<bool> _isEnabled() async {
    final v = await LocalDatabaseService().getUserValue(_enabledKey);
    return v != 'false'; // 默认开启
  }

  Future<int> _lastSuccessMs() async {
    final v = await LocalDatabaseService().getUserValue(_lastSuccessKey);
    return int.tryParse(v ?? '') ?? 0;
  }

  Future<int> _failures() async {
    final v = await LocalDatabaseService().getUserValue(_failuresKey);
    return int.tryParse(v ?? '') ?? 0;
  }

  /// 读取启用时间；缺省时为已开启实例回填「现在」（升级兼容，避免立刻误报）。
  Future<int> _ensureEnabledAt() async {
    final db = LocalDatabaseService();
    final raw = await db.getUserValue(_enabledAtKey);
    final existing = int.tryParse(raw ?? '') ?? 0;
    if (existing > 0) return existing;
    if (!await _isEnabled()) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.setUserValue(_enabledAtKey, '$now');
    return now;
  }

  Future<void> _recordSuccess() async {
    final db = LocalDatabaseService();
    await db.setUserValue(
        _lastSuccessKey, '${DateTime.now().millisecondsSinceEpoch}');
    await db.setUserValue(_failuresKey, '0');
  }

  Future<void> _recordFailure() async {
    final db = LocalDatabaseService();
    await db.setUserValue(_failuresKey, '${await _failures() + 1}');
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
