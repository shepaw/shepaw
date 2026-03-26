import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import '../services/biometric_service.dart';

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
  String _errorMessage = '';
  int _failedAttempts = 0;
  bool _biometricAvailable = false;

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
    final l10n = AppLocalizations.of(context);
    final success = await _biometricService.authenticate(
      reason: l10n.login_biometricPrompt,
    );
    if (success && mounted) {
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
        // 登录成功，跳转到主页
        if (mounted) {
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
    return Scaffold(
      backgroundColor: Colors.white,
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
                  color: Colors.grey[600],
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

              // 登录按钮
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
        title: Text(l10n.login_resetPasswordTitle),
        content: Text(
          l10n.login_resetPasswordContent,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              await _passwordService.resetPassword();
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
