import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';
import 'privacy_policy_screen.dart';

/// 首次密码设置页面
class PasswordSetupScreen extends StatefulWidget {
  const PasswordSetupScreen({Key? key}) : super(key: key);

  @override
  State<PasswordSetupScreen> createState() => _PasswordSetupScreenState();
}

class _PasswordSetupScreenState extends State<PasswordSetupScreen> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _passwordService = PasswordService();
  
  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;
  bool _isLoading = false;
  bool _termsAccepted = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// 验证密码强度
  String? _validatePassword(String password, AppLocalizations l10n) {
    if (password.isEmpty) {
      return l10n.passwordSetup_emptyPassword;
    }
    if (password.length < 6) {
      return l10n.passwordSetup_tooShort;
    }
    if (password.length > 20) {
      return l10n.passwordSetup_tooLong;
    }
    // 检查是否包含字母和数字
    if (!password.contains(RegExp(r'[a-zA-Z]')) ||
        !password.contains(RegExp(r'[0-9]'))) {
      return l10n.passwordSetup_needAlphaNum;
    }
    return null;
  }

  /// 提交密码设置
  Future<void> _submitPassword() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _errorMessage = '';
    });

    // 检查是否勾选服务条款
    if (!_termsAccepted) {
      setState(() {
        _errorMessage = l10n.passwordSetup_termsNotAccepted;
      });
      return;
    }

    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // 验证密码
    final validationError = _validatePassword(password, l10n);
    if (validationError != null) {
      setState(() {
        _errorMessage = validationError;
      });
      return;
    }

    // 检查两次密码是否一致
    if (password != confirmPassword) {
      setState(() {
        _errorMessage = l10n.passwordSetup_mismatch;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final success = await _passwordService.setPassword(password);

      if (success) {
        if (mounted) {
          // 密码设置成功，跳转到登录页面
          Navigator.of(context).pushReplacementNamed('/login');
        }
      } else {
        setState(() {
          _errorMessage = l10n.passwordSetup_setFailed;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = l10n.passwordSetup_errorOccurred('$e');
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
              const SizedBox(height: 60),

              // Logo 和标题
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/images/shepaw_icon.png',
                  width: 80,
                  height: 80,
                ),
              ),
              const SizedBox(height: 24),

              Text(
                l10n.passwordSetup_title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              Text(
                l10n.passwordSetup_subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),

              // 密码输入框
              TextField(
                controller: _passwordController,
                obscureText: !_isPasswordVisible,
                decoration: InputDecoration(
                  labelText: l10n.passwordSetup_password,
                  hintText: l10n.passwordSetup_passwordHint,
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
              const SizedBox(height: 16),

              // 确认密码输入框
              TextField(
                controller: _confirmPasswordController,
                obscureText: !_isConfirmPasswordVisible,
                decoration: InputDecoration(
                  labelText: l10n.passwordSetup_confirmPassword,
                  hintText: l10n.passwordSetup_confirmPasswordHint,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isConfirmPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _isConfirmPasswordVisible = !_isConfirmPasswordVisible;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 服务条款和隐私政策勾选
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _termsAccepted,
                      onChanged: (value) {
                        setState(() {
                          _termsAccepted = value ?? false;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[700],
                        ),
                        children: [
                          TextSpan(text: '${l10n.passwordSetup_agreePrefix} '),
                          TextSpan(
                            text: l10n.settings_termsOfService,
                            style: TextStyle(
                              color: Theme.of(context).primaryColor,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const PrivacyPolicyScreen(showTerms: true),
                                  ),
                                );
                              },
                          ),
                          TextSpan(text: ' ${l10n.passwordSetup_and} '),
                          TextSpan(
                            text: l10n.settings_privacyPolicy,
                            style: TextStyle(
                              color: Theme.of(context).primaryColor,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const PrivacyPolicyScreen(showTerms: false),
                                  ),
                                );
                              },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
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
                  child: Text(
                    _errorMessage,
                    style: TextStyle(color: Colors.red[700]),
                    textAlign: TextAlign.center,
                  ),
                ),

              if (_errorMessage.isNotEmpty)
                const SizedBox(height: 24),

              // 提交按钮
              ElevatedButton(
                onPressed: _isLoading ? null : _submitPassword,
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
                      l10n.passwordSetup_submit,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
              ),
              const SizedBox(height: 24),

              // 密码要求提示
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.passwordSetup_requirementsTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildRequirement(l10n.passwordSetup_reqLength),
                    _buildRequirement(l10n.passwordSetup_reqAlphaNum),
                    _buildRequirement(l10n.passwordSetup_reqSpecialChars),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRequirement(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: Colors.blue[700]),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: Colors.blue[700])),
        ],
      ),
    );
  }
}
