import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../she_memory_screen.dart';
import '../location_settings_screen.dart';
import 'settings_model.dart';
import '../../providers/locale_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/model_registry.dart';
import '../../services/skill_registry.dart';
import '../../utils/layout_utils.dart';
import '../../widgets/model_icon.dart';
import '../../widgets/update_dialog.dart';
import '../change_password_screen.dart';
import '../instruction_set_screen.dart';
import '../cli_config_management_screen.dart';
import '../event_management/event_management_screen.dart';
import '../host_config_screen.dart';
import '../inference_log_screen.dart';
import '../language_settings_screen.dart';
import '../appearance_settings_screen.dart';
import '../log_viewer_screen.dart';
import '../model_management_screen.dart';
import '../notification_settings_screen.dart';
import '../privacy_policy_screen.dart';
import '../skill_management_screen.dart';
import '../storage_space_manage_screen.dart';
import '../user_profile_settings_screen.dart';
import '../../task/screens/scheduled_tasks_management_screen.dart';

/// 设置页的分类。移动端按顺序铺成一页，桌面端用它在中栏做分类列表。
enum SettingsCategory {
  general,
  security,
  hostPouch,
  developer,
  about,
}

extension SettingsCategoryUi on SettingsCategory {
  String title(AppLocalizations l10n) => switch (this) {
        SettingsCategory.general => l10n.settings_general,
        SettingsCategory.security => l10n.settings_security,
        SettingsCategory.hostPouch => l10n.settings_hostPouchSection,
        SettingsCategory.developer => l10n.settings_developerTools,
        SettingsCategory.about => l10n.settings_about,
      };

  IconData get icon => switch (this) {
        SettingsCategory.general => Icons.tune_outlined,
        SettingsCategory.security => Icons.shield_outlined,
        SettingsCategory.hostPouch => Icons.inventory_2_outlined,
        SettingsCategory.developer => Icons.code_outlined,
        SettingsCategory.about => Icons.info_outlined,
      };
}

/// 分区组件要用的状态和动作，由 SettingsScreen 组装。
///
/// 状态留在 SettingsScreen 里（生物识别、电池优化、位置、袋子名都要异步
/// 加载或回调刷新），分区只负责摆 tile。
class SettingsEntries {
  const SettingsEntries({
    required this.l10n,
    required this.openPage,
    required this.biometricLoading,
    required this.biometricSupported,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    required this.batteryOptIgnored,
    required this.onBatteryOptimization,
    required this.locationSubtitle,
    required this.onLocation,
    required this.pouchName,
    required this.pouchHost,
    required this.onRenamePouch,
    required this.onSwitchPouch,
    required this.onHostSetup,
    required this.onSheMemory,
    required this.onAbout,
  });

  final AppLocalizations l10n;

  /// push 一页，关闭后刷新（SettingsScreen 的 _openAndRefresh）。
  final Future<void> Function(Widget page) openPage;

  final bool biometricLoading;
  final bool biometricSupported;
  final bool biometricEnabled;
  final ValueChanged<bool>? onBiometricChanged;

  final bool batteryOptIgnored;
  final VoidCallback? onBatteryOptimization;

  final String locationSubtitle;
  final Future<void> Function()? onLocation;

  final String pouchName;
  final String pouchHost;
  final void Function(BuildContext)? onRenamePouch;
  final void Function(BuildContext)? onSwitchPouch;

  final VoidCallback? onHostSetup;
  final VoidCallback? onSheMemory;
  final VoidCallback? onAbout;
}

/// 移动端设置页 / 桌面某个分类共用的分区内容。
class SettingsSections {
  SettingsSections._();

