import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/biometric_service.dart';
import '../../services/cli_host.dart';
import '../../services/cli_pouch.dart';
import '../../services/noise_identity.dart';
import '../../services/logger_service.dart';
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';
import 'gate_navigator.dart';
import 'widgets/gate_widgets.dart';

/// 忘记主机密码。
///
/// 本机主机：先过一次系统认证（Touch ID / 设备密码），再重设，然后自动用新密码
/// 登录一次 —— 重设会吊销所有设备的凭据，不登一次这台电脑自己也被踢在外面。
/// 远端主机：只能在那台电脑上重设，这里给命令；另外提示可以用加入码绕过去。
Future<void> showForgotPassword(
  BuildContext context, {
  required bool localHost,
  required String hostPeerId,
}) async {
  final l10n = AppLocalizations.of(context);
  if (!localHost) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.unlock_forgot),
        content: Text(l10n.forgot_remoteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _ResetDialog(hostPeerId: hostPeerId, l10n: l10n),
  );
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({required this.hostPeerId, required this.l10n});

  final String hostPeerId;
  final AppLocalizations l10n;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = widget.l10n;
    if (_busy) return;
    final password = _password.text;
    if (password.length < 6) {
      setState(() => _error = l10n.password_minLength);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // 能改主机密码的人本来就能开终端，这里只是不让用户去敲命令；
      // 系统认证挡住的是「路过的人」。
      final ok = await BiometricService().authenticate(reason: 'verify');
      if (!ok) {
        if (mounted) {
          setState(() {
            _error = l10n.gate_errorGeneric;
            _busy = false;
          });
        }
        return;
      }
      await CliHost.setHostPassword(password);
      // 重设吊销了所有凭据，这台电脑也要重新登录一次，不然自己也被踢在外面。
      final session = await PouchSessionStore.readActive();
      final binary = await CliHost.resolveBinary();
      if (session != null && binary != null) {
        final grant = await CliPouch.login(
          binary: binary,
          name: session.pouchName,
          password: password,
          fingerprint: (await NoiseIdentity.loadOrCreate()).fingerprintHex,
          savedId: session.pouchId,
        );
        await CliPouch.openLocal(grant);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      unawaited(GateNavigator.go(context));
    } catch (error) {
      LoggerService().error('password reset failed',
          tag: 'ForgotPassword', error: error);
      if (mounted) {
        setState(() {
          _error = l10n.gate_errorGeneric;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      title: Text(l10n.forgot_localTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.forgot_localBody),
          const SizedBox(height: 12),
          PasswordField(
            controller: _password,
            enabled: !_busy,
            onSubmitted: (_) => _submit(),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.common_confirm),
        ),
      ],
    );
  }
}
