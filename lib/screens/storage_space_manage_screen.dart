import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/folder_binding_service.dart';
import '../storage/local_store.dart';
import '../storage/store_service.dart';
import '../storage/sync_engine.dart';
import '../storage/volume_usage.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';

/// 本机存储空间子页：只管理当前 App 产生的数据占用。
///
/// 多设备镜像 / master 迁移 / 他端目录清理归独立同步节点（Nexuspouch）管理，
/// 不在此页暴露。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({super.key});

  @override
  State<StorageSpaceManageScreen> createState() =>
      _StorageSpaceManageScreenState();
}

class _StorageSpaceManageScreenState extends State<StorageSpaceManageScreen> {
  bool _busy = false;

  String _selfId = '';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _recycle = [];
  bool _recycleExpanded = false;
  List<FolderBinding> _bindings = [];
  final _bindPath = TextEditingController();
  final _bindFolder = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _selfId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final stats = await store.stats();

    // 本机未同步队列占用（磁盘压力，非多设备管理）
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

    _bindings = await FolderBindingService.instance.list();

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

  Future<void> _addBinding() async {
    final path = _bindPath.text.trim();
    final folder = _bindFolder.text.trim();
    if (path.isEmpty || folder.isEmpty) {
      storageToast(context, '请输入外部目录路径与映射文件夹名');
      return;
    }
    setState(() => _busy = true);
    try {
      await FolderBindingService.instance.add(
        label: folder,
        external: path,
        space: 'files',
        folder: folder,
      );
      _bindPath.clear();
      _bindFolder.clear();
      await _refresh();
      storageToast(context, '目录绑定已添加，正在首次同步…');
      await FolderBindingService.instance.syncAll();
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) storageToast(context, '绑定失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncBindings() async {
    setState(() => _busy = true);
    try {
      await FolderBindingService.instance.syncAll();
      await _refresh();
      storageToast(context, '目录绑定同步完成');
    } catch (e) {
      if (mounted) storageToast(context, '同步失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeBinding(String id) async {
    await FolderBindingService.instance.remove(id);
    await _refresh();
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
      if (mounted) storageToast(context, l10n.storage_recycleRestoreFailed('$e'));
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
      // 直接操作本机 LocalStore，不经远端 master。
      final purged = await store.recycleEmpty();
      if (!mounted) return;
      storageToast(context, l10n.storage_recyclePurged(fmtStorageBytes(purged)));
      await _refresh();
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_recyclePurgeFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
              _buildActionsCard(l10n),
              const SizedBox(height: 16),
              _buildBindingsCard(l10n),
              const SizedBox(height: 16),
              _buildRecycleCard(l10n),
            ],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  Widget _buildBindingsCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_copy_outlined,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('目录绑定（单向摄取）',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: '立即同步',
                  onPressed: _busy ? null : _syncBindings,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bindPath,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '外部目录路径，如 /Users/me/Downloads',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bindFolder,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '映射文件夹名（files/<name>）',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : _addBinding,
                  child: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final b in _bindings)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined, size: 18),
                title: Text(b.folder, style: Theme.of(context).textTheme.bodyMedium),
                subtitle: Text(b.external,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _removeBinding(b.id),
                ),
              ),
            if (_bindings.isEmpty)
              Text('未配置绑定目录',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              '单向：目录内容摄取进 files/<folder> 并镜像到 master；删除进回收站；'
              'App 内周期自动同步（事件驱动为后续增强）。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

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
              _buildPendingUploadStatus(l10n),
              _buildVolumeWarning(l10n),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_outlined,
                    color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(l10n.storage_thisDevice,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 8),
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

  /// 本机待上传占用（影响本机磁盘），不提供多设备同步管理入口。
  Widget _buildPendingUploadStatus(AppLocalizations l10n) {
    final unsyncedCount = _stats!['unsynced_count'] as int?;
    final unsyncedBytes = _stats!['unsynced_bytes'] as int?;
    if (unsyncedCount == null) return const SizedBox.shrink();

    final warn = (unsyncedBytes ?? 0) > StorageOverviewSummary.unsyncedWarnBytes;
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
    final parts = recyclePath.split('/');
    return parts.length > 1 ? parts[1] : '';
  }
}
