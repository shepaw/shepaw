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
import '../storage/sync_engine.dart';
import '../storage/volume_usage.dart';

String fmtStorageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 储物袋分区显示名（工作/运行时/文件/公开/认知/产物）。
String storageSpaceLabel(AppLocalizations l10n, String space) {
  switch (space) {
    case StoreSpace.workspaces:
      return l10n.storage_spaceWorkspaces;
    case StoreSpace.runtime:
      return l10n.storage_spaceRuntime;
    case StoreSpace.files:
      return l10n.storage_spaceFiles;
    case StoreSpace.public_:
      return l10n.storage_spacePublic;
    case StoreSpace.cognition:
      return l10n.storage_spaceCognition;
    case StoreSpace.artifacts:
      return l10n.storage_spaceArtifacts;
    default:
      return space;
  }
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

int storageDeviceUsedBytes(Map<String, dynamic>? stats, String deviceId) {
  final devices = (stats?['devices'] as Map?)?.cast<String, dynamic>() ?? {};
  final mine = (devices[deviceId] as Map?)?.cast<String, dynamic>() ?? {};
  var total = 0;
  for (final space in StoreSpace.all) {
    total += (mine[space] as num?)?.toInt() ?? 0;
  }
  return total;
}

Map<String, int> storageDeviceSpaceBytes(
    Map<String, dynamic>? stats, String deviceId) {
  final devices = (stats?['devices'] as Map?)?.cast<String, dynamic>() ?? {};
  final mine = (devices[deviceId] as Map?)?.cast<String, dynamic>() ?? {};
  return {
    for (final space in StoreSpace.all)
      space: (mine[space] as num?)?.toInt() ?? 0,
  };
}

/// 储物袋主页需要的轻量汇总（仅本机 App 数据；不含多设备镜像管理）。
class StorageOverviewSummary {
  StorageOverviewSummary({
    required this.selfId,
    required this.stats,
    required this.schedStatus,
    required this.snapshotCount,
    required this.exchangeEnabled,
    required this.ownerPeerCount,
    required this.isMaster,
  });

  final String selfId;
  final Map<String, dynamic>? stats;
  final ScheduledSnapshotStatus? schedStatus;
  final int snapshotCount;
  final bool exchangeEnabled;
  final int ownerPeerCount;
  final bool isMaster;

  /// 本机四分区用量合计。
  int get myTotalBytes => storageDeviceUsedBytes(stats, selfId);

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

  int get mirroredDeviceCount {
    final devices = (stats?['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    return devices.keys.where((k) => k != selfId).length;
  }

  /// 与空间管理页一致的未同步告警阈值（200MB）。
  static const int unsyncedWarnBytes = 200 * 1024 * 1024;
  bool get unsyncedWarn => unsyncedBytes > unsyncedWarnBytes;
}

/// 加载本机 store 用量（不经远端 master，避免展示多设备镜像数据）。
Future<StorageOverviewSummary> loadStorageOverview() async {
  final selfId = await DeviceIdentity.deviceId();
  final store = await StoreService.instance.localStore();

  final stats = await store.stats(blocking: false);
  final journal = SyncEngine.instance.journal;
  if (journal != null) {
    stats['unsynced_count'] = await journal.pendingCount();
    stats['unsynced_bytes'] = await journal.pendingBytes();
  }
  final volume = await VolumeUsage.probe(store.root.path);
  if (volume != null) {
    stats['volume_total_bytes'] = volume.totalBytes;
    stats['volume_free_bytes'] = volume.freeBytes;
    stats['volume_used_ratio'] = volume.usedRatio;
    stats['volume_warn'] = volume.needsAttention;
  }

  final schedStatus = await ScheduledSnapshotService.instance.status();
  final snapshots = await SnapshotService.instance.listSnapshots();

  final exchange = await ExchangeSettings.load();
  final peers = await PeerStorageService().loadAllPeers();
  final ownerPeerCount =
      peers.where((p) => p.trustLevel == TrustLevel.owner).length;
  final masterId = await StoreService.instance.masterDeviceId();

  return StorageOverviewSummary(
    selfId: selfId,
    stats: stats,
    schedStatus: schedStatus,
    snapshotCount: snapshots.length,
    exchangeEnabled: exchange.enabled,
    ownerPeerCount: ownerPeerCount,
    isMaster: masterId == selfId,
  );
}
