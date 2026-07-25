import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../providers/locale_provider.dart';
import 'change_password_screen.dart';
import 'privacy_policy_screen.dart';
import 'notification_settings_screen.dart';
import 'vault_restore_screen.dart';
import 'language_settings_screen.dart';
import 'inference_log_screen.dart';
import 'log_viewer_screen.dart';
import 'user_profile_settings_screen.dart';
import 'agent_memory_management_screen.dart';
import '../utils/layout_utils.dart';
import '../services/local_database_service.dart';
import '../services/cognition_service.dart';
import '../services/she_memory_db_service.dart';
import '../services/agent_memory_db_service.dart';
import '../services/local_file_storage_service.dart';
import '../services/data_export_import_service.dart';
import '../services/logger_service.dart';
import '../services/biometric_service.dart';
import '../services/inference_log_service.dart';
import '../widgets/update_dialog.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
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

  @override
  void initState() {
    super.initState();
    _loadBiometricState();
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

          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.settings_dataVault),
            subtitle: Text(l10n.settings_dataVaultSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const VaultRestoreScreen(),
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

          // Battery optimization (Android only)
          if (!kIsWeb && Platform.isAndroid) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.battery_saver),
              title: const Text('Battery Optimization'),
              subtitle: const Text('Disable to prevent agent tasks from being interrupted in background'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                FlutterForegroundTask.requestIgnoreBatteryOptimization();
              },
            ),
          ],

          const Divider(height: 32),

          // Data management section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_dataManagement,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Personal Profile'),
            subtitle: const Text('Manage your personal information'),
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
            leading: const Icon(Icons.memory),
            title: const Text('Agent Memories'),
            subtitle: const Text('View and manage memories for each agent'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AgentMemoryManagementScreen(),
                ),
              );
            },
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: Text(l10n.settings_exportData),
            subtitle: Text(l10n.settings_exportDataSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showExportDataDialog(context),
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l10n.settings_clearAllData),
            subtitle: Text(l10n.settings_clearAllDataSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showClearAllDataDialog(context),
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
                applicationName: 'Paw',
                applicationVersion: packageInfo.version,
                applicationIcon: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/images/shepaw_icon.png',
                    width: 48,
                    height: 48,
                  ),
                ),
                children: [
                  Text(l10n.appDescription),
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

  // ── Export / Clear data ───────────────────────────────────────────────────

  /// 显示导出数据确认对话框
  void _showExportDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.settings_exportDataTitle),
          content: Text(dialogL10n.settings_exportDataContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(dialogL10n.common_cancel),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _exportData(context);
              },
              child: Text(dialogL10n.settings_exportData),
            ),
          ],
        );
      },
    );
  }

  /// 导出所有数据
  Future<void> _exportData(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Text(l10n.settings_exportingData),
            ],
          ),
          duration: const Duration(seconds: 10),
        ),
      );

      final exportService = DataExportImportService(
        LocalDatabaseService(),
        LocalFileStorageService(),
        LoggerService(),
      );

      final zipPath = await exportService.exportAllData();

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (zipPath != null) {
        await Share.shareXFiles([XFile(zipPath)]);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.settings_exportSuccess),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.settings_exportFailed('Unknown error')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settings_exportFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 显示清除所有数据确认对话框
  void _showClearAllDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.settings_clearAllDataTitle),
          content: Text(dialogL10n.settings_clearAllDataContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(dialogL10n.common_cancel),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _clearAllData(context);
              },
              child: Text(
                dialogL10n.settings_clearAllDataButton,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 清除所有数据
  Future<void> _clearAllData(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Text(l10n.settings_clearingAllData),
            ],
          ),
          duration: const Duration(seconds: 5),
        ),
      );

      final db = LocalDatabaseService();
      await db.clearAllData();

      await CognitionService.instance.clearAll();

      // She 的记忆（soul / long_term_memory / self_notes 等）与各 Agent 的
      // 独立记忆库也属于「全部数据」，一并清除。
      await SheMemoryDbService().clearSheMemory();
      await AgentMemoryDbService.deleteAllDatabases();

      InferenceLogService.instance.clearAll();

      final fileStorage = LocalFileStorageService();
      await fileStorage.clearAllResources();

      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settings_clearAllDataSuccess),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settings_clearAllDataFailed('$e')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
