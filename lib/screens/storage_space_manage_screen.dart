import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/store_service.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';
import 'storage_snapshots_screen.dart';
import 'storage_space_settings_screen.dart';

/// 储物袋本机浏览页「更多」菜单动作。
enum StorageMoreAction {
  usage,
  bindings,
  recycle,
  snapshots,
}

/// 储物袋「更多」菜单：用量 / 目录绑定 / 回收站 / 备份与恢复。
List<PopupMenuEntry<StorageMoreAction>> storageMoreMenuItems(
  AppLocalizations l10n,
) {
  return [
    PopupMenuItem(
      value: StorageMoreAction.usage,
      child: Text(l10n.storage_usageTitle),
    ),
    PopupMenuItem(
      value: StorageMoreAction.bindings,
      child: Text(l10n.storage_bindingsSection),
    ),
    PopupMenuItem(
      value: StorageMoreAction.recycle,
      child: Text(l10n.storage_recycleSection),
    ),
    PopupMenuItem(
      value: StorageMoreAction.snapshots,
      child: Text(l10n.storage_entrySnapshots),
    ),
  ];
}

/// 打开储物袋「更多」菜单对应页面。
Future<void> openStorageMoreAction(
  BuildContext context,
  StorageMoreAction action,
) async {
  switch (action) {
    case StorageMoreAction.usage:
    case StorageMoreAction.bindings:
    case StorageMoreAction.recycle:
      final section = switch (action) {
        StorageMoreAction.usage => StorageSpaceSettingsSection.usage,
        StorageMoreAction.bindings => StorageSpaceSettingsSection.bindings,
        _ => StorageSpaceSettingsSection.recycle,
      };
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StorageSpaceSettingsScreen(initialSection: section),
        ),
      );
    case StorageMoreAction.snapshots:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const StorageSnapshotsScreen(),
        ),
      );
  }
}

/// 储物袋：点击后直接进入本机文件浏览（其他设备空间不在此进入）。
/// 传入 [initialSpace] 时直接落在「空间」Tab 的该分区根目录。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({super.key, this.initialSpace});

  /// 初始分区（null = 默认「最近」文件列表）。
  final String? initialSpace;

  @override
  State<StorageSpaceManageScreen> createState() =>
      _StorageSpaceManageScreenState();
}

class _StorageSpaceManageScreenState extends State<StorageSpaceManageScreen> {
  int? _usedBytes;
  StreamSubscription<void>? _usageSub;

  @override
  void initState() {
    super.initState();
    _loadUsedBytes();
  }

  @override
  void dispose() {
    _usageSub?.cancel();
    super.dispose();
  }

  Future<void> _loadUsedBytes() async {
    try {
      final selfId = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      _usageSub ??= store.usageUpdates.listen((_) {
        if (mounted) unawaited(_loadUsedBytes());
      });
      final stats = await store.stats(blocking: false);
      final total = storageDeviceUsedBytes(stats, selfId);
      if (!mounted) return;
      setState(() => _usedBytes = total);
    } catch (_) {
      // 用量 badge 失败时静默；文件列表仍可浏览。
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StorageBrowserScreen(
      usedBytes: _usedBytes,
      initialSpace: widget.initialSpace,
      extraActions: [
        PopupMenuButton<StorageMoreAction>(
          tooltip: l10n.storage_moreSettings,
          icon: const Icon(Icons.more_horiz),
          position: PopupMenuPosition.under,
          onSelected: (action) =>
              unawaited(openStorageMoreAction(context, action)),
          itemBuilder: (ctx) => storageMoreMenuItems(l10n),
        ),
      ],
      extraMenuItems: (ctx) => storageMoreMenuItems(l10n),
      onExtraMenuSelected: (value) {
        if (value is StorageMoreAction) {
          unawaited(openStorageMoreAction(context, value));
        }
      },
    );
  }
}
