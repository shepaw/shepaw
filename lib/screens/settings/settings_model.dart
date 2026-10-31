import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../l10n/app_localizations.dart';
import '../../onboarding/host_entry.dart';
import '../../onboarding/phone_auth_screen.dart';
import '../../onboarding/phone_host_store.dart';
import '../../onboarding/phone_pouch_memory.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/biometric_service.dart';
import '../../services/cli_host.dart';
import '../../services/cli_pouch.dart';
import '../../services/local_database_service.dart';
import '../../services/location_service.dart';
import '../../storage/pouch_credential_store.dart';
import '../../storage/pouch_login.dart';
import '../../storage/pouch_login_client.dart';
import '../../storage/pouch_session.dart';
import '../../utils/platform_utils.dart';
import '../../service_locator.dart' show navigatorKey;

/// 设置页的状态。
///
/// 移动端是一整页，桌面端按分类分栏渲染，两边共用这一份加载逻辑，避免
/// 生物识别 / 电池优化 / 位置 / 袋子名的加载代码写两遍。
class SettingsModel extends ChangeNotifier {
  final BiometricService _biometricService = BiometricService();

  bool biometricLoading = true;
  bool biometricSupported = false;
  bool biometricEnabled = false;

  bool batteryOptIgnored = false;

  Map<String, dynamic>? locationStatus;

  String pouchName = '';
  String pouchHost = '';

  Future<void> init() async {
    await Future.wait([
      _loadBiometricState(),
      _loadBatteryOptimizationState(),
      loadLocationState(),
      _loadPouchLabel(),
    ]);
  }

  Future<void> _loadBiometricState() async {
    try {
      final supported = await _biometricService.isDeviceSupported();
      final enabled = await _biometricService.isBiometricEnabled();
      biometricSupported = supported;
      biometricEnabled = enabled;
      biometricLoading = false;
      notifyListeners();
    } catch (_) {
      biometricSupported = false;
      biometricEnabled = false;
      biometricLoading = false;
      notifyListeners();
    }
  }

  Future<void> setBiometric(BuildContext context, bool value) async {
    final l10n = AppLocalizations.of(context);
    if (value) {
      // 开启前先验证一次身份。
      final authenticated = await _biometricService.authenticate(
        reason: l10n.settings_biometricEnablePrompt,
      );
      if (!authenticated) return;
    }
    await _biometricService.setBiometricEnabled(value);
    biometricEnabled = value;
    notifyListeners();
    if (!context.mounted) return;
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

  Future<void> _loadBatteryOptimizationState() async {
    if (!Platform.isAndroid) return;
    try {
      batteryOptIgnored =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> openBatteryOptimization(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final ignored = batteryOptIgnored
          ? await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings()
          : await _requestIgnoreBatteryOptimization();
      batteryOptIgnored = ignored;
      notifyListeners();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settings_batteryOptimizationError)),
      );
    }
  }

  static Future<bool> _requestIgnoreBatteryOptimization() async {
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      return FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    }
  }

  Future<void> loadLocationState() async {
    try {
      locationStatus = await LocationService.instance.status();
      notifyListeners();
    } catch (_) {}
  }

  String locationSubtitle(AppLocalizations l10n) {
    final status = locationStatus;
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

  Future<void> _loadPouchLabel() async {
    final session = await PouchSessionStore.readActive();
    if (session == null) return;
    final peer = await PeerStorageService().getPeerById(session.hostPeerId);
    pouchName = session.pouchName;
    pouchHost = peer?.deviceName.trim().isNotEmpty == true
        ? peer!.deviceName
        : session.hostPeerId;
    notifyListeners();
  }

  /// 一台主机只有一只储物袋，只能改名，不能新建。
  Future<void> renamePouch(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PouchRenameDialog(initial: pouchName),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == pouchName || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
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
      pouchName = pouch.name;
      notifyListeners();
    } catch (error) {
      if (!context.mounted) return;
      final message = error is StateError ? error.message : '$error';
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settings_renamePouchFailed(message))),
      );
    }
  }

  Future<void> confirmSwitchPouch(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
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
    if (confirmed != true || !context.mounted) return;
    final session = await PouchSessionStore.readActive();
    await PhonePouchMemory.rememberSession(session);
    if (session != null) {
      await PouchCredentialStore.instance.delete(session.hostPeerId);
    }
    await PouchSessionStore(await PouchSessionStore.appFile()).forget();
    PouchChannel.clear();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil(
      '/pouch',
      (_) => false,
      arguments: const PouchLoginArgs(switching: true),
    );
  }

  /// 清掉登录态，用根导航离开设置页。
  ///
  /// 桌面设置盖在子 Navigator 上，那个导航的 `onGenerateRoute` 不看名字，
  /// 一律再生成一张设置页。所以不能用离按钮最近的 Navigator。
  static Future<void> logoutToGate() async {
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
