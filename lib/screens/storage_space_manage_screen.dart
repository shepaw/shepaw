import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/store_service.dart';
import '../utils/layout_utils.dart';
import '../widgets/storage/storage_space_hub.dart';
import 'storage_browser_screen.dart';
import 'storage_shared.dart';
import 'storage_space_settings_screen.dart';

/// 储物袋空间：移动端扁平展示本机 + 共享设备；桌面右侧为本机文件浏览器。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({super.key});

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

  void _openSettings(StorageSpaceSettingsSection section) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageSpaceSettingsScreen(initialSection: section),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!LayoutUtils.isDesktopLayout(context)) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.storage_title),
        ),
        body: StorageSpaceHub(localUsedBytes: _usedBytes),
      );
    }

    return StorageBrowserScreen(
      usedBytes: _usedBytes,
      extraActions: [
        PopupMenuButton<StorageSpaceSettingsSection>(
          tooltip: l10n.storage_moreSettings,
          icon: const Icon(Icons.more_horiz),
          position: PopupMenuPosition.under,
          onSelected: _openSettings,
          itemBuilder: (ctx) => _settingsMenuItems(l10n),
        ),
      ],
      extraMenuItems: (ctx) => _settingsMenuItems(l10n),
      onExtraMenuSelected: (value) {
        if (value is StorageSpaceSettingsSection) {
          _openSettings(value);
        }
      },
    );
  }

  List<PopupMenuEntry<StorageSpaceSettingsSection>> _settingsMenuItems(
    AppLocalizations l10n,
  ) {
    return [
      PopupMenuItem(
        value: StorageSpaceSettingsSection.usage,
        child: Text(l10n.storage_usageTitle),
      ),
      PopupMenuItem(
        value: StorageSpaceSettingsSection.bindings,
        child: Text(l10n.storage_bindingsSection),
      ),
      PopupMenuItem(
        value: StorageSpaceSettingsSection.recycle,
        child: Text(l10n.storage_recycleSection),
      ),
    ];
  }
}
