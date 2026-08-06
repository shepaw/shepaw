import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/handoff_notify_service.dart';
import '../storage/import_auth_service.dart';
import 'she_circle_screen.dart';
import 'storage_advanced_screen.dart';
import 'storage_import_screen.dart';
import 'storage_nexuspouch_screen.dart';
import 'storage_shared.dart';
import 'storage_snapshots_screen.dart';
import 'storage_space_manage_screen.dart';

/// 储物袋功能入口（桌面中间栏列表 / 总览告警跳转共用）。
enum StorageBagEntry {
  snapshots,
  space,
  nas,
  import,
  sheCircle,
  advanced,
}

/// 储物袋总览页（重构：原 7 区块单页堆叠 → 总览仪表盘 + 子页）。
///
/// 移动端：用量总览 + 告警 + 5 个功能入口（push 子页）。
/// 桌面 embedded：仅入口列表，选中回调由父级在右侧展示详情。
class StorageSpaceScreen extends StatefulWidget {
  final bool embedded;
  final StorageBagEntry? selectedEntry;
  final ValueChanged<StorageBagEntry>? onEntrySelected;

  const StorageSpaceScreen({
    super.key,
    this.embedded = false,
    this.selectedEntry,
    this.onEntrySelected,
  });

  @override
  State<StorageSpaceScreen> createState() => StorageSpaceScreenState();
}

class StorageSpaceScreenState extends State<StorageSpaceScreen> {
  late Future<StorageOverviewSummary> _future;
  StreamSubscription<ImportRequest>? _importCreatedSub;
  StreamSubscription<ImportGrant>? _importGrantSub;
  StreamSubscription<void>? _handoffSub;

  @override
  void initState() {
    super.initState();
    _future = loadStorageOverview();
    HandoffNotifyService.instance.start();
    _importCreatedSub = ImportRequestBus.instance.onCreated.listen((_) {
      if (mounted) unawaited(_refresh());
    });
    _importGrantSub = ImportGrantBus.instance.onReceived.listen((_) {
      if (mounted) unawaited(_refresh());
    });
    _handoffSub = HandoffNotifyService.instance.onChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _importCreatedSub?.cancel();
    _importGrantSub?.cancel();
    _handoffSub?.cancel();
    super.dispose();
  }

  Future<void> reload() => _refresh();

  Future<void> _refresh() async {
    setState(() => _future = loadStorageOverview());
  }

