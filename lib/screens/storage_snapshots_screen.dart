import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/vault_service.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/restore_service.dart';
import '../storage/scheduled_snapshot_service.dart';
import '../storage/snapshot_crypto.dart';
import '../storage/snapshot_service.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import '../storage/sync_engine.dart';
import '../widgets/storage/storage_mirrored_devices_card.dart';
import '../widgets/storage/storage_pending_sync_card.dart';
import 'storage_pending_sync_screen.dart';
import 'storage_shared.dart';
import 'vault_restore_screen.dart';

/// 备份与恢复子页（储物袋重构 §子页）：自动快照设置 + 本机快照列表 +
/// 历史数据保险库入口（自设置页迁入，同属加密备份恢复）。
/// 业务逻辑与原 storage_space_screen.dart M1/M3 区块一致。
class StorageSnapshotsScreen extends StatefulWidget {
  const StorageSnapshotsScreen({super.key});

  @override
  State<StorageSnapshotsScreen> createState() => _StorageSnapshotsScreenState();
}

class _StorageSnapshotsScreenState extends State<StorageSnapshotsScreen> {
  late Future<List<SnapshotInfo>> _future;
  final Map<String, SnapshotVerifyStatus> _verifyCache = {};
  bool _busy = false;

  final VaultService _vaultService = VaultService();
  int _vaultCount = 0;

  ScheduledSnapshotStatus? _schedStatus;
  int _passwordChangedAtMs = 0;

  StreamSubscription<SyncStatus>? _syncSub;
  SyncStatus _syncStatus = SyncStatus.empty;
  bool _isMaster = false;
  List<MirroredDeviceRow> _mirrored = const [];

