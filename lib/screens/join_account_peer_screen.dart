import 'package:flutter/material.dart';

import '../identity/models/device_role.dart';
import '../identity/services/account_join_service.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_manual_input_screen.dart';
import 'qr_login_flow.dart';

/// 扫描主存储设备二维码，加入同一账号并建立多设备关联。
class JoinAccountPeerScreen extends StatefulWidget {
  /// 从登录页进入的扫码登录模式（默认应用设备角色，简化 UI）。
  final bool qrLoginMode;

  const JoinAccountPeerScreen({super.key, this.qrLoginMode = false});

  @override
  State<JoinAccountPeerScreen> createState() => _JoinAccountPeerScreenState();
}

class _JoinAccountPeerScreenState extends State<JoinAccountPeerScreen> {
  bool _busy = false;
  DeviceRole _joinRole = DeviceRole.app;

  @override
  void initState() {
    super.initState();
    if (widget.qrLoginMode) {
      _joinRole = DeviceRole.app;
    }
    AccountJoinService.instance.start();
  }

  Future<void> _afterPaired(PairedPeer peer) async {
    setState(() => _busy = true);
    await QrLoginFlow.joinWithPeer(
      context,
      peer: peer,
      preferredRole: _joinRole,
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _scanQr() async {
    if (_busy) return;
    await QrLoginFlow.scanAndJoin(
      context,
      preferredRole: _joinRole,
    );
  }

  Future<void> _manualInput() async {
    if (_busy) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PeerManualInputScreen(
          onPaired: (peer) {
            Navigator.pop(context);
            _afterPaired(peer);
          },
        ),
      ),
    );
  }

  String _roleLabel(DeviceRole role, AppLocalizations l10n) {
    switch (role) {
      case DeviceRole.primary:
        return l10n.identity_rolePrimary;
      case DeviceRole.backup:
        return l10n.identity_roleBackup;
      case DeviceRole.app:
        return l10n.identity_roleApp;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isQrLogin = widget.qrLoginMode;

    return Scaffold(
      appBar: AppBar(title: Text(isQrLogin ? l10n.qrLogin_scanTitle : l10n.account_joinTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              isQrLogin ? l10n.qrLogin_scanHeadline : l10n.account_joinHint,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (!isQrLogin) ...[
              Text(l10n.account_gateCreateRoleHint, style: Theme.of(context).textTheme.bodySmall),
              ...DeviceRole.values.map((role) => RadioListTile<DeviceRole>(
                    title: Text(_roleLabel(role, l10n)),
                    subtitle: Text(_roleDescription(role, l10n), style: Theme.of(context).textTheme.bodySmall),
                    value: role,
                    groupValue: _joinRole,
                    onChanged: _busy ? null : (v) => setState(() => _joinRole = v!),
                  )),
              const SizedBox(height: 16),
            ] else ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phone_android),
                  title: Text(l10n.identity_roleApp),
                  subtitle: Text(l10n.qrLogin_appRoleHint),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              FilledButton.icon(
                onPressed: _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(isQrLogin ? l10n.qrLogin_scanButton : l10n.account_joinScanPeer),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _manualInput,
                icon: const Icon(Icons.keyboard),
                label: Text(l10n.account_joinManualPeer),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _roleDescription(DeviceRole role, AppLocalizations l10n) {
    switch (role) {
      case DeviceRole.primary:
        return l10n.qrLogin_rolePrimaryDesc;
      case DeviceRole.backup:
        return l10n.qrLogin_roleBackupDesc;
      case DeviceRole.app:
        return l10n.qrLogin_roleAppDesc;
    }
  }
}
