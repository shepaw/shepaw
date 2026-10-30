import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/update_service.dart';
import '../storage/store_protocol.dart';
import '../widgets/update_settings_badge.dart';
import 'settings_screen.dart';
import 'storage_shared.dart';
import 'storage_space_manage_screen.dart';

/// 手机底栏「我的」页：文件、设置的入口。
class MineScreen extends StatelessWidget {
  const MineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.nav_mine),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(storageSpaceLabel(l10n, StoreSpace.files)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const StorageSpaceManageScreen(
                  initialSpace: StoreSpace.files,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const SettingsUpdateBadge(
              child: Icon(Icons.settings_outlined),
            ),
            title: Text(l10n.nav_settings),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              UpdateService().dismissSettingsIconBadge();
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}