  /// 进入子页；返回后刷新摘要（子页操作可能改变状态）。
  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) unawaited(_refresh());
  }

  void _selectOrOpen(StorageBagEntry entry, Widget screen) {
    if (widget.onEntrySelected != null) {
      widget.onEntrySelected!(entry);
      return;
    }
    unawaited(_open(screen));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.storage_title),
        elevation: widget.embedded ? 0 : null,
      ),
      body: FutureBuilder<StorageOverviewSummary>(
        future: _future,
        builder: (context, snap) {
          final s = snap.data;
          if (widget.embedded) {
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _buildEntries(l10n, s, asCard: false),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StorageOverviewBody(
                summary: s,
                onOpenEntry: (entry) => _selectOrOpen(entry, entry.screen),
              ),
              const SizedBox(height: 20),
              _buildEntries(l10n, s, asCard: true),
            ],
          );
        },
      ),
    );
  }

  /// 功能入口列表。
  Widget _buildEntries(
    AppLocalizations l10n,
    StorageOverviewSummary? s, {
    required bool asCard,
  }) {
    final sched = s?.schedStatus;
    final snapshotSubtitle = s == null
        ? ''
        : '${sched != null && sched.enabled ? l10n.storage_autoShortOn : l10n.storage_autoShortOff}'
            ' · ${l10n.storage_snapshotCount(s.snapshotCount)}'
            '${sched != null && sched.lastSuccessMs > 0 ? ' · ${l10n.storage_lastSuccess(_fmtTime(sched.lastSuccessMs))}' : ''}';

    final spaceSubtitle = s == null
        ? ''
        : '${fmtStorageBytes(s.myTotalBytes)}'
            '${s.unsyncedCount > 0 ? ' · ${l10n.storage_unsynced(s.unsyncedCount, fmtStorageBytes(s.unsyncedBytes))}' : ''}';

    final importSubtitle = s != null && s.pendingImportCount > 0
        ? l10n.storage_alertPendingImports(s.pendingImportCount)
        : l10n.storage_importEntryHint;

    final circleSubtitle = s == null
        ? ''
        : s.exchangeEnabled
            ? l10n.storage_ownerPeerCount(s.ownerPeerCount)
            : l10n.storage_autoSnapshotOff;

    final tiles = <Widget>[
      _entryTile(
        entry: StorageBagEntry.snapshots,
        icon: Icons.backup_outlined,
        title: l10n.storage_entrySnapshots,
        subtitle: snapshotSubtitle,
        onTap: () => _selectOrOpen(
          StorageBagEntry.snapshots,
          const StorageSnapshotsScreen(),
        ),
      ),
      _entryTile(
        entry: StorageBagEntry.space,
        icon: Icons.dns_outlined,
        title: l10n.storage_entrySpace,
        subtitle: spaceSubtitle,
        onTap: () => _selectOrOpen(
          StorageBagEntry.space,
          const StorageSpaceManageScreen(),
        ),
      ),
      _entryTile(
        entry: StorageBagEntry.nas,
        icon: Icons.lan_outlined,
        title: l10n.storage_entryNas,
        subtitle: l10n.storage_nasEntryHint,
        onTap: () => _selectOrOpen(
          StorageBagEntry.nas,
          const StorageNexuspouchScreen(),
        ),
      ),
      _entryTile(
        entry: StorageBagEntry.import,
        icon: Icons.phonelink_ring_outlined,
        title: l10n.storage_importSection,
        subtitle: importSubtitle,
        alert: s != null && s.pendingImportCount > 0,
        onTap: () => _selectOrOpen(
          StorageBagEntry.import,
          const StorageImportScreen(),
        ),
      ),
      _entryTile(
        entry: StorageBagEntry.sheCircle,
        icon: Icons.favorite_outline,
        title: l10n.storage_sheCircleSection,
        subtitle: circleSubtitle,
        onTap: () => _selectOrOpen(
          StorageBagEntry.sheCircle,
          const SheCircleScreen(),
        ),
      ),
      _entryTile(
        entry: StorageBagEntry.advanced,
        icon: Icons.settings_suggest_outlined,
        title: l10n.storage_entryAdvanced,
        subtitle: l10n.storage_advancedEntryHint,
        onTap: () => _selectOrOpen(
          StorageBagEntry.advanced,
          const StorageAdvancedScreen(),
        ),
      ),
    ];

    if (!asCard) {
      return Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            tiles[i],
            if (i < tiles.length - 1) const Divider(height: 1, indent: 56),
          ],
        ],
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            tiles[i],
            if (i < tiles.length - 1) const Divider(height: 1, indent: 56),
          ],
        ],
      ),
    );
  }

  Widget _entryTile({
    required StorageBagEntry entry,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool alert = false,
  }) {
    final selected = widget.selectedEntry == entry;
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
      leading: Icon(icon, color: colorScheme.primary),
      title: Text(title),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              style: alert ? TextStyle(color: colorScheme.error) : null,
            ),
      trailing: widget.embedded
          ? null
          : const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }

  String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

extension StorageBagEntryX on StorageBagEntry {
  Widget get screen {
    switch (this) {
      case StorageBagEntry.snapshots:
        return const StorageSnapshotsScreen();
      case StorageBagEntry.space:
        return const StorageSpaceManageScreen();
      case StorageBagEntry.nas:
        return const StorageNexuspouchScreen();
      case StorageBagEntry.import:
        return const StorageImportScreen();
      case StorageBagEntry.sheCircle:
        return const SheCircleScreen();
      case StorageBagEntry.advanced:
        return const StorageAdvancedScreen();
    }
  }
}

/// 用量卡 + 告警（总览主体，移动端仪表盘使用）。
class StorageOverviewBody extends StatelessWidget {
  final StorageOverviewSummary? summary;
  final ValueChanged<StorageBagEntry>? onOpenEntry;

