import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/password_service.dart';

/// 密码修改页面
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({Key? key}) : super(key: key);

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _passwordService = PasswordService();
  
  bool _isOldPasswordVisible = false;
  bool _isNewPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;
  bool _isLoading = false;
  String _errorMessage = '';
  String _successMessage = '';

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    await _passwordService.init();
  }

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// 验证密码强度
  String? _validatePassword(String password) {
    final l10n = AppLocalizations.of(context);
    if (password.isEmpty) {
      return l10n.passwordSetup_emptyPassword;
    }
    if (password.length < 6) {
      return l10n.passwordSetup_tooShort;
    }
    if (password.length > 20) {
      return l10n.passwordSetup_tooLong;
    }
    if (!password.contains(RegExp(r'[a-zA-Z]')) ||
        !password.contains(RegExp(r'[0-9]'))) {
      return l10n.passwordSetup_needAlphaNum;
    }
    return null;
  }

  /// 提交密码修改
  Future<void> _submitChange() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _errorMessage = '';
      _successMessage = '';
    });

    final oldPassword = _oldPasswordController.text;
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // 验证旧密码
    if (oldPassword.isEmpty) {
      setState(() {
        _errorMessage = l10n.changePassword_emptyCurrentPassword;
      });
      return;
    }

    // 验证新密码
    final validationError = _validatePassword(newPassword);
    if (validationError != null) {
      setState(() {
        _errorMessage = validationError;
      });
      return;
    }

    // 检查新密码是否与旧密码相同
    if (oldPassword == newPassword) {
      setState(() {
        _errorMessage = l10n.changePassword_sameAsOld;
      });
      return;
    }

    // 检查两次新密码是否一致
    if (newPassword != confirmPassword) {
      setState(() {
        _errorMessage = l10n.changePassword_newMismatch;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final success = await _passwordService.changePassword(
        oldPassword,
        newPassword,
      );

      if (success) {
        setState(() {
          _successMessage = l10n.changePassword_success;
        });

        // 清空输入框
        _oldPasswordController.clear();
        _newPasswordController.clear();
        _confirmPasswordController.clear();

        // 2秒后返回
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.pop(context);
          }
        });
      } else {
        setState(() {
          _errorMessage = l10n.changePassword_wrongCurrent;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = l10n.changePassword_failed('$e');
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
      appBar: AppBar(
        title: Text(l10n.changePassword_title),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),

              // 当前密码输入框
              TextField(
                controller: _oldPasswordController,
                obscureText: !_isOldPasswordVisible,
                decoration: InputDecoration(
                  labelText: l10n.changePassword_currentPassword,
                  hintText: l10n.changePassword_currentPasswordHint,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isOldPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _isOldPasswordVisible = !_isOldPasswordVisible;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 新密码输入框
              TextField(
                controller: _newPasswordController,
                obscureText: !_isNewPasswordVisible,
                decoration: InputDecoration(
                  labelText: l10n.changePassword_newPassword,
                  hintText: l10n.changePassword_newPasswordHint,
                  prefixIcon: const Icon(Icons.lock_reset),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isNewPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _isNewPasswordVisible = !_isNewPasswordVisible;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 确认新密码输入框
              TextField(
                controller: _confirmPasswordController,
                obscureText: !_isConfirmPasswordVisible,
                decoration: InputDecoration(
                  labelText: l10n.changePassword_confirmNewPassword,
                  hintText: l10n.changePassword_confirmNewPasswordHint,
                  prefixIcon: const Icon(Icons.lock_reset),
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

              // 成功提示
              if (_successMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _successMessage,
                          style: TextStyle(color: Colors.green[700]),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_errorMessage.isNotEmpty || _successMessage.isNotEmpty)
                const SizedBox(height: 24),

              // 提交按钮
              ElevatedButton(
                onPressed: _isLoading ? null : _submitChange,
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
                      l10n.changePassword_submit,
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
                      l10n.changePassword_requirementsTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildRequirement(l10n.changePassword_reqLength),
                    _buildRequirement(l10n.changePassword_reqAlphaNum),
                    _buildRequirement(l10n.changePassword_reqDifferent),
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
