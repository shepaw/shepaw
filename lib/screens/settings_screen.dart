import 'package:flutter/material.dart';
import 'settings/settings_sections.dart';
import '../l10n/app_localizations.dart';
import 'location_settings_screen.dart';
import '../services/location_service.dart';
import '../peer/services/peer_storage_service.dart';
import '../onboarding/host_entry.dart';
import '../onboarding/phone_auth_screen.dart';
import '../onboarding/phone_host_store.dart';
import '../onboarding/phone_pouch_memory.dart';
import '../service_locator.dart';
import '../services/cli_host.dart';
import '../services/cli_pouch.dart';
import '../storage/pouch_credential_store.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import '../utils/platform_utils.dart';
import 'she_memory_screen.dart';
import '../services/biometric_service.dart';
import '../services/update_service.dart';
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
  String _pouchName = '';
  String _pouchHost = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 设置页不再常驻挂载（移动端在「我的」里，桌面是独立模式），打开即清角标。
      UpdateService().dismissSettingsIconBadge();
    });
    _loadBiometricState();
    _loadBatteryOptimizationState();
    _loadLocationState();
    _loadPouchLabel();
  }

  Future<void> _loadPouchLabel() async {
    final session = await PouchSessionStore.readActive();
    if (session == null || !mounted) return;
    final peer = await PeerStorageService().getPeerById(session.hostPeerId);
    if (!mounted) return;
    setState(() {
      _pouchName = session.pouchName;
      _pouchHost = peer?.deviceName.trim().isNotEmpty == true
          ? peer!.deviceName
          : session.hostPeerId;
    });
  }

  /// 清掉登录态，用根导航离开设置页。
  ///
  /// 桌面设置盖在子 Navigator 上，那个导航的 `onGenerateRoute` 不管名字，
  /// 一律再生成一张设置页。所以不能用离按钮最近的 Navigator。
  Future<void> _logoutToGate() async {
    final session = await PouchSessionStore.readActive();
    await PhonePouchMemory.rememberSession(session);
    // 退出登录要连本机的设备凭据一起清掉：留着它，下次开机还会自动恢复登录。
    if (session != null) {
      await PouchCredentialStore.instance.delete(session.hostPeerId);
    }
    await PouchSessionStore(await PouchSessionStore.appFile()).forget();
    PouchChannel.clear();
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final desktop = isDesktopPlatform;
    final mode = await HostModeStore.read();
    var binary = desktop ? await CliHost.resolveBinary() : null;
    var initialized = false;
    if (binary != null && mode != HostMode.remote) {
      try {
        initialized = await CliPouch.passwordIsSet(binary);
      } catch (_) {
        initialized = true;
      }
    }
    if (mode == HostMode.remote) binary = null;
    final phoneHost = desktop ? null : await PhoneHostStore.read();
    final route = logoutRoute(
      isDesktop: desktop,
      mode: mode,
      cliInstalled: binary != null,
      pouchInitialized: initialized,
      phoneHasHost: phoneHost != null,
    );
    nav.pushNamedAndRemoveUntil(
      route,
      (_) => false,
      arguments:
          phoneHost == null ? null : PhoneAuthArgs(hostPeerId: phoneHost),
    );
  }

  /// 一台主机只有一只储物袋，只能改名，不能新建。
  Future<void> _renamePouch(BuildContext screenContext) async {
    final name = await showDialog<String>(
      context: screenContext,
      builder: (_) => _PouchRenameDialog(initial: _pouchName),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == _pouchName || !screenContext.mounted) {
      return;
    }
    final l10n = AppLocalizations.of(screenContext);
    final messenger = ScaffoldMessenger.of(screenContext);
    try {
      final session = await PouchSessionStore.readActive();
      if (session == null) throw StateError(l10n.pouch_loginFailed);
      final pouch = await requestPouchRename(
        hostPeerId: session.hostPeerId,
        name: trimmed,
      );
      final updated = session.copyWith(pouchName: pouch.name);
      await PouchSessionStore(await PouchSessionStore.appFile()).save(updated);
      await PouchLoginMemory.write(id: pouch.id, name: pouch.name);
      await PhonePouchMemory.write(session.hostPeerId, [pouch]);
      if (!mounted) return;
      setState(() => _pouchName = pouch.name);
    } catch (error) {
      final message = error is StateError ? error.message : '$error';
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settings_renamePouchFailed(message))),
      );
    }
  }

  Future<void> _confirmSwitchPouch(BuildContext screenContext) async {
    final confirmed = await showDialog<bool>(
      context: screenContext,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(dialogL10n.settings_switchPouchConfirmTitle),
          content: Text(dialogL10n.settings_switchPouchConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogL10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(dialogL10n.common_confirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !screenContext.mounted) return;
    final session = await PouchSessionStore.readActive();
    await PhonePouchMemory.rememberSession(session);
    if (session != null) {
      await PouchCredentialStore.instance.delete(session.hostPeerId);
    }
    await PouchSessionStore(await PouchSessionStore.appFile()).forget();
    PouchChannel.clear();
    if (!screenContext.mounted) return;
    Navigator.of(screenContext, rootNavigator: true).pushNamedAndRemoveUntil(
      '/pouch',
      (_) => false,
      arguments: const PouchLoginArgs(switching: true),
    );
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
            value
                ? l10n.settings_biometricEnabled
                : l10n.settings_biometricDisabled,
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

  SettingsEntries _entries(AppLocalizations l10n) => SettingsEntries(
        l10n: l10n,
        openPage: _openAndRefresh,
        biometricLoading: _biometricLoading,
        biometricSupported: _biometricSupported,
        biometricEnabled: _biometricEnabled,
        onBiometricChanged: _onBiometricChanged,
        batteryOptIgnored: _batteryOptIgnored,
        onBatteryOptimization: _onBatteryOptimizationTap,
        locationSubtitle: _locationSubtitle(l10n),
        onLocation: () async {
          await _openAndRefresh(const LocationSettingsScreen());
          await _loadLocationState();
        },
        pouchName: _pouchName,
        pouchHost: _pouchHost,
        onRenamePouch: _renamePouch,
        onSwitchPouch: _confirmSwitchPouch,
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
                    await _logoutToGate();
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

/// 改名框自己持有 controller。对话框关掉的动画还在跑时不能提前 dispose。
class _PouchRenameDialog extends StatefulWidget {
  const _PouchRenameDialog({required this.initial});

  final String initial;

  @override
  State<_PouchRenameDialog> createState() => _PouchRenameDialogState();
}

class _PouchRenameDialogState extends State<_PouchRenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.settings_renamePouch),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(labelText: l10n.pouchGate_name),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}
