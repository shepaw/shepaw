import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/notification_provider.dart';
import '../services/notification_service.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({Key? key}) : super(key: key);

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  bool? _osPermissionGranted;
  bool _checkingPermission = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshOsPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshOsPermission();
    }
  }

  Future<void> _refreshOsPermission() async {
    final enabled = await NotificationService().areNotificationsEnabled();
    if (!mounted) return;
    setState(() {
      _osPermissionGranted = enabled;
      _checkingPermission = false;
    });
  }

  Future<void> _openSystemSettings() async {
    await NotificationService().openSystemSettings();
  }

  Future<void> _onEnableChanged(
    NotificationProvider provider,
    bool value,
  ) async {
    final l10n = AppLocalizations.of(context);
    if (value) {
      final granted = await NotificationService().requestPermission();
      await _refreshOsPermission();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.notif_permissionDenied),
            action: SnackBarAction(
              label: l10n.notif_openSystemSettings,
              onPressed: _openSystemSettings,
            ),
          ),
        );
        return;
      }
    }
    await provider.setEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final showOsBanner =
        !_checkingPermission && _osPermissionGranted == false;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_notifications),
        centerTitle: true,
      ),
      body: Consumer<NotificationProvider>(
        builder: (context, provider, _) {
          return ListView(
            children: [
              if (showOsBanner) ...[
                _OsPermissionBanner(
                  title: l10n.notif_osPermissionOffTitle,
                  body: l10n.notif_osPermissionOffBody,
                  actionLabel: l10n.notif_openSystemSettings,
                  onOpenSettings: _openSystemSettings,
                ),
                const SizedBox(height: 8),
              ] else
                const SizedBox(height: 16),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active),
                title: Text(l10n.notif_enableAll),
                subtitle: Text(
                  showOsBanner
                      ? l10n.notif_osPermissionOffBody
                      : l10n.notif_enableAllSub,
                ),
                value: provider.enabled,
                onChanged: (value) => _onEnableChanged(provider, value),
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.volume_up),
                title: Text(l10n.notif_sound),
                subtitle: Text(l10n.notif_soundSub),
                value: provider.soundEnabled,
                onChanged: provider.enabled && !showOsBanner
                    ? (value) => provider.setSoundEnabled(value)
                    : null,
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.visibility),
                title: Text(l10n.notif_showPreview),
                subtitle: Text(l10n.notif_showPreviewSub),
                value: provider.showPreview,
                onChanged: provider.enabled && !showOsBanner
                    ? (value) => provider.setShowPreview(value)
                    : null,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _OsPermissionBanner extends StatelessWidget {
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onOpenSettings;

  const _OsPermissionBanner({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.notifications_off_outlined,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onErrorContainer.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onOpenSettings,
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
