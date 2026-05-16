import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import '../services/local_file_storage_service.dart';
import '../services/data_export_import_service.dart';
import '../services/logger_service.dart';
import '../services/biometric_service.dart';
import '../services/inference_log_service.dart';
import '../services/local_network_service.dart';
import '../services/channel_tunnel_service.dart';
import '../services/remote_agent_service.dart';
import '../services/token_service.dart';
import '../widgets/update_dialog.dart';
import '../main.dart' show globalACPServer, kAcpServerPortKey, kAcpServerDefaultPort, kAcpServerEnabledKey;
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

  // Local service state
  List<String> _lanAddresses = [];
  bool _lanLoading = true;
  bool _acpEnabled = true;   // 用户开关（持久化）
  bool _acpRunning = false;  // 实际运行状态
  String? _acpError;
  int _acpPort = kAcpServerDefaultPort;
  ChannelTunnelConfig? _tunnelConfig;
  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  bool _tunnelLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBiometricState();
    _loadAcpState();
    _loadTunnelState();
  }

  Future<void> _loadAcpState() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(kAcpServerPortKey) ?? kAcpServerDefaultPort;
    final enabled = prefs.getBool(kAcpServerEnabledKey) ?? true;
    final addresses = await LocalNetworkService.getACPServerAddresses(port: port);
    if (mounted) {
      setState(() {
        _acpEnabled = enabled;
        _acpPort = port;
        _acpRunning = globalACPServer.isRunning;
        _acpError = globalACPServer.startError;
        _lanAddresses = addresses;
        _lanLoading = false;
      });
    }
  }

  Future<void> _onAcpToggled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAcpServerEnabledKey, value);
    setState(() => _acpEnabled = value);

    if (value) {
      // 开启：启动 server
      try {
        await globalACPServer.start();
      } catch (e) {
        // start() 失败不抛给 UI，通过 startError 显示
      }
    } else {
      // 关闭：停止 server，同时停止 tunnel
      await globalACPServer.stop();
      if (ChannelTunnelService.instance.isRunning) {
        await ChannelTunnelService.instance.stop();
      }
    }

    setState(() {
      _acpRunning = globalACPServer.isRunning;
      _acpError = globalACPServer.startError;
    });
  }

  Future<void> _loadTunnelState() async {
    // Try to find a local agent with channel config (per-agent design)
    // Fall back to old global SharedPreferences config for backward compatibility
    ChannelTunnelConfig? config;
    try {
      final db = LocalDatabaseService();
      final tokenService = TokenService(db);
      final agentService = RemoteAgentService(db, tokenService);
      final allAgents = await agentService.getAllAgents();
      for (final agent in allAgents) {
        final cfg = agent.channelConfig;
        if (cfg != null && agent.allowExternalAccess) {
          config = cfg;
          break;
        }
      }
    } catch (_) {}
    // Fall back to old global config if no per-agent config found
    if (config == null) {
      config = await ChannelTunnelService.instance.loadConfig();
    }
    if (mounted) {
      setState(() {
        _tunnelConfig = config;
        _tunnelStatus = ChannelTunnelService.instance.currentStatus;
        _tunnelLoading = false;
      });
    }
    // Listen to status stream
    ChannelTunnelService.instance.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _tunnelStatus = status;
        });
      }
    });

    // Auto-connect if configured (use per-agent config directly)
    if (config != null && config.autoConnect &&
        !ChannelTunnelService.instance.isRunning) {
      await ChannelTunnelService.instance.startWithConfig(config);
    }
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
            title: const Text('历史数据保险库'),
            subtitle: const Text('查看并恢复重置密码前的数据备份'),
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

          // Local Service section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.settings_localService,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // LAN address card
          _buildLanAddressCard(l10n),

          const Divider(),

          // Channel Tunnel card
          _buildChannelTunnelCard(l10n),

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

  // ── Local Service widgets ─────────────────────────────────────────────────

  Widget _buildLanAddressCard(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row with Switch
              Row(
                children: [
                  const Icon(Icons.wifi, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.settings_lanAddress,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          l10n.settings_localServiceDesc,
                          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _acpEnabled,
                    onChanged: (value) async {
                      if (!value) {
                        // 关闭时弹出确认对话框
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) {
                            final dialogL10n = AppLocalizations.of(ctx);
                            return AlertDialog(
                              title: Text(dialogL10n.settings_disableServiceTitle),
                              content: Text(dialogL10n.settings_disableServiceContent),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(dialogL10n.common_cancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(
                                    dialogL10n.settings_disableServiceConfirm,
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                        if (confirmed != true) return; // 用户取消，不关闭
                      }
                      _onAcpToggled(value); // 原有逻辑
                    },
                  ),
                ],
              ),
              // Only show detail when enabled
              if (_acpEnabled) ...[
                const SizedBox(height: 6),
                // Status + port row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: _acpRunning ? Colors.green.shade100 : Colors.red.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _acpRunning
                            ? l10n.settings_acpServerRunning
                            : l10n.settings_acpServerStopped,
                        style: TextStyle(
                          fontSize: 11,
                          color: _acpRunning ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.settings_ethernet, size: 13, color: Colors.grey[400]),
                    const SizedBox(width: 3),
                    Text(
                      '$_acpPort',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => _showPortConfigDialog(context),
                      child: Text(
                        l10n.settings_acpChangePort,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
                // Error message
                if (_acpError != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.error_outline, size: 13, color: Colors.red.shade700),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _acpError!,
                          style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  l10n.settings_lanAddressSub,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 8),
                if (_lanLoading)
                  const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (!_acpRunning)
                  Text(
                    l10n.settings_acpServerStopped,
                    style: TextStyle(color: Colors.red.shade400, fontSize: 13),
                  )
                else if (_lanAddresses.isEmpty)
                  Text(
                    l10n.settings_noLanAddress,
                    style: TextStyle(color: Colors.grey[500], fontSize: 13),
                  )
                else
                  ..._lanAddresses.map((addr) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                addr,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              tooltip: l10n.settings_copyLanAddress,
                              onPressed: () => _copyToClipboard(context, addr),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      )),
                // ── Refresh IPs button ─────────────────────────────────────
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _lanLoading = true);
                      _loadAcpState();
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.common_retry),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelTunnelCard(AppLocalizations l10n) {
    final tunnelService = ChannelTunnelService.instance;
    final isRunning = tunnelService.isRunning;
    final hasConfig = _tunnelConfig != null;
    // Tunnel switch: only enabled when ACP server is on and config exists
    final canToggle = _acpEnabled && hasConfig;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row with Switch
              Row(
                children: [
                  const Icon(Icons.cloud_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.settings_channelTunnel,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (hasConfig)
                          _buildTunnelStatusChip(l10n)
                        else
                          Text(
                            l10n.settings_tunnelNotConfigured,
                            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          ),
                      ],
                    ),
                  ),
                  Switch(
                    value: isRunning,
                    onChanged: canToggle
                        ? (value) async {
                            if (value) {
                              // Use per-agent config directly (not global prefs)
                              if (_tunnelConfig != null) {
                                await tunnelService.startWithConfig(_tunnelConfig!);
                              } else {
                                await tunnelService.start();
                              }
                            } else {
                              await tunnelService.stop();
                            }
                            if (mounted) setState(() {});
                          }
                        : null, // 灰色禁用：未配置或 ACP 关闭
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_tunnelLoading)
                const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (!hasConfig)
                _buildTunnelUnconfiguredContent(l10n)
              else
                _buildTunnelConfiguredContent(l10n),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTunnelStatusChip(AppLocalizations l10n) {
    Color bgColor;
    Color textColor;
    String label;

    switch (_tunnelStatus) {
      case TunnelStatus.connected:
        bgColor = Colors.green.shade100;
        textColor = Colors.green.shade700;
        label = l10n.settings_tunnelConnected;
      case TunnelStatus.connecting:
        bgColor = Colors.orange.shade100;
        textColor = Colors.orange.shade700;
        label = l10n.settings_tunnelConnecting;
      case TunnelStatus.disconnected:
        bgColor = Colors.grey.shade200;
        textColor = Colors.grey.shade600;
        label = l10n.settings_tunnelDisconnected;
      case TunnelStatus.error:
        bgColor = Colors.red.shade100;
        textColor = Colors.red.shade700;
        label = l10n.settings_tunnelError;
      case TunnelStatus.idle:
        bgColor = Colors.grey.shade200;
        textColor = Colors.grey.shade600;
        label = l10n.settings_tunnelNotConfigured;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: textColor),
      ),
    );
  }

  Widget _buildTunnelUnconfiguredContent(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settings_tunnelNotConfigured,
          style: TextStyle(fontSize: 13, color: Colors.grey[500], fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  Widget _buildTunnelConfiguredContent(AppLocalizations l10n) {
    // Show tunnel status only; channel config is now managed per-agent
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTunnelStatusChip(l10n),
      ],
    );
  }

  // ── Export / Clear data ───────────────────────────────────────────────────

  /// 显示端口配置对话框
  void _showPortConfigDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final portController = TextEditingController(text: _acpPort.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settings_acpChangePort),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settings_acpPortHint,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.settings_acpPort,
                hintText: kAcpServerDefaultPort.toString(),
                suffixText: l10n.settings_acpPortSuffix,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.common_cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              final portStr = portController.text.trim();
              final port = int.tryParse(portStr);
              if (port == null || port < 1024 || port > 65535) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.settings_acpPortInvalid)),
                );
                return;
              }

              // 保存端口
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt(kAcpServerPortKey, port);

              if (ctx.mounted) Navigator.pop(ctx);

              // 重启 ACP Server
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.settings_acpPortRestarting)),
                );
              }

              try {
                await globalACPServer.stop();
              } catch (_) {}

              // 用新端口重建 server 实例并启动
              // 注意：需要重启 App 才能彻底生效（globalACPServer 是 late 变量）
              // 这里提示用户重启
              if (mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.settings_acpPortRestartRequired),
                    duration: const Duration(seconds: 5),
                  ),
                );
                setState(() {
                  _acpPort = port;
                  _lanAddresses = [];
                  _lanLoading = true;
                });
                _loadAcpState();
              }
            },
            child: Text(l10n.common_save),
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        action: SnackBarAction(
          label: AppLocalizations.of(context).common_ok,
          onPressed: () {},
        ),
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
