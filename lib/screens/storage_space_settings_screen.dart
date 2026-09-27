import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_service.dart';
import '../storage/sync_engine.dart';
import '../storage/volume_usage.dart';
import 'storage_shared.dart';

/// 用量与回收站各自独立成页。
enum StorageSpaceSettingsSection {
  usage,
  recycle,
}

/// 用量或回收站。一次只展示 [section] 对应的一页。
class StorageSpaceSettingsScreen extends StatefulWidget {
  const StorageSpaceSettingsScreen({
    super.key,
    required this.section,
  });

  final StorageSpaceSettingsSection section;

  @override
  State<StorageSpaceSettingsScreen> createState() =>
      _StorageSpaceSettingsScreenState();
}

class _StorageSpaceSettingsScreenState
    extends State<StorageSpaceSettingsScreen> {
  bool _busy = false;

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
    final store = await StoreService.instance.localStore();
    final stats = await store.stats();

    final journal = SyncEngine.instance.journal;
    if (journal != null) {
      stats['unsynced_count'] = await journal.pendingCount();
      stats['unsynced_bytes'] = await journal.pendingBytes();
      final cursors = await journal.cursors();
      stats['change_seq'] = cursors.changeSeq;
      stats['ack_seq'] = cursors.ackSeq;
    }

    final volume = await VolumeUsage.probe(store.root.path);
    if (volume != null) {
      stats['volume_total_bytes'] = volume.totalBytes;
      stats['volume_free_bytes'] = volume.freeBytes;
      stats['volume_used_ratio'] = volume.usedRatio;
      stats['volume_warn'] = volume.needsAttention;
    }

    final recycle = await store.recycleList();
    final selfRecycle = recycle
        .where((e) => e.originDevice == _selfId)
        .map((e) => e.toJson())
        .toList();

    if (mounted) {
      setState(() {
        _stats = stats;
        _recycle = selfRecycle;
      });
    }
  }

  Future<void> _refresh() => _load();

  Future<void> _recycleRestore(Map<String, dynamic> entry) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final store = await StoreService.instance.localStore();
      await store.recycleRestore(entry['recycle_path'] as String);
      await _refresh();
      if (mounted) storageToast(context, l10n.storage_recycleRestored);
    } on StoreException catch (e) {
      if (mounted) {
        storageToast(
            context,
            l10n.storage_recycleRestoreFailed(
                e.message.isEmpty ? e.code : e.message));
      }
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_recycleRestoreFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recyclePurgeAll() async {
    final l10n = AppLocalizations.of(context);
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
      final store = await StoreService.instance.localStore();
      final purged = await store.recycleEmpty();
      if (!mounted) return;
      storageToast(
          context, l10n.storage_recyclePurged(fmtStorageBytes(purged)));
      await _refresh();
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_recyclePurgeFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _title(AppLocalizations l10n) {
    switch (widget.section) {
      case StorageSpaceSettingsSection.usage:
        return l10n.storage_usageTitle;
      case StorageSpaceSettingsSection.recycle:
        return l10n.storage_recycleSection;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = switch (widget.section) {
      StorageSpaceSettingsSection.usage => _buildUsageCard(l10n),
      StorageSpaceSettingsSection.recycle => _buildRecycleCard(l10n),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(l10n)),
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
            children: [body],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  Widget _buildUsageCard(AppLocalizations l10n) {
    final volumeTotal = _stats?['volume_total_bytes'] as int?;
    final volumeFree = _stats?['volume_free_bytes'] as int?;
    final int? volumeUsed = (volumeTotal != null && volumeFree != null)
        ? (volumeTotal - volumeFree).clamp(0, volumeTotal).toInt()
        : null;
    final volumeWarn = _stats?['volume_warn'] == true;
    final double? ratio =
        (volumeTotal != null && volumeUsed != null && volumeTotal > 0)
            ? (volumeUsed / volumeTotal).clamp(0.0, 1.0)
            : null;
    final bagUsed = _stats == null ? null : storageBagUsedBytes(_stats);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _usageMetric(l10n.storage_usageSystemTotal, volumeTotal),
            _usageMetric(
              l10n.storage_usageSystemUsed,
              volumeUsed,
              alert: volumeWarn,
            ),
            if (ratio != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 8,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      volumeWarn
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            _usageMetric(l10n.storage_usageBagUsed, bagUsed),
            if (_stats != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildPendingUploadStatus(l10n),
                    _buildVolumeWarning(l10n),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _usageMetric(String label, int? bytes, {bool alert = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          ),
          Text(
            bytes == null ? '—' : fmtStorageBytes(bytes),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: alert ? scheme.error : null,
                ),
          ),
        ],
      ),
    );
  }

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

  Widget _buildPendingUploadStatus(AppLocalizations l10n) {
    final unsyncedCount = _stats!['unsynced_count'] as int?;
    final unsyncedBytes = _stats!['unsynced_bytes'] as int?;
    if (unsyncedCount == null) return const SizedBox.shrink();

    final warn =
        (unsyncedBytes ?? 0) > StorageOverviewSummary.unsyncedWarnBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          l10n.storage_unsynced(
              unsyncedCount, fmtStorageBytes(unsyncedBytes ?? 0)),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: unsyncedCount > 0
                    ? Theme.of(context).colorScheme.tertiary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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

  Widget _buildRecycleCard(AppLocalizations l10n) {
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
                if (_recycle.isNotEmpty)
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
                    leading:
                        const Icon(Icons.insert_drive_file_outlined, size: 18),
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
    final parts = recyclePath.split('/');
    return parts.length > 1 ? parts[1] : '';
  }
}