  static List<Widget> general(BuildContext context, SettingsEntries e) {
    final l10n = e.l10n;
    return [
      ListTile(
        leading: const Icon(Icons.notifications),
        title: Text(l10n.settings_notifications),
        subtitle: Text(l10n.settings_notificationsSub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const NotificationSettingsScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.language),
        title: Text(l10n.settings_language),
        subtitle: Text(context.watch<LocaleProvider>().currentLabel(context)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const LanguageSettingsScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.dark_mode_outlined),
        title: Text(l10n.settings_appearance),
        subtitle: Text(context.watch<ThemeProvider>().currentLabel(context)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const AppearanceSettingsScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.location_on_outlined),
        title: Text(l10n.settings_location),
        subtitle: Text(e.locationSubtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: e.onLocation,
      ),
      if (Platform.isAndroid) ...[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.battery_saver),
          title: Text(l10n.settings_batteryOptimization),
          subtitle: Text(
            e.batteryOptIgnored
                ? l10n.settings_batteryOptimizationIgnored
                : l10n.settings_batteryOptimizationSub,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: e.onBatteryOptimization,
        ),
      ],
      // 惜宝长期记忆归到惜宝的储物袋后（P3）这一项会移走。
      if (e.onSheMemory != null) ...[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(l10n.settings_sheMemory),
          subtitle: Text(l10n.settings_sheMemorySub),
          trailing: const Icon(Icons.chevron_right),
          onTap: e.onSheMemory,
        ),
      ],
    ];
  }

  static List<Widget> security(BuildContext context, SettingsEntries e) {
    final l10n = e.l10n;
    return [
      ListTile(
        leading: const Icon(Icons.lock_reset),
        title: Text(l10n.settings_changePassword),
        subtitle: Text(l10n.settings_changePasswordSub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const ChangePasswordScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.fingerprint),
        title: Text(l10n.settings_biometric),
        subtitle: Text(
          !e.biometricLoading && !e.biometricSupported
              ? l10n.settings_biometricNotSupported
              : l10n.settings_biometricSub,
        ),
        trailing: e.biometricLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Switch(
                value: e.biometricEnabled,
                onChanged: e.biometricSupported ? e.onBiometricChanged : null,
              ),
      ),
    ];
  }

  static List<Widget> hostPouch(BuildContext context, SettingsEntries e) {
    final l10n = e.l10n;
    return [
      ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(l10n.storage_manageTitle),
        subtitle: Text(l10n.storage_settingsEntrySub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const StorageSpaceManageScreen()),
      ),
      if (e.pouchName.isNotEmpty) ...[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.drive_file_rename_outline),
          title: Text(l10n.settings_renamePouch),
          subtitle: Text(e.pouchName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => e.onRenamePouch?.call(context),
        ),
      ],
      const Divider(),
      ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text(l10n.settings_switchPouch),
        subtitle: e.pouchName.isEmpty
            ? null
            : Text(l10n.settings_switchPouchCurrent(e.pouchName, e.pouchHost)),
        onTap: () => e.onSwitchPouch?.call(context),
      ),
      // 主机相关的两项只在桌面平台出现。
      if (!(Platform.isAndroid || Platform.isIOS)) ...[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(l10n.contacts_host),
          subtitle: Text(l10n.hostSetup_title),
          trailing: const Icon(Icons.chevron_right),
          onTap: e.onHostSetup,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: Text(l10n.hostConfig_title),
          subtitle: Text(l10n.hostConfig_subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => e.openPage(const HostConfigScreen()),
        ),
      ],
    ];
  }

  static List<Widget> developer(BuildContext context, SettingsEntries e) {
    final l10n = e.l10n;
    return [
      ListTile(
        leading: const Icon(Icons.psychology),
        title: Text(l10n.settings_inferenceLog),
        subtitle: Text(l10n.settings_inferenceLogSub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          LayoutUtils.openFloatingPanel(
            context: context,
            key: 'inference_log',
            title: l10n.settings_inferenceLog,
            builder: (context) => const InferenceLogScreen(embedded: true),
          );
        },
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.article_outlined),
        title: Text(l10n.settings_systemLog),
        subtitle: Text(l10n.settings_systemLogSub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          LayoutUtils.openFloatingPanel(
            context: context,
            key: 'system_log',
            title: l10n.settings_systemLog,
            builder: (context) => const LogViewerScreen(embedded: true),
          );
        },
      ),
    ];
  }

  static List<Widget> about(BuildContext context, SettingsEntries e) {
    final l10n = e.l10n;
    return [
      ListTile(
        leading: const Icon(Icons.info),
        title: Text(l10n.settings_about),
        subtitle: FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final version = snapshot.data?.version ?? '';
            return Text('v$version');
          },
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: e.onAbout,
      ),
      const CheckForUpdatesListTile(),
      ListTile(
        leading: const Icon(Icons.privacy_tip_outlined),
        title: Text(l10n.settings_privacyPolicy),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const PrivacyPolicyScreen()),
      ),
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text(l10n.settings_termsOfService),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => e.openPage(const PrivacyPolicyScreen(showTerms: true)),
      ),
    ];
  }

  /// 「我的」里用到的能力项（模型、指令集、技能、CLI、事件、定时任务）。
  ///
  /// 这些不是偏好设置，放在「我的」里；桌面才多一项定时任务。
  static List<Widget> capabilities(
    BuildContext context, {
    required AppLocalizations l10n,
    required Future<void> Function(Widget page) openPage,
  }) {
    return [
      ListTile(
        leading: const ModelIcon(),
        title: Text(l10n.toolModel_managementTitle),
        subtitle: Text(
          l10n.toolModel_count(ModelRegistry.instance.definitions.length),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(const ModelManagementScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.playlist_add_check_outlined),
        title: Text(l10n.instructionSet_title),
        subtitle: Text(l10n.instructionSet_subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(const InstructionSetScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: Text(l10n.skillMgmt_title),
        subtitle: Text(
          SkillRegistry.instance.skills.isEmpty
              ? l10n.settings_skillsSub
              : l10n.skillMgmt_skillCount(SkillRegistry.instance.skills.length),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(const SkillManagementScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.terminal),
        title: Text(l10n.osTool_configTitle),
        subtitle: Text(l10n.settings_cliSub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(const CliConfigManagementScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.sensors),
        title: Text(l10n.eventMgmt_title),
        subtitle: Text(l10n.eventMgmt_subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(const EventManagementScreen()),
      ),
      if (!(Platform.isAndroid || Platform.isIOS)) ...[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: Text(l10n.scheduledTasks_title),
          subtitle: Text(l10n.scheduledTasks_description),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(const ScheduledTasksManagementScreen()),
        ),
      ],
    ];
  }

  /// 「我的」里的个人档案入口（名片点开的那页）。
  static Widget profileTile(
    BuildContext context, {
    required AppLocalizations l10n,
    required Future<void> Function(Widget page) openPage,
  }) {
    return ListTile(
      leading: const Icon(Icons.person),
      title: Text(l10n.settings_userProfile),
      subtitle: Text(l10n.settings_userProfileSub),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openPage(const UserProfileSettingsScreen()),
    );
  }

  /// 关于对话框。原来在 SettingsScreen 里，抽出来给「关于」分区用。
  static Future<void> showAbout(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: l10n.appTitle,
      applicationVersion: packageInfo.version,
      applicationLegalese: l10n.about_legalese,
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset(
          'assets/images/shepaw_icon.png',
          width: 48,
          height: 48,
        ),
      ),
      children: [
        const SizedBox(height: 12),
        Text(l10n.about_content),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () async {
              final uri = Uri.parse('https://github.com/shepaw/shepaw');
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: Text(l10n.about_sourceRepo),
          ),
        ),
      ],
    );
  }
}

/// 桌面设置右栏：自己持一份 [SettingsModel] 加载分类需要的状态，
/// 按 [category] 渲染对应的几项。
class SettingsCategoryPane extends StatefulWidget {
  const SettingsCategoryPane({super.key, required this.category});

  final SettingsCategory category;

  @override
  State<SettingsCategoryPane> createState() => _SettingsCategoryPaneState();
}

class _SettingsCategoryPaneState extends State<SettingsCategoryPane> {
  late final SettingsModel _model = SettingsModel();

  @override
  void initState() {
    super.initState();
    unawaited(_model.init());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) => SettingsCategoryPage(
        category: widget.category,
        entries: _entries(l10n),
      ),
    );
  }

  SettingsEntries _entries(AppLocalizations l10n) => SettingsEntries(
        l10n: l10n,
        openPage: (page) => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => page),
        ),
        biometricLoading: _model.biometricLoading,
        biometricSupported: _model.biometricSupported,
        biometricEnabled: _model.biometricEnabled,
        onBiometricChanged: (v) => _model.setBiometric(context, v),
        batteryOptIgnored: _model.batteryOptIgnored,
        onBatteryOptimization: () => _model.openBatteryOptimization(context),
        locationSubtitle: _model.locationSubtitle(l10n),
        onLocation: () async {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const LocationSettingsScreen(),
            ),
          );
          await _model.loadLocationState();
        },
        pouchName: _model.pouchName,
        pouchHost: _model.pouchHost,
        onRenamePouch: (ctx) => _model.renamePouch(ctx),
        onSwitchPouch: (ctx) => _model.confirmSwitchPouch(ctx),
        // 必须走根 Navigator：右栏是子 Navigator，它的 onGenerateRoute 不看
        // 路由名；而主机流程内部靠 pushReplacementNamed 在命名路由之间跳转。
        onHostSetup: () =>
            Navigator.of(context, rootNavigator: true).pushNamed('/host-setup'),
        onSheMemory: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const SheMemoryScreen()),
        ),
        onAbout: () => SettingsSections.showAbout(context, l10n),
      );
}

/// 桌面设置的中栏分类页：只显示 [category] 对应的那几项。
class SettingsCategoryPage extends StatelessWidget {
  const SettingsCategoryPage({
    super.key,
    required this.category,
    required this.entries,
  });

  final SettingsCategory category;
  final SettingsEntries entries;

  @override
  Widget build(BuildContext context) {
    final l10n = entries.l10n;
    final children = switch (category) {
      SettingsCategory.general => SettingsSections.general(context, entries),
      SettingsCategory.security => SettingsSections.security(context, entries),
      SettingsCategory.hostPouch =>
        SettingsSections.hostPouch(context, entries),
      SettingsCategory.developer =>
        SettingsSections.developer(context, entries),
      SettingsCategory.about => SettingsSections.about(context, entries),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(category.title(l10n)),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: children,
      ),
    );
  }
}
