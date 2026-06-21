import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/models/device_role.dart';
import '../identity/models/local_account_entry.dart';
import '../identity/services/account_identity_service.dart';
import '../identity/services/account_session_service.dart';
import '../identity/services/local_account_registry.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import 'join_account_peer_screen.dart';
import 'import_account_screen.dart';
import 'privacy_policy_screen.dart';
import 'qr_login_flow.dart';

/// 设备登录账号：选择已有账号 / 创建新账号 / 加入已有账号。
///
/// 一个账号固定对应一只灵宠；账号 ID（Ed25519 指纹）全局唯一。
/// 每个账号在本机拥有独立密码。
class AccountGateScreen extends StatefulWidget {
  const AccountGateScreen({super.key});

  @override
  State<AccountGateScreen> createState() => _AccountGateScreenState();
}

class _AccountGateScreenState extends State<AccountGateScreen> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _passwordService = PasswordService();

  bool _loading = true;
  bool _busy = false;
  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;
  bool _termsAccepted = false;
  String _createError = '';
  List<LocalAccountEntry> _accounts = [];
  String? _selectedAccountId;
  DeviceRole _createRole = DeviceRole.primary;
  bool _showCreateSection = false;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _createRole = AccountIdentityService.defaultRoleForPlatform();
    _refresh();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final accounts = await LocalAccountRegistry.instance.listAccounts();
    final activeId = await LocalAccountRegistry.instance.getActiveAccountId();
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _selectedAccountId = activeId ?? (accounts.isNotEmpty ? accounts.first.accountId : null);
      _showCreateSection = accounts.isEmpty;
      _loading = false;
    });
  }

  Future<void> _navigateAfterAccountReady() async {
    await AccountSessionService.instance.activate();
    if (!mounted) return;
    final isPasswordSet = await _passwordService.isPasswordSet();
    if (!mounted) return;
    if (isPasswordSet) {
      Navigator.of(context).pushReplacementNamed('/login');
    } else {
      Navigator.of(context).pushReplacementNamed('/setup');
    }
  }

  String? _passwordValidationMessage(PasswordValidationIssue? issue, AppLocalizations l10n) {
    switch (issue) {
      case PasswordValidationIssue.empty:
        return l10n.passwordSetup_emptyPassword;
      case PasswordValidationIssue.tooShort:
        return l10n.passwordSetup_tooShort;
      case PasswordValidationIssue.tooLong:
        return l10n.passwordSetup_tooLong;
      case PasswordValidationIssue.needAlphaNum:
        return l10n.passwordSetup_needAlphaNum;
      case null:
        return null;
    }
  }

  Future<void> _createAccount() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _createError = '');

    if (_accounts.isEmpty && !_termsAccepted) {
      setState(() => _createError = l10n.passwordSetup_termsNotAccepted);
      return;
    }

    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;
    final validationIssue = PasswordService.validateStrength(password);
    final validationMessage = _passwordValidationMessage(validationIssue, l10n);
    if (validationMessage != null) {
      setState(() => _createError = validationMessage);
      return;
    }
    if (password != confirmPassword) {
      setState(() => _createError = l10n.passwordSetup_mismatch);
      return;
    }

    setState(() => _busy = true);
    try {
      await AccountIdentityService.instance.createAccount(preferredRole: _createRole);
      await AccountSessionService.instance.activate();
      final ok = await _passwordService.setPassword(password);
      if (!ok) {
        throw StateError(l10n.passwordSetup_setFailed);
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _createError = l10n.account_gateCreateFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanQrLogin() async {
    await QrLoginFlow.scanAndJoin(context);
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _joinViaPeer() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => JoinAccountPeerScreen(qrLoginMode: _isMobile),
      ),
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
    if (_selectedAccountId == null) return;
    setState(() => _busy = true);
    try {
      await AccountSessionService.instance.switchToAccount(_selectedAccountId!);
      await _navigateAfterAccountReady();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onAccountSelected(String? accountId) async {
    if (accountId == null) return;
    setState(() => _selectedAccountId = accountId);
    await AccountSessionService.instance.switchToAccount(accountId);
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

  LocalAccountEntry? get _selectedAccount {
    if (_selectedAccountId == null) return null;
    for (final a in _accounts) {
      if (a.accountId == _selectedAccountId) return a;
    }
    return null;
  }

  Widget _buildCreatePasswordFields(AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.account_gateSetPasswordHint, style: theme.textTheme.titleSmall),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: !_isPasswordVisible,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: l10n.passwordSetup_password,
            hintText: l10n.passwordSetup_passwordHint,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmPasswordController,
          obscureText: !_isConfirmPasswordVisible,
          enabled: !_busy,
          onSubmitted: (_) => _createAccount(),
          decoration: InputDecoration(
            labelText: l10n.passwordSetup_confirmPassword,
            hintText: l10n.passwordSetup_confirmPasswordHint,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_isConfirmPasswordVisible ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _isConfirmPasswordVisible = !_isConfirmPasswordVisible),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.passwordSetup_reqLength,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (_accounts.isEmpty) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _termsAccepted,
                  onChanged: _busy ? null : (v) => setState(() => _termsAccepted = v ?? false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
                    children: [
                      TextSpan(text: '${l10n.passwordSetup_agreePrefix} '),
                      TextSpan(
                        text: l10n.settings_termsOfService,
                        style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen(showTerms: true)),
                            );
                          },
                      ),
                      TextSpan(text: ' ${l10n.passwordSetup_and} '),
                      TextSpan(
                        text: l10n.settings_privacyPolicy,
                        style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen(showTerms: false)),
                            );
                          },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_createError.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_createError, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
      ],
    );
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

                  if (_accounts.isEmpty) ...[
                    FilledButton.icon(
                      onPressed: _busy ? null : _scanQrLogin,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(l10n.qrLogin_scanButton),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.qrLogin_scanHeadline,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(l10n.account_gateOrCreate, style: theme.textTheme.bodySmall),
                        ),
                        Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],

                  if (_accounts.isNotEmpty) ...[
                    Text(l10n.login_selectAccount, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedAccountId,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.account_circle_outlined),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      items: _accounts
                          .map((account) => DropdownMenuItem(
                                value: account.accountId,
                                child: Text(account.label, overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: _busy ? null : _onAccountSelected,
                    ),
                    const SizedBox(height: 16),
                    if (_selectedAccount != null)
                      _AccountIdCard(accountId: _selectedAccount!.accountId, l10n: l10n),
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
                    const SizedBox(height: 24),
                    Divider(color: theme.colorScheme.outlineVariant),
                    const SizedBox(height: 16),
                    Text(l10n.account_gateAddAccount, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 12),
                  ],

                  if (_accounts.isEmpty || _showCreateSection) ...[
                    if (_accounts.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _showCreateSection = false;
                                    _createError = '';
                                    _passwordController.clear();
                                    _confirmPasswordController.clear();
                                  }),
                          child: Text(l10n.common_cancel),
                        ),
                      ),
                    Text(l10n.account_gateCreateRoleHint, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    ...DeviceRole.values.map((role) => RadioListTile<DeviceRole>(
                          title: Text(_roleLabel(role, l10n)),
                          value: role,
                          groupValue: _createRole,
                          onChanged: _busy ? null : (v) => setState(() => _createRole = v!),
                        )),
                    const SizedBox(height: 8),
                    _buildCreatePasswordFields(l10n, theme),
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
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _showCreateSection = true;
                                _createError = '';
                              }),
                      icon: const Icon(Icons.person_add_outlined),
                      label: Text(l10n.account_gateAddAccount),
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
