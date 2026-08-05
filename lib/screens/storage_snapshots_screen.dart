import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/vault_service.dart';
import '../storage/restore_service.dart';
import '../storage/scheduled_snapshot_service.dart';
import '../storage/snapshot_crypto.dart';
import '../storage/snapshot_service.dart';
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

  @override
  void initState() {
    super.initState();
    _future = _load();
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
    return list;
  }

  Future<void> _refresh() async {
    _verifyCache.clear();
    setState(() => _future = _load());
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

  // ------------------------------------------------------------ UI

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
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildAutoCard(l10n),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text(l10n.storage_snapshotSection,
                          style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _busy ? null : _snapshotNow,
                        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                        label: Text(l10n.storage_snapshotNow),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (snap.connectionState != ConnectionState.done)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(l10n.storage_noSnapshots,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                      ),
                    )
                  else
                    ...list.map((s) => _buildSnapshotTile(l10n, s)),
                  const SizedBox(height: 20),
                  _buildVaultTile(l10n),
                ],
              );
            },
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }

  /// 历史数据保险库入口卡（重置密码前的加密备份，用旧密码恢复）。
  Widget _buildVaultTile(AppLocalizations l10n) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.archive_outlined),
        title: Text(l10n.settings_dataVault),
        subtitle: Text(
          '${l10n.settings_dataVaultSub} · ${l10n.vault_count(_vaultCount)}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _busy ? null : () => unawaited(_openVault()),
      ),
    );
  }

  Widget _buildAutoCard(AppLocalizations l10n) {
    final status = _schedStatus;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.backup_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.storage_snapshotDesc,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (status != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.storage_autoSnapshot,
                            style: Theme.of(context).textTheme.bodyMedium),
                        Text(
                          !status.enabled
                              ? l10n.storage_autoSnapshotOff
                              : !status.keyCached
                                  ? l10n.storage_noKeyHint
                                  : status.lastSuccessMs > 0
                                      ? l10n.storage_lastSuccess(
                                          _fmtTime(status.lastSuccessMs))
                                      : l10n.storage_noSnapshots,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: status.enabled,
                    onChanged: _busy
                        ? null
                        : (v) => unawaited(_setAutoSnapshotEnabled(v)),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _decryptSelfCheck,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(l10n.storage_decryptCheck),
                ),
              ),
              if (status.needsAttention)
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
                          size: 18,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l10n.storage_snapshotWarning,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
            ],
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.save_as_outlined, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(timeLabel,
                          style: Theme.of(context).textTheme.bodyMedium),
                      Text(
                        '${fmtStorageBytes(info.totalBytes)} · '
                        'schema v${info.manifest.schemaVersion}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                _StatusChip(label: label, color: color),
              ],
            ),
            if (needsOldPassword)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(l10n.storage_needsOldPassword,
                      style: Theme.of(context).textTheme.labelSmall),
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
