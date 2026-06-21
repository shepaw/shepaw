import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../identity/models/local_account_entry.dart';
import '../identity/services/account_identity_service.dart';
import '../identity/services/account_join_service.dart';
import '../identity/services/account_session_service.dart';
import '../identity/services/local_account_registry.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import '../services/biometric_service.dart';
import '../theme/app_theme.dart';
import 'qr_login_display_screen.dart';

/// 登录时选择本机已保存的账号。
const _createNewAccountValue = '__create_new__';

/// 登录页面
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _passwordController = TextEditingController();
  final _passwordService = PasswordService();
  final _biometricService = BiometricService();

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _loadingAccounts = true;
  String _errorMessage = '';
  int _failedAttempts = 0;
  bool _biometricAvailable = false;
  List<LocalAccountEntry> _accounts = [];
  String? _selectedAccountId;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    await _loadAccounts();
    await _checkBiometric();
  }

  Future<void> _loadAccounts() async {
    final accounts = await LocalAccountRegistry.instance.listAccounts();
    final activeId = await LocalAccountRegistry.instance.getActiveAccountId();
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _selectedAccountId = activeId ?? (accounts.isNotEmpty ? accounts.first.accountId : null);
      _loadingAccounts = false;
    });
    if (_selectedAccountId != null) {
      await AccountSessionService.instance.switchToAccount(_selectedAccountId!);
    }
  }

  Future<void> _onAccountChanged(String? accountId) async {
    if (accountId == null) return;
    if (accountId == _createNewAccountValue) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/account-gate');
      return;
    }
    if (accountId == _selectedAccountId) return;

    setState(() {
      _selectedAccountId = accountId;
      _errorMessage = '';
      _failedAttempts = 0;
      _passwordController.clear();
      _isLoading = true;
    });

    await AccountSessionService.instance.switchToAccount(accountId);
    if (!mounted) return;
    setState(() => _isLoading = false);
    await _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    try {
      final enabled = await _biometricService.isBiometricEnabled();
      if (!enabled) {
        if (mounted) setState(() => _biometricAvailable = false);
        return;
      }

      final supported = await _biometricService.isDeviceSupported();
      if (!supported) {
        if (mounted) setState(() => _biometricAvailable = false);
        return;
      }

      if (mounted) {
        setState(() => _biometricAvailable = true);
        _authenticateWithBiometric();
      }
    } catch (_) {
      if (mounted) setState(() => _biometricAvailable = false);
    }
  }

  Future<void> _authenticateWithBiometric() async {
    final l10n = AppLocalizations.of(context);
    final success = await _biometricService.authenticate(
      reason: l10n.login_biometricPrompt,
    );
    if (success && mounted) {
      await AccountSessionService.instance.activate();
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  /// 提交登录
  Future<void> _submitLogin() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _errorMessage = '';
    });

    final password = _passwordController.text;

    if (password.isEmpty) {
      setState(() {
        _errorMessage = l10n.login_emptyPassword;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final success = await _passwordService.verifyPassword(password);

      if (success) {
        if (mounted) {
          await AccountSessionService.instance.activate();
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed('/home');
        }
      } else {
        setState(() {
          _failedAttempts++;
          if (_failedAttempts >= 3) {
            _errorMessage = l10n.login_tooManyAttempts;
          } else {
            _errorMessage = l10n.login_wrongPassword(_failedAttempts);
          }
        });

        _passwordController.clear();
      }
    } catch (e) {
      setState(() {
        _errorMessage = l10n.login_failed('$e');
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _showQrLoginForMobile() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _errorMessage = '');

    setState(() => _isLoading = true);
    try {
      if (_selectedAccountId != null) {
        await AccountSessionService.instance.switchToAccount(_selectedAccountId!);
      }
      await AccountIdentityService.instance.ensureInitialized();
      AccountJoinService.instance.start();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const QrLoginDisplayScreen()),
      );
    } catch (e) {
      setState(() => _errorMessage = l10n.qrLogin_displayFailed('$e'));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (_loadingAccounts) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_accounts.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/account-gate');
        }
      });
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),

              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/images/shepaw_icon.png',
                  width: 100,
                  height: 100,
                ),
              ),
              const SizedBox(height: 32),

              Text(
                l10n.login_title,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              Text(
                l10n.login_subtitle,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              DropdownButtonFormField<String>(
                value: _selectedAccountId,
                decoration: InputDecoration(
                  labelText: l10n.login_selectAccount,
                  prefixIcon: const Icon(Icons.account_circle_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                items: [
                  ..._accounts.map((account) => DropdownMenuItem(
                        value: account.accountId,
                        child: Text(
                          account.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                  DropdownMenuItem(
                    value: _createNewAccountValue,
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 18, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(l10n.login_createNewAccount),
                      ],
                    ),
                  ),
                ],
                onChanged: _isLoading ? null : _onAccountChanged,
              ),
              const SizedBox(height: 24),

              TextField(
                controller: _passwordController,
                obscureText: !_isPasswordVisible,
                autofocus: !_biometricAvailable,
                onSubmitted: (_) => _submitLogin(),
                decoration: InputDecoration(
                  labelText: l10n.login_password,
                  hintText: l10n.login_passwordHint,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _isPasswordVisible = !_isPasswordVisible;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              if (_errorMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red[700]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage,
                          style: TextStyle(color: Colors.red[700]),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_errorMessage.isNotEmpty)
                const SizedBox(height: 24),

              ElevatedButton(
                onPressed: (_isLoading || _failedAttempts >= 3)
                  ? null
                  : _submitLogin,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      l10n.login_button,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
              ),
              const SizedBox(height: 12),

              if (!_isMobile)
                OutlinedButton.icon(
                  onPressed: _isLoading ? null : _showQrLoginForMobile,
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.qrLogin_displayButton),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              if (!_isMobile) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.qrLogin_displayNoPasswordHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (!_isMobile) const SizedBox(height: 16),

              if (_biometricAvailable)
                Column(
                  children: [
                    IconButton(
                      iconSize: 48,
                      icon: const Icon(Icons.fingerprint),
                      color: Theme.of(context).primaryColor,
                      tooltip: l10n.login_useBiometric,
                      onPressed: _authenticateWithBiometric,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.login_useBiometric,
                      style: TextStyle(
                        color: Theme.of(context).primaryColor,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),

              TextButton(
                onPressed: () {
                  _showResetPasswordDialog();
                },
                child: Text(l10n.login_forgotPassword),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showResetPasswordDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange[700]),
            const SizedBox(width: 8),
            Text(l10n.login_resetPasswordTitle),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.login_resetPasswordContent),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primaryLight),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: AppColors.primaryDark, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.login_resetPasswordVaultHint,
                      style: const TextStyle(color: AppColors.primaryDark, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              if (!mounted) return;

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => AlertDialog(
                  content: Row(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(width: 16),
                      Expanded(child: Text(l10n.login_resetPasswordBackingUp)),
                    ],
                  ),
                ),
              );

              try {
                await _passwordService.resetPassword();
              } finally {
                if (mounted) Navigator.of(context, rootNavigator: true).pop();
              }

              if (mounted) {
                Navigator.of(context).pushReplacementNamed('/setup');
              }
            },
            child: Text(
              l10n.login_confirmReset,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}
