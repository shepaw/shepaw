import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/models/device_role.dart';
import '../identity/services/account_identity_service.dart';
import '../identity/services/account_session_service.dart';
import '../identity/services/spirit_pet_identity_service.dart';
import '../identity/services/user_identity_service.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import 'join_account_peer_screen.dart';
import 'import_account_screen.dart';

/// 设备登录账号：创建新账号 / 加入已有账号 / 继续进入应用。
///
/// 一个账号固定对应一只灵宠；账号 ID（Ed25519 指纹）全局唯一。
class AccountGateScreen extends StatefulWidget {
  const AccountGateScreen({super.key});

  @override
  State<AccountGateScreen> createState() => _AccountGateScreenState();
}

class _AccountGateScreenState extends State<AccountGateScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _hasAccount = false;
  String? _accountId;
  DeviceRole _createRole = DeviceRole.primary;

  @override
  void initState() {
    super.initState();
    _createRole = AccountIdentityService.defaultRoleForPlatform();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final has = await AccountSessionService.instance.hasLocalAccount();
    String? id;
    if (has && AccountIdentityService.instance.isInitialized) {
      try {
        final user = await AccountIdentityService.instance.userIdentity();
        id = user.fingerprintHex;
      } catch (_) {}
    } else if (has) {
      try {
        await AccountIdentityService.instance.ensureInitialized();
        final user = await AccountIdentityService.instance.userIdentity();
        id = user.fingerprintHex;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _hasAccount = has;
      _accountId = id;
      _loading = false;
    });
  }

  Future<void> _navigateAfterAccountReady() async {
    await AccountSessionService.instance.activate();
    if (!mounted) return;
    final isPasswordSet = await PasswordService().isPasswordSet();
    if (!mounted) return;
    if (isPasswordSet) {
      Navigator.of(context).pushReplacementNamed('/login');
    } else {
      Navigator.of(context).pushReplacementNamed('/setup');
    }
  }

  Future<void> _createAccount() async {
    setState(() => _busy = true);
    try {
      await AccountIdentityService.instance.createAccount(preferredRole: _createRole);
      await _navigateAfterAccountReady();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).account_gateCreateFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinViaPeer() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const JoinAccountPeerScreen()),
    );
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _importOffline() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ImportAccountScreen()),
    );
    if (ok == true && mounted) {
      AccountSessionService.instance.resetSyncState();
      await _navigateAfterAccountReady();
    }
  }

  Future<void> _continueWithAccount() async {
    setState(() => _busy = true);
    try {
      await _navigateAfterAccountReady();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchAccount() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.account_gateSwitchTitle),
        content: Text(l10n.account_gateSwitchBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.common_cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.common_confirm)),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await UserIdentityService.instance.clearKeysAndCache();
    await SpiritPetIdentityService.instance.clearKeysAndCache();
    AccountIdentityService.instance.resetInMemory();
    AccountSessionService.instance.resetSyncState();
    await _refresh();
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.account_gateTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Icon(Icons.pets, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    l10n.account_gateHeadline,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.account_gateSubtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (_hasAccount) ...[
                    _AccountIdCard(accountId: _accountId ?? '—', l10n: l10n),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _continueWithAccount,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(l10n.account_gateContinue),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _busy ? null : _switchAccount,
                      child: Text(l10n.account_gateSwitchAccount),
                    ),
                  ] else ...[
                    Text(l10n.account_gateCreateRoleHint, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    ...DeviceRole.values.map((role) => RadioListTile<DeviceRole>(
                          title: Text(_roleLabel(role, l10n)),
                          value: role,
                          groupValue: _createRole,
                          onChanged: _busy ? null : (v) => setState(() => _createRole = v!),
                        )),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _createAccount,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.account_gateCreate),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _joinViaPeer,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(l10n.account_gateJoinViaPeer),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _importOffline,
                      child: Text(l10n.account_gateOfflineImport),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _AccountIdCard extends StatelessWidget {
  final String accountId;
  final AppLocalizations l10n;

  const _AccountIdCard({required this.accountId, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.account_gateAccountId, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              accountId,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: accountId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.account_gateIdCopied)),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(l10n.common_copy),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
