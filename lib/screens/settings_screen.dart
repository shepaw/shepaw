import 'dart:async';

import 'package:flutter/material.dart';
import 'settings/settings_model.dart';
import 'settings/settings_sections.dart';
import '../l10n/app_localizations.dart';
import 'location_settings_screen.dart';
import 'she_memory_screen.dart';
import '../services/update_service.dart';

/// Settings screen
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsModel _model = SettingsModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 设置页不再常驻挂载（移动端在「我的」里，桌面是独立模式），打开即清角标。
      UpdateService().dismissSettingsIconBadge();
    });
    unawaited(_model.init());
  }

  /// Push 一页设置子页，回来后刷新（计数类副标题会变）。
  Future<void> _openAndRefresh(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) setState(() {});
  }

  SettingsEntries _entries(AppLocalizations l10n) => SettingsEntries(
        l10n: l10n,
        openPage: _openAndRefresh,
        biometricLoading: _model.biometricLoading,
        biometricSupported: _model.biometricSupported,
        biometricEnabled: _model.biometricEnabled,
        onBiometricChanged: (v) => _model.setBiometric(context, v),
        batteryOptIgnored: _model.batteryOptIgnored,
        onBatteryOptimization: () => _model.openBatteryOptimization(context),
        locationSubtitle: _model.locationSubtitle(l10n),
        onLocation: () async {
          await _openAndRefresh(const LocationSettingsScreen());
          await _model.loadLocationState();
        },
        pouchName: _model.pouchName,
        pouchHost: _model.pouchHost,
        onRenamePouch: (ctx) => _model.renamePouch(ctx),
        onSwitchPouch: (ctx) => _model.confirmSwitchPouch(ctx),
        // 必须走根 Navigator：设置页挂在自己的子 Navigator 上，它的
        // onGenerateRoute 不看路由名；而主机流程内部靠 pushReplacementNamed
        // 在命名路由之间跳转，只有根 Navigator 认得这些名字。
        onHostSetup: () =>
            Navigator.of(context, rootNavigator: true).pushNamed('/host-setup'),
        onSheMemory: () => _openAndRefresh(const SheMemoryScreen()),
        onAbout: () => SettingsSections.showAbout(context, l10n),
      );

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildLogoutTile(AppLocalizations l10n) {
    return ListTile(
      leading: const Icon(Icons.logout, color: Colors.red),
      title: Text(
        l10n.drawer_logout,
        style: const TextStyle(color: Colors.red),
      ),
      onTap: () {
        final screenContext = context;
        showDialog(
          context: screenContext,
          builder: (dialogContext) {
            final dialogL10n = AppLocalizations.of(dialogContext);
            return AlertDialog(
              title: Text(dialogL10n.logout_confirmTitle),
              content: Text(dialogL10n.logout_confirmContent),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(dialogL10n.common_cancel),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await SettingsModel.logoutToGate();
                  },
                  child: Text(
                    dialogL10n.drawer_logout,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 生物识别 / 电池优化 / 位置 / 袋子名都是异步加载的，加载完要重画。
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) => _buildBody(l10n),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    final context = this.context;
    final entries = _entries(l10n);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: Navigator.canPop(context),
        title: Text(l10n.settings_title),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 16),
          _sectionHeader(l10n.settings_general),
          ...SettingsSections.general(context, entries),
          const Divider(height: 32),
          _sectionHeader(l10n.settings_security),
          ...SettingsSections.security(context, entries),
          const Divider(height: 32),
          _sectionHeader(l10n.settings_hostPouchSection),
          ...SettingsSections.hostPouch(context, entries),
          const Divider(height: 32),
          _sectionHeader(l10n.settings_developerTools),
          ...SettingsSections.developer(context, entries),
          const Divider(height: 32),
          _sectionHeader(l10n.settings_about),
          ...SettingsSections.about(context, entries),
          const Divider(height: 32),
          _buildLogoutTile(l10n),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
