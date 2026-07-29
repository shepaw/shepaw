import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/store_export_service.dart';
import '../storage/store_webdav_export_service.dart';
import '../storage/store_wipe_service.dart';
import '../storage/webdav_uploader.dart';
import 'storage_shared.dart';

/// 高级与危险区子页（储物袋重构 §子页）：目录导出 / WebDAV 导出 /
/// 抹除本机存储。业务逻辑与原危险区卡片一致。
class StorageAdvancedScreen extends StatefulWidget {
  const StorageAdvancedScreen({super.key});

  @override
  State<StorageAdvancedScreen> createState() => _StorageAdvancedScreenState();
}

class _StorageAdvancedScreenState extends State<StorageAdvancedScreen> {
  bool _busy = false;

  Future<void> _exportStoreTree() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.folder_zip_outlined,
            color: Theme.of(ctx).colorScheme.primary, size: 36),
        title: Text(l10n.storage_exportTreeTitle),
        content: Text(l10n.storage_exportTreeHint),
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
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    setState(() => _busy = true);
    try {
      final out = await StoreExportService.instance.exportSelfTree(dir);
      if (mounted) {
        storageToast(
          context,
          l10n.storage_exportTreeDone(
              out.directory.path, out.fileCount, fmtStorageBytes(out.totalBytes)),
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_exportTreeFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportStoreWebdav() async {
    final l10n = AppLocalizations.of(context);
    final urlCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final prefixCtrl = TextEditingController(text: 'shepaw-export');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.cloud_upload_outlined,
            color: Theme.of(ctx).colorScheme.primary, size: 36),
        title: Text(l10n.storage_exportWebdavTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.storage_exportWebdavHint,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: l10n.storage_exportWebdavUrl,
                  hintText: 'https://dav.example.com/remote.php/dav/files/u',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: userCtrl,
                decoration:
                    InputDecoration(labelText: l10n.storage_exportWebdavUser),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: InputDecoration(
                    labelText: l10n.storage_exportWebdavPassword),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: prefixCtrl,
                decoration: InputDecoration(
                  labelText: l10n.storage_exportWebdavPrefix,
                  hintText: 'shepaw-export',
                ),
              ),
            ],
          ),
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
    );
    if (confirmed != true) return;
    final url = urlCtrl.text.trim();
    if (url.isEmpty) {
      storageToast(context, l10n.storage_exportWebdavFailed('URL'));
      return;
    }
    setState(() => _busy = true);
    final uploader = DioWebdavUploader(
      baseUrl: url,
      username: userCtrl.text.trim(),
      password: passCtrl.text,
    );
    try {
      final out = await StoreWebdavExportService.instance.exportSelfTree(
        uploader: uploader,
        remotePrefix: prefixCtrl.text.trim(),
      );
      if (mounted) {
        storageToast(
          context,
          l10n.storage_exportWebdavDone(
              out.remoteRoot, out.fileCount, fmtStorageBytes(out.totalBytes)),
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_exportWebdavFailed('$e'));
    } finally {
      await uploader.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wipeSelfStore() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final ok = controller.text.trim() == 'DELETE';
            return AlertDialog(
              icon: Icon(Icons.delete_forever,
                  color: Theme.of(ctx).colorScheme.error, size: 36),
              title: Text(l10n.storage_wipeSelfTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.storage_wipeSelfConfirm),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: l10n.storage_wipeSelfTypeHint,
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(ctx).colorScheme.error),
                  onPressed: ok ? () => Navigator.of(ctx).pop(true) : null,
                  child: Text(l10n.common_confirm),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final out = await StoreWipeService.instance.wipeSelfTree();
      if (mounted) {
        storageToast(
            context, l10n.storage_wipeSelfDone(fmtStorageBytes(out.freedBytes)));
      }
    } catch (e) {
      if (mounted) storageToast(context, l10n.storage_wipeSelfFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.storage_entryAdvanced)),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l10n.storage_export,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.storage_exportTreeDesc,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _exportStoreTree,
                          icon: const Icon(Icons.folder_copy_outlined,
                              size: 18),
                          label: Text(l10n.storage_exportTree),
                        ),
                      ),
                      const Divider(height: 24),
                      Text(l10n.storage_exportWebdavDesc,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _exportStoreWebdav,
                          icon: const Icon(Icons.cloud_upload_outlined,
                              size: 18),
                          label: Text(l10n.storage_exportWebdav),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(l10n.storage_dangerZone,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      )),
              const SizedBox(height: 8),
              Card(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.35),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.storage_wipeSelfDesc,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _wipeSelfStore,
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                          icon: const Icon(Icons.delete_forever, size: 18),
                          label: Text(l10n.storage_wipeSelf),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_busy) const StorageBusyOverlay(),
        ],
      ),
    );
  }
}
