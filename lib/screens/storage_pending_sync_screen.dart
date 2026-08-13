import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/sync_engine.dart';
import '../widgets/storage/storage_pending_sync_card.dart';
import 'storage_shared.dart';

/// 待同步到 master 的完整路径清单。
class StoragePendingSyncScreen extends StatelessWidget {
  const StoragePendingSyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final engine = SyncEngine.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_pendingToMaster),
        actions: [
          IconButton(
            tooltip: l10n.storage_sharedSyncNow,
            onPressed: () => engine.syncNow(),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: StreamBuilder<SyncStatus>(
        stream: engine.status,
        initialData: engine.latestStatus,
        builder: (context, snap) {
          final status = snap.data ?? SyncStatus.empty;
          final items = status.items;
          if (!status.hasPending && !status.isSyncing) {
            return Center(
              child: Text(
                l10n.storage_pendingEmpty,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            );
          }
          final remaining = status.expandedCount > items.length
              ? status.expandedCount - items.length
              : 0;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                l10n.storage_sharedSyncPending(
                  status.pendingCount,
                  fmtStorageBytes(status.pendingBytes),
                ),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                !status.masterOnline
                    ? l10n.storage_pendingWaitingMaster
                    : status.isSyncing
                        ? l10n.storage_pendingUploading
                        : l10n.storage_pendingToMaster,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              StoragePendingSyncList(
                items: items,
                uploadingSeq: status.uploadingSeq,
                footer: remaining > 0
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          l10n.storage_pendingMore(remaining),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      )
                    : null,
              ),
            ],
          );
        },
      ),
    );
  }
}
