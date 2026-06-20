import 'dart:async';

import 'package:flutter/material.dart';

import '../identity/models/device_role.dart';
import '../identity/services/account_join_service.dart';
import '../identity/services/account_session_service.dart';
import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_manual_input_screen.dart';
import '../peer/screens/peer_qr_scanner_screen.dart';
import '../services/password_service.dart';

/// 新设备：扫描 Primary 的 P2P 配对码，经加密通道加入已有账号。
class JoinAccountPeerScreen extends StatefulWidget {
  const JoinAccountPeerScreen({super.key});

  @override
  State<JoinAccountPeerScreen> createState() => _JoinAccountPeerScreenState();
}

class _JoinAccountPeerScreenState extends State<JoinAccountPeerScreen> {
  bool _busy = false;
  String? _status;
  DeviceRole _joinRole = DeviceRole.app;

  @override
  void initState() {
    super.initState();
    AccountJoinService.instance.start();
  }

  Future<void> _navigateAfterJoin() async {
    AccountSessionService.instance.resetSyncState();
    await AccountSessionService.instance.activate();
    if (!mounted) return;
    final isPasswordSet = await PasswordService().isPasswordSet();
    if (!mounted) return;
    if (isPasswordSet) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    } else {
      Navigator.of(context).pushNamedAndRemoveUntil('/setup', (_) => false);
    }
  }

  Future<void> _afterPaired(PairedPeer peer) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _status = l10n.account_joinWaitingApproval;
    });

    try {
      await AccountJoinService.instance.joinViaPeer(
        peer: peer,
        preferredRole: _joinRole,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.account_joinSuccess)),
      );
      await _navigateAfterJoin();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.account_joinFailed(e.toString()))),
      );
    }
  }

  Future<void> _scanQr() async {
    if (_busy) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PeerQrScannerScreen(
          onPaired: (peer) {
            Navigator.pop(context);
            unawaited(_afterPaired(peer));
          },
        ),
      ),
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
            unawaited(_afterPaired(peer));
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

    return Scaffold(
      appBar: AppBar(title: Text(l10n.account_joinTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(l10n.account_joinHint, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            Text(l10n.account_gateCreateRoleHint, style: Theme.of(context).textTheme.bodySmall),
            ...DeviceRole.values.map((role) => RadioListTile<DeviceRole>(
                  title: Text(_roleLabel(role, l10n)),
                  value: role,
                  groupValue: _joinRole,
                  onChanged: _busy ? null : (v) => setState(() => _joinRole = v!),
                )),
            const SizedBox(height: 16),
            if (_status != null) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_status!, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: _busy ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l10n.account_joinScanPeer),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _manualInput,
                icon: const Icon(Icons.keyboard),
                label: Text(l10n.account_joinManualPeer),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
