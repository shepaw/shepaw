// 储物袋各子页共享的小工具与总览数据加载（UI 重构 §shared）。

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/services/peer_storage_service.dart';
import '../she_network/exchange_settings.dart';
import '../storage/device_identity.dart';
import '../storage/scheduled_snapshot_service.dart';
import '../storage/snapshot_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';

String fmtStorageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 密码输入对话框；返回密码或 null（取消）。
Future<String?> askStoragePassword(BuildContext context, {String? title}) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title ?? l10n.storage_passwordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.storage_passwordHint,
              style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text(l10n.common_confirm),
        ),
      ],
    ),
  );
  return (result == null || result.isEmpty) ? null : result;
}

void storageToast(BuildContext context, String message, {Duration? duration}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    duration: duration ?? const Duration(seconds: 3),
  ));
}

/// 子页通用的忙碌遮罩：盖在 Stack 最上层阻断操作。
class StorageBusyOverlay extends StatelessWidget {
  const StorageBusyOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black26,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

/// 储物袋主页需要的轻量汇总（各子页仍各自加载完整数据）。
class StorageOverviewSummary {
  StorageOverviewSummary({
    required this.selfId,
    required this.masterId,
    required this.stats,
    required this.schedStatus,
    required this.snapshotCount,
    required this.pendingImportCount,
    required this.exchangeEnabled,
    required this.ownerPeerCount,
  });

  final String selfId;
  final String masterId;
  final Map<String, dynamic>? stats;
  final ScheduledSnapshotStatus? schedStatus;
  final int snapshotCount;
  final int pendingImportCount;
  final bool exchangeEnabled;
  final int ownerPeerCount;

  bool get isMaster => masterId == selfId && selfId.isNotEmpty;

  /// 本机四分区用量合计。
  int get myTotalBytes {
    final devices = (stats?['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    final mine = (devices[selfId] as Map?)?.cast<String, dynamic>() ?? {};
    var total = 0;
    for (final space in StoreSpace.all) {
      total += mine[space] as int? ?? 0;
    }
    return total;
  }

  int get recycleBytes => stats?['recycle_bytes'] as int? ?? 0;
  int get stagingBytes => stats?['staging_bytes'] as int? ?? 0;
  int? get volumeTotalBytes => stats?['volume_total_bytes'] as int?;
  int? get volumeFreeBytes => stats?['volume_free_bytes'] as int?;
  bool get volumeWarn => stats?['volume_warn'] == true;

  double? get volumeUsedRatio {
    final total = volumeTotalBytes;
    final free = volumeFreeBytes;
    if (total == null || free == null || total <= 0) return null;
    return ((total - free) / total).clamp(0.0, 1.0);
  }

  int get unsyncedCount => stats?['unsynced_count'] as int? ?? 0;
  int get unsyncedBytes => stats?['unsynced_bytes'] as int? ?? 0;

  /// 与空间管理页一致的未同步告警阈值（200MB）。
  static const int unsyncedWarnBytes = 200 * 1024 * 1024;
  bool get unsyncedWarn => unsyncedBytes > unsyncedWarnBytes;
}

Future<StorageOverviewSummary> loadStorageOverview() async {
  final selfId = await DeviceIdentity.deviceId();
  final masterId = await StoreService.instance.masterDeviceId();

  Map<String, dynamic>? stats;
  final statsRes = await StoreService.instance
      .call(StoreFrame(op: StoreOp.stats, payload: {}));
  if (statsRes != null && !statsRes.containsKey('_error')) {
    stats = statsRes;
  }

  final schedStatus = await ScheduledSnapshotService.instance.status();
  final snapshots = await SnapshotService.instance.listSnapshots();

  var pendingImportCount = 0;
  final pending = await StoreService.instance
      .call(StoreFrame(op: StoreOp.importPending, payload: {}));
  if (pending != null && pending['requests'] is List) {
    pendingImportCount = (pending['requests'] as List).length;
  }

  final exchange = await ExchangeSettings.load();
  final peers = await PeerStorageService().loadAllPeers();
  final ownerPeerCount =
      peers.where((p) => p.trustLevel == TrustLevel.owner).length;

  return StorageOverviewSummary(
    selfId: selfId,
    masterId: masterId,
    stats: stats,
    schedStatus: schedStatus,
    snapshotCount: snapshots.length,
    pendingImportCount: pendingImportCount,
    exchangeEnabled: exchange.enabled,
    ownerPeerCount: ownerPeerCount,
  );
}
