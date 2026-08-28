import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../providers/locale_provider.dart';
import '../providers/theme_provider.dart';
import 'change_password_screen.dart';
import 'privacy_policy_screen.dart';
import 'notification_settings_screen.dart';
import 'language_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'location_settings_screen.dart';
import '../services/location_service.dart';
import 'inference_log_screen.dart';
import 'log_viewer_screen.dart';
import 'user_profile_settings_screen.dart';
import 'model_management_screen.dart';
import 'skill_management_screen.dart';
import 'cli_config_management_screen.dart';
import '../task/screens/scheduled_tasks_management_screen.dart';
import '../utils/layout_utils.dart';
import '../services/biometric_service.dart';
import '../widgets/update_dialog.dart';
import '../services/update_service.dart';
import '../widgets/model_icon.dart';
import '../services/model_registry.dart';
import '../services/skill_registry.dart';
import 'dart:io' show Platform;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Settings screen
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final BiometricService _biometricService = BiometricService();

  bool _biometricEnabled = false;
  bool _biometricSupported = false;
  bool _biometricLoading = true;
  bool _batteryOptIgnored = false;
  Map<String, dynamic>? _locationStatus;

  @override
  void initState() {
    super.initState();
    UpdateService().dismissSettingsIconBadge();
    _loadBiometricState();
    _loadBatteryOptimizationState();
    _loadLocationState();
  }

  Future<void> _loadBiometricState() async {
    try {
      final supported = await _biometricService.isDeviceSupported();
      final enabled = await _biometricService.isBiometricEnabled();
      if (mounted) {
        setState(() {
          _biometricSupported = supported;
          _biometricEnabled = enabled;
          _biometricLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _biometricSupported = false;
          _biometricEnabled = false;
          _biometricLoading = false;
        });
      }
    }
  }

  Future<void> _onBiometricChanged(bool value) async {
    final l10n = AppLocalizations.of(context);
    if (value) {
      // Require biometric verification before enabling
      final authenticated = await _biometricService.authenticate(
        reason: l10n.settings_biometricEnablePrompt,
      );
      if (!authenticated) return;
    }

    await _biometricService.setBiometricEnabled(value);
    if (mounted) {
      setState(() {
        _biometricEnabled = value;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value ? l10n.settings_biometricEnabled : l10n.settings_biometricDisabled,
          ),
        ),
      );
    }
  }

  Future<void> _loadBatteryOptimizationState() async {
    if (!Platform.isAndroid) return;
    try {
      final ignored =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (mounted) {
        setState(() => _batteryOptIgnored = ignored);
      }
    } catch (_) {}
  }

  Future<void> _loadLocationState() async {
    try {
      final status = await LocationService.instance.status();
      if (mounted) setState(() => _locationStatus = status);
    } catch (_) {}
  }

  String _locationSubtitle(AppLocalizations l10n) {
    final status = _locationStatus;
    if (status == null || status['success'] != true) {
      return l10n.settings_locationSub;
    }
    if (status['service_enabled'] != true) {
      return l10n.settings_locationServiceOff;
    }
    if (status['available'] == true) {
      return l10n.settings_locationGranted;
    }
    if (status['permission'] == 'deniedForever') {
      return l10n.settings_locationDeniedForever;
    }
    return l10n.settings_locationDenied;
  }

  Future<void> _onBatteryOptimizationTap() async {
    final l10n = AppLocalizations.of(context);
    try {
      bool ignored;
      if (_batteryOptIgnored) {
        ignored =
            await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
      } else {
        try {
          ignored =
              await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        } catch (_) {
          ignored = await FlutterForegroundTask
              .openIgnoreBatteryOptimizationSettings();
        }
      }
      if (mounted) {
        setState(() => _batteryOptIgnored = ignored);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settings_batteryOptimizationError)),
      );
    }
  }

  /// Push a tool/settings sub-page and refresh list tiles (counts) on return.
  Future<void> _openAndRefresh(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: Navigator.canPop(context),
        title: Text(l10n.settings_title),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),

          // Security settings section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_security,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.lock_reset),
            title: Text(l10n.settings_changePassword),
            subtitle: Text(l10n.settings_changePasswordSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ChangePasswordScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: Text(l10n.settings_biometric),
            subtitle: Text(
              !_biometricLoading && !_biometricSupported
                  ? l10n.settings_biometricNotSupported
                  : l10n.settings_biometricSub,
            ),
            trailing: _biometricLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Switch(
                    value: _biometricEnabled,
                    onChanged: _biometricSupported ? _onBiometricChanged : null,
                  ),
          ),

          const Divider(height: 32),

          // Account settings section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_account,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.person),
            title: Text(l10n.settings_userProfile),
            subtitle: Text(l10n.settings_userProfileSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const UserProfileSettingsScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.notifications),
            title: Text(l10n.settings_notifications),
            subtitle: Text(l10n.settings_notificationsSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationSettingsScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.settings_language),
            subtitle: Text(context.watch<LocaleProvider>().currentLabel(context)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const LanguageSettingsScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: Text(l10n.settings_appearance),
            subtitle: Text(context.watch<ThemeProvider>().currentLabel(context)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AppearanceSettingsScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: Text(l10n.settings_location),
            subtitle: Text(_locationSubtitle(l10n)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await _openAndRefresh(const LocationSettingsScreen());
              await _loadLocationState();
            },
          ),

          // Battery optimization (Android only)
          if (Platform.isAndroid) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.battery_saver),
              title: Text(l10n.settings_batteryOptimization),
              subtitle: Text(
                _batteryOptIgnored
                    ? l10n.settings_batteryOptimizationIgnored
                    : l10n.settings_batteryOptimizationSub,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _onBatteryOptimizationTap,
            ),
          ],

          const Divider(height: 32),

          // Tools & capabilities (moved from primary menu)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_toolsSection,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          ListTile(
            leading: const ModelIcon(),
            title: Text(l10n.toolModel_managementTitle),
            subtitle: Text(
              l10n.toolModel_count(ModelRegistry.instance.definitions.length),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openAndRefresh(
              const ModelManagementScreen(),
            ),
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
            onTap: () => _openAndRefresh(
              const SkillManagementScreen(),
            ),
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.terminal),
            title: Text(l10n.osTool_configTitle),
            subtitle: Text(l10n.settings_cliSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openAndRefresh(
              const CliConfigManagementScreen(),
            ),
          ),

          const Divider(),

          // 定时任务配置不适合移动端操作，入口仅在桌面端提供；
          // 已创建的任务不受入口隐藏影响，调度器照常运行。
          if (!(Platform.isAndroid || Platform.isIOS))
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(l10n.scheduledTasks_title),
              subtitle: Text(l10n.scheduledTasks_description),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openAndRefresh(
                const ScheduledTasksManagementScreen(),
              ),
            ),

          const Divider(height: 32),

          // Developer Tools section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_developerTools,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

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

          const Divider(height: 32),

          // About section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_about,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

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
            onTap: () async {
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
            },
          ),

          const CheckForUpdatesListTile(),

          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.settings_privacyPolicy),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const PrivacyPolicyScreen(),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(l10n.settings_termsOfService),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const PrivacyPolicyScreen(showTerms: true),
                ),
              );
            },
          ),

          const Divider(),

          // Logout
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(
              l10n.drawer_logout,
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  final dialogL10n = AppLocalizations.of(context);
                  return AlertDialog(
                    title: Text(dialogL10n.logout_confirmTitle),
                    content: Text(dialogL10n.logout_confirmContent),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(dialogL10n.common_cancel),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pushNamedAndRemoveUntil(
                            '/login',
                            (route) => false,
                          );
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
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
