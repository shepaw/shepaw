import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../storage/device_identity.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'storage_browser_screen.dart';
import 'storage_space_settings_screen.dart';

/// 本机空间：直接展示 store 文件列表；用量 / 目录绑定 / 回收站收入「更多设置」。
class StorageSpaceManageScreen extends StatefulWidget {
  const StorageSpaceManageScreen({super.key});

  @override
  State<StorageSpaceManageScreen> createState() =>
      _StorageSpaceManageScreenState();
}

class _StorageSpaceManageScreenState extends State<StorageSpaceManageScreen> {
  int? _usedBytes;

  @override
  void initState() {
    super.initState();
    _loadUsedBytes();
  }

  Future<void> _loadUsedBytes() async {
    try {
      final selfId = await DeviceIdentity.deviceId();
      final store = await StoreService.instance.localStore();
      final stats = await store.stats();
      final devices = (stats['devices'] as Map?)?.cast<String, dynamic>() ?? {};
      final mine = (devices[selfId] as Map?)?.cast<String, dynamic>() ?? {};
      var total = 0;
      for (final space in StoreSpace.all) {
        total += mine[space] as int? ?? 0;
      }
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
