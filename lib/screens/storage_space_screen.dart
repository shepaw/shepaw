import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import '../storage/restore_service.dart';
import '../storage/snapshot_service.dart';

/// 存储空间页（docs/storage_space_plan.md §7，M1 范围：快照管理）。
///
/// M1 只含本机快照：生成（验密）、校验状态展示、恢复（全量替换）、
/// 本机导出。master/同步/回收站等区块随 M2~M6 扩展。
class StorageSpaceScreen extends StatefulWidget {
  const StorageSpaceScreen({super.key});

  @override
  State<StorageSpaceScreen> createState() => _StorageSpaceScreenState();
}

class _StorageSpaceScreenState extends State<StorageSpaceScreen> {
  late Future<List<SnapshotInfo>> _future;
  final Map<String, SnapshotVerifyStatus> _verifyCache = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<SnapshotInfo>> _load() async {
    final list = await SnapshotService.instance.listSnapshots();
    // 逐个校验（免密码哈希校验），结果进缓存
    for (final s in list) {
      if (!_verifyCache.containsKey(s.id)) {
        _verifyCache[s.id] = await SnapshotService.instance.verifySnapshot(s);
      }
    }
    return list;
  }

  Future<void> _refresh() async {
    _verifyCache.clear();
    setState(() => _future = _load());
  }

  // ------------------------------------------------------------ 操作

  /// 密码输入对话框；返回密码或 null（取消）。
  Future<String?> _askPassword({String? title}) async {
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

  Future<void> _snapshotNow() async {
    final l10n = AppLocalizations.of(context);
    final password = await _askPassword();
    if (password == null) return;
    if (!await PasswordService().verifyPassword(password)) {
      _toast(l10n.storage_passwordWrong);
      return;
    }
    setState(() => _busy = true);
    try {
      await SnapshotService.instance.createSnapshot(password: password);
      _toast(l10n.storage_snapshotDone);
      await _refresh();
    } catch (e) {
      _toast(l10n.storage_snapshotFailed('$e'));
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

    final password = await _askPassword();
    if (password == null) return;
    setState(() => _busy = true);
    try {
      final preview =
          await RestoreService.instance.prepareRestore(info, password);
      await RestoreService.instance.executeRestore(preview, password);
      _toast(l10n.storage_restoreDone, duration: const Duration(seconds: 6));
    } on StateError catch (e) {
      _toast(e.message.contains('wrong password')
          ? l10n.storage_passwordWrong
          : l10n.storage_restoreFailed('${e.message}'));
    } catch (e) {
      _toast(l10n.storage_restoreFailed('$e'));
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
      _toast(l10n.storage_exportDone(out.path),
          duration: const Duration(seconds: 5));
    } catch (e) {
      _toast(l10n.storage_snapshotFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(seconds: 3),
    ));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          FutureBuilder<List<SnapshotInfo>>(
            future: _future,
            builder: (context, snap) {
              final list = snap.data ?? const <SnapshotInfo>[];
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildHeader(l10n),
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
                ],
              );
            },
          ),
          if (_busy)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
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
      null => (l10n.storage_verifyUnknown, Theme.of(context).colorScheme.outline),
    };
    final t = info.createdAt;
    final timeLabel =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Card(
      child: ListTile(
        leading: const Icon(Icons.save_as_outlined),
        title: Text(timeLabel),
        subtitle: Text(
          '${_fmtBytes(info.totalBytes)} · schema v${info.manifest.schemaVersion} · $label',
          style: TextStyle(color: color),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _busy ? null : () => _export(info),
              child: Text(l10n.storage_export),
            ),
            TextButton(
              onPressed:
                  _busy || status != SnapshotVerifyStatus.ok
                      ? null
                      : () => _restore(info),
              child: Text(l10n.storage_restore),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