  @override
  void initState() {
    super.initState();
    _syncStatus = SyncEngine.instance.latestStatus;
    _syncSub = SyncEngine.instance.status.listen((s) {
      if (mounted) setState(() => _syncStatus = s);
    });
    unawaited(SyncEngine.instance.currentStatus());
    _future = _load();
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  Future<List<SnapshotInfo>> _load() async {
    final list = await SnapshotService.instance.listSnapshots();
    for (final s in list) {
      if (!_verifyCache.containsKey(s.id)) {
        _verifyCache[s.id] = await SnapshotService.instance.verifySnapshot(s);
      }
    }
    _schedStatus = await ScheduledSnapshotService.instance.status();
    _passwordChangedAtMs =
        await ScheduledSnapshotService.instance.passwordChangedAtMs();
    _vaultCount = (await _vaultService.listVaults()).length;

    _isMaster = await StoreService.instance.isMaster();
    if (_isMaster) {
      final self = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      final stats = await store.stats();
      final peers = await PeerStorageService().loadAllPeers();
      _mirrored = await loadMirroredDevices(
        selfId: self,
        peers: peers,
        stats: stats,
      );
    } else {
      _mirrored = const [];
    }
    return list;
  }

  Future<void> _refresh() async {
    _verifyCache.clear();
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  // ------------------------------------------------------------ 操作

  Future<void> _snapshotNow() async {
    final l10n = AppLocalizations.of(context);
    final password = await askStoragePassword(context);
    if (password == null) return;
    setState(() => _busy = true);
    try {
      await SnapshotService.instance.createSnapshot(password: password);
      await _refresh();
      if (mounted) storageToast(context, l10n.storage_snapshotDone);
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_snapshotFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 开启自动快照：强制验密（§10）；可选解密最新快照并缓存密钥。
  Future<void> _setAutoSnapshotEnabled(bool enabled) async {
    final l10n = AppLocalizations.of(context);
    if (enabled) {
      final password = await askStoragePassword(context,
          title: l10n.storage_enableSnapshotPasswordTitle);
      if (password == null) return;
      setState(() => _busy = true);
      try {
        final result =
            await SnapshotService.instance.checkDecryptAndCache(password);
        await ScheduledSnapshotService.instance.setEnabled(true);
        await _refresh();
        if (mounted) {
          storageToast(
              context,
              result.decryptedSnapshot
                  ? l10n.storage_decryptCheckOk
                  : l10n.storage_decryptCheckOkNoSnapshot);
        }
      } on SnapshotDecryptException {
        if (mounted) storageToast(context, l10n.storage_passwordWrong);
      } catch (e) {
        if (mounted) storageToast(context, l10n.storage_decryptCheckFailed('$e'));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    await ScheduledSnapshotService.instance.setEnabled(false);
    await _refresh();
  }

  /// 解密自检（§10）。
  Future<void> _decryptSelfCheck() async {
    final l10n = AppLocalizations.of(context);
    final password =
        await askStoragePassword(context, title: l10n.storage_decryptCheckTitle);
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final result =
          await SnapshotService.instance.checkDecryptAndCache(password);
      await _refresh();
      if (mounted) {
        storageToast(
            context,
            result.decryptedSnapshot
                ? l10n.storage_decryptCheckOk
                : l10n.storage_decryptCheckOkNoSnapshot);
      }
    } on SnapshotDecryptException {
      if (mounted) storageToast(context, l10n.storage_passwordWrong);
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_decryptCheckFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(SnapshotInfo info) async {
    final l10n = AppLocalizations.of(context);
    // 全量替换语义强提示（§5.3）
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Theme.of(ctx).colorScheme.error, size: 36),
        title: Text(l10n.storage_restoreTitle),
        content: Text(l10n.storage_restoreWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.storage_restoreConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final password = await askStoragePassword(context);
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final preview =
          await RestoreService.instance.prepareRestore(info, password);
      final safetyHash = await SnapshotCrypto.cachedPasswordHash();
      await RestoreService.instance.executeRestore(preview, password,
          safetyPasswordHash: safetyHash);
      if (mounted) {
        storageToast(context, l10n.storage_restoreDone,
            duration: const Duration(seconds: 6));
      }
    } on StateError catch (e) {
      if (mounted) {
        storageToast(
            context,
            e.message.contains('wrong password')
                ? l10n.storage_passwordWrong
                : l10n.storage_restoreFailed(e.message));
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_restoreFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(SnapshotInfo info) async {
    final l10n = AppLocalizations.of(context);
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    setState(() => _busy = true);
    try {
      final out = await SnapshotService.instance.exportToDirectory(info, dir);
      if (!mounted) return;
      if (out.missingAttachments.isEmpty) {
        storageToast(
          context,
          out.packedAttachments > 0
              ? l10n.storage_exportDoneWithAttachments(
                  out.directory.path, out.packedAttachments)
              : l10n.storage_exportDone(out.directory.path),
          duration: const Duration(seconds: 5),
        );
      } else {
        storageToast(
          context,
          l10n.storage_exportDonePartial(out.directory.path,
              out.packedAttachments, out.missingAttachments.length),
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_snapshotFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 进入历史数据保险库；返回后刷新数量（可能恢复/删除了 vault）。
  Future<void> _openVault() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const VaultRestoreScreen()),
    );
    if (mounted) unawaited(_refresh());
  }

  Future<void> _purgeMirror(MirroredDeviceRow device) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.storage_purgeDeviceTitle),
        content: Text(
          l10n.storage_purgeDeviceConfirm(
            device.name,
            fmtStorageBytes(device.bytes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.storage_purgeDevice),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final freed =
          await StoreService.instance.purgeMirroredDevice(device.deviceId);
      await _refresh();
      if (mounted) {
        storageToast(
          context,
          l10n.storage_purgeDeviceDone(
            device.name,
            fmtStorageBytes(freed),
          ),
        );
      }
    } on StoreException catch (e) {
      if (!mounted) return;
      storageToast(
        context,
        e.code == StoreError.notMaster
            ? l10n.storage_purgeDeviceMasterOnly
            : l10n.storage_purgeDeviceFailed(
                e.message.isEmpty ? e.code : e.message),
      );
    } catch (e) {
      if (mounted) {
        storageToast(context, l10n.storage_purgeDeviceFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  Widget _iconBox(IconData icon, {Color? color}) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 20, color: c),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.storage_entrySnapshots)),
      body: Stack(
        children: [
          FutureBuilder<List<SnapshotInfo>>(
            future: _future,
            builder: (context, snap) {
              final list = snap.data ?? const <SnapshotInfo>[];
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _buildCreateCard(l10n),
                    const SizedBox(height: 12),
                    _buildAutoCard(l10n),
                    if (_syncStatus.showPendingCard) ...[
                      const SizedBox(height: 12),
                      StoragePendingSyncCard(
                        status: _syncStatus,
                        onSeeAll: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const StoragePendingSyncScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                    if (_isMaster) ...[
                      const SizedBox(height: 12),
                      StorageMirroredDevicesCard(
                        devices: _mirrored,
                        busy: _busy,
                        onPurge: _purgeMirror,
                      ),
                    ],
                    const SizedBox(height: 20),
                    _sectionLabel(l10n.storage_snapshotSection),
                    if (snap.connectionState != ConnectionState.done)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (list.isEmpty)
                      _buildEmptySnapshots(l10n)
                    else
                      for (var i = 0; i < list.length; i++) ...[
                        _buildSnapshotTile(l10n, list[i]),
                        if (i < list.length - 1) const SizedBox(height: 8),
                      ],
                    const SizedBox(height: 20),
                    _buildVaultTile(l10n),
                  ],
                ),
              );
            },
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  Widget _buildCreateCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _iconBox(Icons.backup_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.storage_createBackup,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.storage_snapshotDesc,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _snapshotNow,
                icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: Text(l10n.storage_snapshotNow),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 历史数据保险库入口卡（重置密码前的加密备份，用旧密码恢复）。
  Widget _buildVaultTile(AppLocalizations l10n) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minLeadingWidth: 36,
        horizontalTitleGap: 12,
        leading: _iconBox(Icons.archive_outlined),
        title: Text(l10n.settings_dataVault),
        subtitle: Text(
          '${l10n.settings_dataVaultSub} · ${l10n.vault_count(_vaultCount)}',
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: _busy ? null : () => unawaited(_openVault()),
      ),
    );
  }

  Widget _buildAutoCard(AppLocalizations l10n) {
    final status = _schedStatus;
    final scheme = Theme.of(context).colorScheme;
    final subtitle = status == null
        ? null
        : !status.enabled
            ? l10n.storage_autoSnapshotOff
            : !status.keyCached
                ? l10n.storage_noKeyHint
                : status.lastSuccessMs > 0
                    ? l10n.storage_lastSuccess(_fmtTime(status.lastSuccessMs))
                    : l10n.storage_noSnapshots;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(
              children: [
                _iconBox(Icons.schedule_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.storage_autoSnapshot,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                    ],
                  ),
                ),
                Switch(
                  value: status?.enabled ?? false,
                  onChanged: _busy || status == null
                      ? null
                      : (v) => unawaited(_setAutoSnapshotEnabled(v)),
                ),
              ],
            ),
          ),
          if (status != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(64, 0, 16, 8),
              child: Text(
                l10n.storage_autoSnapshotRetention,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            const Divider(height: 1, indent: 64),
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              minLeadingWidth: 36,
              horizontalTitleGap: 12,
              leading: _iconBox(Icons.verified_user_outlined),
              title: Text(l10n.storage_decryptCheck),
              subtitle: Text(l10n.storage_decryptCheckTitle),
              onTap: _busy ? null : () => unawaited(_decryptSelfCheck()),
            ),
            if (status.needsAttention)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 18, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.storage_snapshotWarning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptySnapshots(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            Icon(Icons.save_alt_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              l10n.storage_noSnapshots,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.storage_noSnapshotsHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotTile(AppLocalizations l10n, SnapshotInfo info) {
    final status = _verifyCache[info.id];
    final (label, color) = switch (status) {
      SnapshotVerifyStatus.ok => (l10n.storage_verifyOk, Colors.green),
      SnapshotVerifyStatus.fileTampered => (
          l10n.storage_verifyFileTampered,
          Theme.of(context).colorScheme.error
        ),
      SnapshotVerifyStatus.manifestTampered => (
          l10n.storage_verifyManifestTampered,
          Theme.of(context).colorScheme.error
        ),
      SnapshotVerifyStatus.unreadable => (
          l10n.storage_verifyUnreadable,
          Theme.of(context).colorScheme.error
        ),
      null => (
          l10n.storage_verifyUnknown,
          Theme.of(context).colorScheme.outline
        ),
    };
    final t = info.createdAt;
    final timeLabel =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    // 改密前的快照：需旧密码恢复（§5.2 密码变更策略）
    final needsOldPassword = _passwordChangedAtMs > 0 &&
        info.manifest.createdAtMs < _passwordChangedAtMs;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _iconBox(Icons.save_as_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timeLabel,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${fmtStorageBytes(info.totalBytes)} · '
                        'schema v${info.manifest.schemaVersion}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                _StatusChip(label: label, color: color),
                const SizedBox(width: 8),
              ],
            ),
            if (needsOldPassword)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    l10n.storage_needsOldPassword,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _export(info),
                  child: Text(l10n.storage_export),
                ),
                TextButton(
                  onPressed: _busy || status != SnapshotVerifyStatus.ok
                      ? null
                      : () => _restore(info),
                  child: Text(l10n.storage_restore),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// 校验状态小徽标（✓已校验 / 篡改 / 未校验）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color),
      ),
    );
  }
}
