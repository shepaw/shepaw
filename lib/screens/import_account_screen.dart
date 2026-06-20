import 'package:flutter/material.dart';

import '../identity/models/identity_export_bundle.dart';
import '../identity/services/identity_export_service.dart';
import '../l10n/app_localizations.dart';

/// 离线恢复：粘贴身份导出包（无法与主设备在线配对时使用）。
class ImportAccountScreen extends StatefulWidget {
  const ImportAccountScreen({super.key});

  @override
  State<ImportAccountScreen> createState() => _ImportAccountScreenState();
}

class _ImportAccountScreenState extends State<ImportAccountScreen> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _importBundle() async {
    final l10n = AppLocalizations.of(context);
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;

    final bundle = IdentityExportBundle.tryParse(raw);
    if (bundle == null) {
      _snack(l10n.identity_importInvalid);
      return;
    }

    setState(() => _busy = true);
    try {
      await IdentityExportService.instance.importBundle(bundle);
      if (!mounted) return;
      _snack(l10n.identity_importSuccess);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _snack(l10n.identity_importFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identity_importOfflineTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.identity_importOfflineHint),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 8,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: l10n.identity_importPasteHint,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _importBundle,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l10n.identity_importAction),
            ),
          ],
        ),
      ),
    );
  }
}
