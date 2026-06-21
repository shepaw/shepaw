import 'package:flutter/material.dart';

import '../identity/services/account_join_service.dart';
import '../l10n/app_localizations.dart';
import '../peer/screens/peer_qr_display_screen.dart';

/// 主存储设备展示扫码登录二维码，供移动端扫描加入同一账号。
class QrLoginDisplayScreen extends StatefulWidget {
  const QrLoginDisplayScreen({super.key});

  @override
  State<QrLoginDisplayScreen> createState() => _QrLoginDisplayScreenState();
}

class _QrLoginDisplayScreenState extends State<QrLoginDisplayScreen> {
  @override
  void initState() {
    super.initState();
    AccountJoinService.instance.start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.qrLogin_displayTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Icon(Icons.qr_code_2, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            l10n.qrLogin_displayHeadline,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.qrLogin_displayHint,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _StepRow(number: 1, text: l10n.qrLogin_stepScan),
                  _StepRow(number: 2, text: l10n.qrLogin_stepApprove),
                  _StepRow(number: 3, text: l10n.qrLogin_stepSync),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const PeerQrDisplayScreen(),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int number;
  final String text;

  const _StepRow({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text('$number', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