  const StorageOverviewBody({
    super.key,
    required this.summary,
    this.onOpenEntry,
  });

  void _open(BuildContext context, StorageBagEntry entry) {
    if (onOpenEntry != null) {
      onOpenEntry!(entry);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => entry.screen),
    );
  }

  Future<void> _showHandoffs(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final notices = HandoffNotifyService.instance.notices;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.storage_handoffTitle,
                        style: Theme.of(ctx).textTheme.titleMedium),
                  ),
                  TextButton(
                    onPressed: () {
                      HandoffNotifyService.instance.dismissAll();
                      Navigator.of(ctx).pop();
                    },
                    child: Text(l10n.storage_handoffClear),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (notices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(l10n.storage_handoffEmpty,
                      textAlign: TextAlign.center),
                )
              else
                SizedBox(
                  height: MediaQuery.of(ctx).size.height * 0.4,
                  child: ListView.builder(
                    itemCount: notices.length,
                    itemBuilder: (_, i) {
                      final n = notices[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.handshake_outlined, size: 18),
                        title: Text(n.uri,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (n.context != null && n.context!.isNotEmpty)
                              n.context!,
                            if (n.device.isNotEmpty) n.device,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildUsageCard(context, l10n, s),
        if (s != null) ..._buildAlerts(context, l10n, s),
      ],
    );
  }

  Widget _buildUsageCard(
    BuildContext context,
    AppLocalizations l10n,
    StorageOverviewSummary? s,
  ) {
    final ratio = s?.volumeUsedRatio;
    final warn = s?.volumeWarn ?? false;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context, StorageBagEntry.space),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: s == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.pie_chart_outline,
                            color: Theme.of(context).colorScheme.primary,
                            size: 20),
                        const SizedBox(width: 8),
                        Text(l10n.storage_usageTitle,
                            style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                        if (s.volumeTotalBytes != null &&
                            s.volumeFreeBytes != null)
                          Text(
                            l10n.storage_volumeFree(
                                fmtStorageBytes(s.volumeFreeBytes!),
                                fmtStorageBytes(s.volumeTotalBytes!)),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: warn
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                          )
                        else
                          Text(
                            fmtStorageBytes(s.myTotalBytes),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right,
                            size: 18,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
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
                            warn
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '${l10n.storage_thisDevice} '
                      '${fmtStorageBytes(s.myTotalBytes)}'
                      ' · ${l10n.storage_recycleSection} '
                      '${fmtStorageBytes(s.recycleBytes)}'
                      '${s.stagingBytes > 0 ? ' · staging ${fmtStorageBytes(s.stagingBytes)}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _buildAlerts(
    BuildContext context,
    AppLocalizations l10n,
    StorageOverviewSummary s,
  ) {
    final alerts = <(String, StorageBagEntry)>[];

    if (s.schedStatus?.needsAttention ?? false) {
      alerts.add((
        l10n.storage_snapshotWarning,
        StorageBagEntry.snapshots,
      ));
    }
    if (s.volumeWarn) {
      final pct = ((s.volumeUsedRatio ?? 0) * 100).round();
      alerts.add((
        l10n.storage_volumeWarning(pct),
        StorageBagEntry.space,
      ));
    }
    if (s.unsyncedWarn) {
      alerts.add((
        l10n.storage_unsyncedWarning,
        StorageBagEntry.space,
      ));
    }
    if (s.pendingImportCount > 0) {
      alerts.add((
        l10n.storage_alertPendingImports(s.pendingImportCount),
        StorageBagEntry.import,
      ));
    }
    final handoffCount = HandoffNotifyService.instance.count;
    final widgets = <Widget>[];
    if (handoffCount > 0) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _showHandoffs(context),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.handshake_outlined,
                        color:
                            Theme.of(context).colorScheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.storage_alertHandoffs(handoffCount),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (alerts.isEmpty && widgets.isEmpty) return const [];

    return [
      const SizedBox(height: 12),
      ...widgets,
      for (final (message, entry) in alerts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _open(context, entry),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 18, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(message,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }
}
