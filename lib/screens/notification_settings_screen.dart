import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/notification_provider.dart';
import '../services/notification_service.dart';

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_notifications),
        centerTitle: true,
      ),
      body: Consumer<NotificationProvider>(
        builder: (context, provider, _) {
          return ListView(
            children: [
              const SizedBox(height: 16),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active),
                title: Text(l10n.notif_enableAll),
                subtitle: Text(l10n.notif_enableAllSub),
                value: provider.enabled,
                onChanged: (value) async {
                  if (value) {
                    final granted =
                        await NotificationService().requestPermission();
                    if (!granted) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l10n.notif_permissionDenied),
                          ),
                        );
                      }
                      return;
                    }
                  }
                  await provider.setEnabled(value);
                },
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.volume_up),
                title: Text(l10n.notif_sound),
                subtitle: Text(l10n.notif_soundSub),
                value: provider.soundEnabled,
                onChanged: provider.enabled
                    ? (value) => provider.setSoundEnabled(value)
                    : null,
              ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.visibility),
                title: Text(l10n.notif_showPreview),
                subtitle: Text(l10n.notif_showPreviewSub),
                value: provider.showPreview,
                onChanged: provider.enabled
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
