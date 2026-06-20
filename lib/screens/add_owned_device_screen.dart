import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/services/identity_export_service.dart';
import '../l10n/app_localizations.dart';
import '../peer/screens/peer_qr_display_screen.dart';

/// 主存储设备：展示 P2P 配对码，供新设备扫码配对并加入同一账号。
class AddOwnedDeviceScreen extends StatefulWidget {
  const AddOwnedDeviceScreen({super.key});

  @override
  State<AddOwnedDeviceScreen> createState() => _AddOwnedDeviceScreenState();
}

class _AddOwnedDeviceScreenState extends State<AddOwnedDeviceScreen> {
  bool _exporting = false;

  Future<void> _copyOfflineExport() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _exporting = true);
    try {
      final bundle = await IdentityExportService.instance.exportBundle();
      await Clipboard.setData(ClipboardData(text: bundle.toPayloadJson()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.identity_exportCopied)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identity_addDeviceTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.identity_addDevicePeerHint, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          const PeerQrDisplayScreen(),
          const Divider(height: 32),
          Text(l10n.identity_importOfflineTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(l10n.identity_importOfflineHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _exporting ? null : _copyOfflineExport,
            icon: _exporting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.copy),
            label: Text(l10n.identity_copyExport),
          ),
        ],
      ),
    );
  }
}
