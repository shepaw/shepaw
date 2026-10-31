import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/settings/settings_sections.dart';
import '../../services/update_service.dart';
import '../../widgets/update_settings_badge.dart';

/// 桌面「设置」模式的中栏：分类列表 + 底部退出登录。
///
/// 右栏显示选中分类的几项（[SettingsCategoryPage]）。移动端没有这一层，
/// 直接把全部分区铺成一页。
class SettingsCategoryPanel extends StatelessWidget {
  const SettingsCategoryPanel({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onLogout,
  });

  final SettingsCategory selected;
  final ValueChanged<SettingsCategory> onSelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_title),
        automaticallyImplyLeading: false,
        actions: const [
          SettingsUpdateBadge(child: Icon(Icons.settings_outlined)),
          SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final category in SettingsCategory.values)
                  ListTile(
                    leading: Icon(
                      category.icon,
                      color: selected == category ? scheme.primary : null,
                    ),
                    title: Text(
                      category.title(l10n),
                      style: TextStyle(
                        fontWeight: selected == category
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected == category ? scheme.primary : null,
                      ),
                    ),
                    selected: selected == category,
                    onTap: () => onSelected(category),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(
              l10n.drawer_logout,
              style: const TextStyle(color: Colors.red),
            ),
            onTap: onLogout,
          ),
        ],
      ),
    );
  }
}

/// 退出登录前的确认框，桌面中栏和移动端设置页共用。
Future<bool?> confirmLogout(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final dialogL10n = AppLocalizations.of(dialogContext);
      return AlertDialog(
        title: Text(dialogL10n.logout_confirmTitle),
        content: Text(dialogL10n.logout_confirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogL10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              dialogL10n.drawer_logout,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      );
    },
  ).then((value) {
    if (value == true) UpdateService().dismissSettingsIconBadge();
    return value;
  });
}
