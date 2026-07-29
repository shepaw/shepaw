import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/services/peer_storage_service.dart';
import '../storage/device_cursor_store.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/master_migration_service.dart';
import '../storage/mirror_reprotect_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';

/// 空间与同步子页（储物袋重构 §子页）：用量可视化 + master 节点 +
/// 同步状态 + 他端镜像 + 回收站。业务逻辑与原 M2/M4/M6 区块一致。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({super.key});

  @override
  State<StorageSpaceManageScreen> createState() =>
      _StorageSpaceManageScreenState();
}

class _StorageSpaceManageScreenState extends State<StorageSpaceManageScreen> {
  bool _busy = false;

  String _masterId = '';
  String _selfId = '';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _recycle = [];
  bool _recycleExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _selfId = await DeviceIdentity.deviceId();
    _masterId = await StoreService.instance.masterDeviceId();
    final stats = await StoreService.instance
        .call(StoreFrame(op: StoreOp.stats, payload: {}));
    if (stats != null && !stats.containsKey('_error')) {
      _stats = stats;
    }
    final recycle = await StoreService.instance
        .call(StoreFrame(op: StoreOp.recycleList, payload: {}));
    if (recycle != null && recycle['entries'] is List) {
      _recycle = (recycle['entries'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh() => _load();

  // ------------------------------------------------------------ M6 master 迁移

  /// 旧 master ≠ 本机且当前不可达时，升主存在历史 blob 缺口风险（方案 §6.5）。
  Future<bool> _oldMasterGapRisk() async {
    final masterId = await StoreService.instance.masterDeviceId();
    if (masterId == _selfId) return false;
    return !await StoreService.instance.masterOnline();
  }

  Future<bool> _confirmMigrate(String deviceLabel) async {
    final l10n = AppLocalizations.of(context);
    final gapRisk = await _oldMasterGapRisk();
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.storage_migrateConfirm(deviceLabel)),
                if (gapRisk) ...[
                  const SizedBox(height: 12),
                  Text(l10n.storage_migrateGapWarning),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(l10n.common_confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _toastMigrateDone(AppLocalizations l10n, MigrationResult result) {
    if (!result.oldMasterReachable) {
      storageToast(context, l10n.storage_migrateDoneGap(result.epoch));
      return;
    }
    if (result.hashGate.ran && !result.hashGate.ok) {
      storageToast(
          context,
          l10n.storage_migrateDoneHashMismatch(
              result.epoch, result.hashGate.mismatches.length));
      return;
    }
    storageToast(context, l10n.storage_migrateDone(result.epoch));
  }

  Future<void> _becomeMaster() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _confirmMigrate(l10n.storage_thisDevice);
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final result = await MasterMigrationService.instance.promoteSelf();
      await _refresh();
      if (mounted) _toastMigrateDone(l10n, result);
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickMigrateTarget() async {
    final l10n = AppLocalizations.of(context);
    final peers = await PeerStorageService().loadAllPeers();
    final owners = peers
        .where((p) => p.trustLevel == 'owner' && p.fingerprint != _selfId)
        .toList();
    if (!mounted) return;
    final choices = <(String, String)>[
      (_selfId, l10n.storage_thisDevice),
      for (final p in owners)
        (p.fingerprint, '${p.deviceName} (${p.fingerprint.substring(0, 8)}…)'),
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.storage_migratePick),
        children: [
          for (final (id, label) in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(id),
              child: Text(label),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final label = choices.firstWhere((c) => c.$1 == picked).$2;
    final confirmed = await _confirmMigrate(label);
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      final result =
          await MasterMigrationService.instance.requestPromote(picked);
      await _refresh();
      if (result != null && mounted) {
        _toastMigrateDone(l10n, result);
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprotectNow() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final id = await MirrorReprotectService.instance.runIfMaster();
      if (!mounted) return;
      if (id == null) {
        storageToast(context, l10n.storage_reprotectSkipped);
      } else {
        storageToast(context, l10n.storage_reprotectDone(id));
        await _refresh();
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_migrateFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 回收站操作

  Future<void> _recycleRestore(Map<String, dynamic> entry) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final res = await StoreService.instance.call(StoreFrame(
          op: StoreOp.recycleRestore,
          payload: {'recycle_path': entry['recycle_path']}));
      if (!mounted) return;
      if (res != null && res.containsKey('_error')) {
        storageToast(context, l10n.storage_recycleRestoreFailed('${res['_error']}'));
        return;
      }
      await _refresh();
      if (mounted) storageToast(context, l10n.storage_recycleRestored);
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_recycleRestoreFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recyclePurgeAll() async {
    final l10n = AppLocalizations.of(context);
    if (_masterId != _selfId || _selfId.isEmpty) {
      storageToast(context, l10n.storage_recyclePurgeMasterOnly);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_forever,
            color: Theme.of(ctx).colorScheme.error, size: 36),
        content: Text(l10n.storage_recyclePurgeConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final res = await StoreService.instance
          .call(StoreFrame(op: StoreOp.recycleEmpty, payload: {}));
      if (!mounted) return;
      if (res != null && res.containsKey('_error')) {
        storageToast(context, l10n.storage_recyclePurgeFailed('${res['_error']}'));
        return;
      }
      final purged = res?['purged_bytes'] as int? ?? 0;
      storageToast(context, l10n.storage_recyclePurged(fmtStorageBytes(purged)));
      await _refresh();
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_recyclePurgeFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeMirroredDevice(String deviceId, int bytesHint) async {
    final l10n = AppLocalizations.of(context);
    if (_masterId != _selfId || _selfId.isEmpty) {
      storageToast(context, l10n.storage_purgeDeviceMasterOnly);
      return;
    }
    final short =
        deviceId.length >= 8 ? '${deviceId.substring(0, 8)}…' : deviceId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_forever,
            color: Theme.of(ctx).colorScheme.error, size: 36),
        title: Text(l10n.storage_purgeDeviceTitle),
        content: Text(l10n.storage_purgeDeviceConfirm(
            short, fmtStorageBytes(bytesHint))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final store = await StoreService.instance.localStore();
      final purged = await store.purgeDevice(deviceId, selfDeviceId: _selfId);
      final cursors = DeviceCursorStore(storeRoot: store.root);
      await cursors.remove(deviceId);
      await _refresh();
      if (mounted) {
        storageToast(context, l10n.storage_purgeDeviceDone(short, fmtStorageBytes(purged)));
      }
    } on StoreException catch (e) {
      if (mounted) {
        storageToast(context,
            l10n.storage_purgeDeviceFailed(e.message.isEmpty ? e.code : e.message));
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_purgeDeviceFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_entrySpace),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.common_refresh,
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildUsageCard(l10n),
              const SizedBox(height: 16),
              _buildMasterCard(l10n),
              const SizedBox(height: 16),
              _buildRecycleCard(l10n),
            ],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  /// 用量卡：卷进度条（有卷数据时）+ 各分区 chips + 同步状态 + 告警。
  Widget _buildUsageCard(AppLocalizations l10n) {
    final volumeTotal = _stats?['volume_total_bytes'] as int?;
    final volumeFree = _stats?['volume_free_bytes'] as int?;
    final volumeWarn = _stats?['volume_warn'] == true;
    final double? ratio =
        (volumeTotal != null && volumeFree != null && volumeTotal > 0)
            ? ((volumeTotal - volumeFree) / volumeTotal).clamp(0.0, 1.0)
            : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(l10n.storage_usageTitle,
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (volumeTotal != null && volumeFree != null)
                  Text(
                    l10n.storage_volumeFree(fmtStorageBytes(volumeFree),
                        fmtStorageBytes(volumeTotal)),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: volumeWarn
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
            if (ratio != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    volumeWarn
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
            if (_stats != null) ...[
              const SizedBox(height: 12),
              _buildUsageChips(l10n),
              _buildSyncStatus(l10n),
              _buildVolumeWarning(l10n),
              if (_masterId == _selfId && _selfId.isNotEmpty)
                _buildMirroredDevices(l10n),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMasterCard(AppLocalizations l10n) {
    final isMaster = _masterId == _selfId && _selfId.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dns_outlined,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(l10n.storage_masterNode,
                    style: Theme.of(context).textTheme.bodyMedium),
                const Spacer(),
                Flexible(
                  child: Text(
                    isMaster
                        ? '${_masterId.substring(0, 8)}…（${l10n.storage_thisDevice}）'
                        : _masterId,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!isMaster)
                  FilledButton.tonal(
                    onPressed: _busy ? null : _becomeMaster,
                    child: Text(l10n.storage_becomeMaster),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : _pickMigrateTarget,
                  child: Text(l10n.storage_migrateMaster),
                ),
                if (isMaster)
                  OutlinedButton(
                    onPressed: _busy ? null : _reprotectNow,
                    child: Text(l10n.storage_reprotectNow),
                  ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const StorageBrowserScreen(),
                            ),
                          );
                        },
                  child: Text(l10n.storage_browseFiles),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsageChips(AppLocalizations l10n) {
    final devices = (_stats!['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    final mine = (devices[_selfId] as Map?)?.cast<String, dynamic>() ?? {};
    final staging = _stats!['staging_bytes'] as int? ?? 0;
    final recycle = _stats!['recycle_bytes'] as int? ?? 0;
    final chips = <Widget>[
      for (final space in ['artifacts', 'files', 'attachments', 'backups'])
        Chip(
          label: Text('$space ${fmtStorageBytes(mine[space] as int? ?? 0)}'),
          visualDensity: VisualDensity.compact,
        ),
      if (staging > 0)
        Chip(
          label: Text('staging ${fmtStorageBytes(staging)}'),
          visualDensity: VisualDensity.compact,
        ),
      if (recycle > 0)
        Chip(
          label: Text('.recycle ${fmtStorageBytes(recycle)}'),
          visualDensity: VisualDensity.compact,
        ),
    ];
    return Wrap(spacing: 8, runSpacing: 4, children: chips);
  }

  /// 方案 §7：卷用量 ≥80% 告警。
  Widget _buildVolumeWarning(AppLocalizations l10n) {
    if (_stats!['volume_warn'] != true) return const SizedBox.shrink();
    final ratio = (_stats!['volume_used_ratio'] as num?)?.toDouble() ?? 0;
    final pct = (ratio * 100).round();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.storage_rounded,
              size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l10n.storage_volumeWarning(pct),
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  /// M4：未同步占用与游标水位（§6.4 磁盘压力展示 + 超阈值告警）。
  Widget _buildSyncStatus(AppLocalizations l10n) {
    final unsyncedCount = _stats!['unsynced_count'] as int?;
    final unsyncedBytes = _stats!['unsynced_bytes'] as int?;
    final changeSeq = _stats!['change_seq'] as int?;
    final ackSeq = _stats!['ack_seq'] as int?;
    if (unsyncedCount == null) return const SizedBox.shrink();

    final warn = (unsyncedBytes ?? 0) > StorageOverviewSummary.unsyncedWarnBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(
              l10n.storage_unsynced(
                  unsyncedCount, fmtStorageBytes(unsyncedBytes ?? 0)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unsyncedCount > 0
                        ? Theme.of(context).colorScheme.tertiary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (changeSeq != null && ackSeq != null)
              Text(
                l10n.storage_syncCursor(ackSeq, changeSeq),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        if (warn)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.storage_unsyncedWarning,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// master 上他端镜像目录：展示用量并允许手动删除（§5.4 / §7.2）。
  Widget _buildMirroredDevices(AppLocalizations l10n) {
    final devices = (_stats!['devices'] as Map?)?.cast<String, dynamic>() ?? {};
    final others = devices.keys.where((id) => id != _selfId).toList()..sort();
    if (others.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 20),
        Text(l10n.storage_mirroredDevices,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ...others.map((id) {
          final spaces = (devices[id] as Map?)?.cast<String, dynamic>() ?? {};
          var total = 0;
          for (final space in StoreSpace.all) {
            total += spaces[space] as int? ?? 0;
          }
          final short = id.length >= 8 ? '${id.substring(0, 8)}…' : id;
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_other, size: 18),
            title: Text(short, style: Theme.of(context).textTheme.bodySmall),
            subtitle: Text(fmtStorageBytes(total),
                style: Theme.of(context).textTheme.labelSmall),
            trailing: TextButton(
              onPressed: _busy ? null : () => _purgeMirroredDevice(id, total),
              child: Text(l10n.storage_purgeDevice),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildRecycleCard(AppLocalizations l10n) {
    final isMaster = _masterId == _selfId && _selfId.isNotEmpty;
    const pageSize = 20;
    final visible = _recycleExpanded || _recycle.length <= pageSize
        ? _recycle
        : _recycle.take(pageSize).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(l10n.storage_recycleSection,
                    style: Theme.of(context).textTheme.bodyMedium),
                const Spacer(),
                if (isMaster && _recycle.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _recyclePurgeAll,
                    child: Text(l10n.storage_recyclePurgeAll),
                  ),
              ],
            ),
            if (_recycle.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.storage_recycleEmptyHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            else ...[
              ...visible.map((e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined,
                        size: 18),
                    title: Text('${e['space']}/${e['origin_path']}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${fmtStorageBytes(e['size'] as int? ?? 0)} · ${l10n.storage_deletedAt(_fmtRecycleDate(e['recycle_path'] as String))}'),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _recycleRestore(e),
                      child: Text(l10n.storage_recycleRestore),
                    ),
                  )),
              if (_recycle.length > pageSize)
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _recycleExpanded = !_recycleExpanded),
                    child: Text(_recycleExpanded
                        ? l10n.storage_recycleShowLess
                        : l10n.storage_recycleShowMore(_recycle.length)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtRecycleDate(String recyclePath) {
    // .recycle/<yyyy-MM-dd>/...
    final parts = recyclePath.split('/');
    return parts.length > 1 ? parts[1] : '';
  }
}
