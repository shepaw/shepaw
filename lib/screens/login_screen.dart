import 'dart:async';

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../services/password_service.dart';
import '../services/biometric_service.dart';
import '../services/desktop_window_auto_size.dart';
import '../theme/app_theme.dart';

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

  static const int _lockoutSeconds = 30;

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  String _errorMessage = '';
  int _failedAttempts = 0;
  int _lockSecondsLeft = 0;
  Timer? _lockTimer;
  bool _biometricAvailable = false;

  bool get _isLocked => _lockSecondsLeft > 0;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    await _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    try {
      final enabled = await _biometricService.isBiometricEnabled();
      if (!enabled) return;

      final supported = await _biometricService.isDeviceSupported();
      if (!supported) return;

      if (mounted) {
        setState(() {
          _biometricAvailable = true;
        });
        // Auto-trigger biometric authentication
        _authenticateWithBiometric();
      }
    } catch (_) {
      // Biometric not available, fall back to password
    }
  }

  Future<void> _authenticateWithBiometric() async {
    if (_isLocked) return;
    final l10n = AppLocalizations.of(context);
    final success = await _biometricService.authenticate(
      reason: l10n.login_biometricPrompt,
    );
    if (success && mounted) {
      LoggerService().info('Biometric login OK, navigating to /home', tag: 'Login');
      await _goHome();
    }
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _passwordController.dispose();
    super.dispose();
  }

  void _beginLockout() {
    _lockSecondsLeft = _lockoutSeconds;
    _errorMessage = AppLocalizations.of(context).login_retryIn(_lockSecondsLeft);
    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _lockSecondsLeft -= 1;
        if (_lockSecondsLeft <= 0) {
          timer.cancel();
          _lockTimer = null;
          _failedAttempts = 0;
          _errorMessage = '';
        } else {
          _errorMessage =
              AppLocalizations.of(context).login_retryIn(_lockSecondsLeft);
        }
      });
    });
  }

  /// 系统认证面板关掉后再进主页，避免 macOS 把主窗口当成已关闭而退出。
  Future<void> _goHome() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await DesktopWindowAutoSize.bringToFront();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/home');
  }

  /// 提交登录
  Future<void> _submitLogin() async {
    if (_isLocked || _isLoading) return;
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
        // 登录成功，跳转到主页
        if (mounted) {
          LoggerService().info('Password verified, navigating to /home', tag: 'Login');
          await _goHome();
        }
      } else {
        setState(() {
          _failedAttempts++;
          if (_failedAttempts >= 3) {
            _beginLockout();
          } else {
            _errorMessage = l10n.login_wrongPassword(_failedAttempts);
          }
        });

        // 清空输入
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),

              // Logo
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
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              // 密码输入框
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

              // 错误提示
              if (_errorMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: scheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_errorMessage.isNotEmpty)
                const SizedBox(height: 24),

              // 登录按钮
              ElevatedButton(
                onPressed: (_isLoading || _isLocked)
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
              const SizedBox(height: 16),

              // 生物识别按钮
              if (_biometricAvailable)
                Column(
                  children: [
                    IconButton(
                      iconSize: 48,
                      icon: const Icon(Icons.fingerprint),
                      color: Theme.of(context).primaryColor,
                      tooltip: l10n.login_useBiometric,
                      onPressed: _isLocked ? null : _authenticateWithBiometric,
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

              // 忘记密码提示
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

  /// 显示重置密码对话框
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

              // 显示进度对话框
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (dialogContext) => AlertDialog(
                  content: Row(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(dialogContext).login_backingUp,
                        ),
                      ),
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
