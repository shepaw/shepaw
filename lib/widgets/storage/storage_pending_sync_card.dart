import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../screens/storage_shared.dart';
import '../../storage/store_protocol.dart';
import '../../storage/sync_engine.dart';
import '../../storage/sync_journal.dart';

const int kPendingCardPreviewLimit = 8;

/// 备份与恢复页上的「待同步到 master」卡片。
class StoragePendingSyncCard extends StatelessWidget {
  const StoragePendingSyncCard({
    super.key,
    required this.status,
    this.previewLimit = kPendingCardPreviewLimit,
    this.onSeeAll,
  });

  final SyncStatus status;
  final int previewLimit;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (!status.showPendingCard) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final items = status.items;
    final expanded = status.expandedCount;
    final preview = items.take(previewLimit).toList();
    final remaining = expanded > preview.length ? expanded - preview.length : 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status.isSyncing
                      ? Icons.cloud_sync_outlined
                      : Icons.cloud_upload_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.storage_sharedSyncPending(
                          expanded,
                          fmtStorageBytes(status.pendingBytes),
                        ),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(l10n, status),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: status.lastError != null &&
                                      !status.isSyncing
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: status.isSyncing || !status.masterOnline
                      ? null
                      : () => _onSyncNow(context),
                  child: status.isSyncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.storage_sharedSyncNow),
                ),
              ],
            ),
            if (preview.isNotEmpty) ...[
              const Divider(height: 24),
              StoragePendingSyncList(
                items: preview,
                uploadingSeq: status.uploadingSeq,
                dense: true,
              ),
              if (remaining > 0 && onSeeAll != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onSeeAll,
                    child: Text(l10n.storage_pendingSeeAll),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _subtitle(AppLocalizations l10n, SyncStatus status) {
    if (status.isSyncing) return l10n.storage_pendingUploading;
    if (!status.masterOnline) return l10n.storage_pendingWaitingMaster;
    if (status.lastError != null && status.lastError!.isNotEmpty) {
      return l10n.storage_syncFailed(_syncErrorLabel(l10n, status.lastError!));
    }
    return l10n.storage_pendingToMaster;
  }

  Future<void> _onSyncNow(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final before = status.expandedCount;
    await SyncEngine.instance.syncNow();
    if (!context.mounted) return;
    final after = SyncEngine.instance.latestStatus;
    if (after.expandedCount == 0) return;
    if (after.lastError != null && after.lastError!.isNotEmpty) {
      storageToast(
        context,
        l10n.storage_syncFailed(_syncErrorLabel(l10n, after.lastError!)),
      );
    } else if (after.expandedCount >= before) {
      storageToast(
        context,
        l10n.storage_syncStillPending(after.expandedCount),
      );
    }
  }
}

String _syncErrorLabel(AppLocalizations l10n, String code) {
  switch (code) {
    case StoreError.masterOffline:
      return l10n.storage_pendingWaitingMaster;
    default:
      return code;
  }
}

class StoragePendingSyncList extends StatelessWidget {
  const StoragePendingSyncList({
    super.key,
    required this.items,
    this.uploadingSeq,
    this.dense = false,
    this.footer,
  });

  final List<SyncPendingItem> items;
  final int? uploadingSeq;
  final bool dense;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final grouped = <String, List<SyncPendingItem>>{};
    for (final item in items) {
      (grouped[item.space] ??= []).add(item);
    }
    final spaces = grouped.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final space in spaces) ...[
          Padding(
            padding: EdgeInsets.only(bottom: dense ? 4 : 8, top: dense ? 4 : 8),
            child: Text(
              space,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          for (final item in grouped[space]!)
            _PendingRow(
              item: item,
              uploading: uploadingSeq == item.seq,
              dense: dense,
              l10n: l10n,
            ),
        ],
        if (footer != null) footer!,
      ],
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.item,
    required this.uploading,
    required this.dense,
    required this.l10n,
  });

  final SyncPendingItem item;
  final bool uploading;
  final bool dense;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = item.kind == 'delete'
        ? l10n.storage_pendingKindDelete
        : l10n.storage_pendingKindCommit;
    final size = item.size > 0 ? fmtStorageBytes(item.size) : null;
    final subtitle = [
      kind,
      if (size != null) size,
      if (uploading) l10n.storage_pendingUploading,
    ].join(' · ');

    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.kind == 'delete'
                ? Icons.delete_outline
                : uploading
                    ? Icons.cloud_sync_outlined
                    : Icons.cloud_upload_outlined,
            size: 18,
            color: uploading ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(item.path).isEmpty ? item.path : p.basename(item.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            uploading ? FontWeight.w600 : FontWeight.w500,
                      ),
                ),
                Text(
                  item.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: uploading ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
