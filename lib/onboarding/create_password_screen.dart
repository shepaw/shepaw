import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/cli_host.dart';
import '../../services/cli_pouch.dart';
import '../../services/noise_identity.dart';
import '../../services/logger_service.dart';
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';
import 'gate_navigator.dart';
import 'widgets/gate_widgets.dart';

/// 桌面首次：这台主机还没设过密码。
///
/// 一个密码框，可以显示/隐藏。以前要输两遍；显示切换比二次输入更能防输错，
/// 而且本机忘了可以重设。
class CreatePasswordScreen extends StatefulWidget {
  const CreatePasswordScreen({super.key});

  @override
  State<CreatePasswordScreen> createState() => _CreatePasswordScreenState();
}

class _CreatePasswordScreenState extends State<CreatePasswordScreen> {
  final _nickname = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    PouchLoginKeeper.instance.retainGate();
  }

  @override
  void dispose() {
    PouchLoginKeeper.instance.releaseGate();
    _nickname.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    final nickname = _nickname.text.trim();
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
      final binary = await CliHost.resolveBinary();
      if (binary == null) throw StateError('没有找到 shepaw');
      final name = nickname.isEmpty
          ? l10n.pouch_defaultName
          : l10n.pouch_namedBag(nickname);
      final grant = await CliPouch.init(
        binary: binary,
        name: name,
        password: password,
        fingerprint: (await NoiseIdentity.loadOrCreate()).fingerprintHex,
      );
      await CliPouch.openLocal(grant);
      if (!mounted) return;
      await Navigator.of(context).pushReplacementNamed('/setup-done');
    } catch (error) {
      LoggerService().error('pouch init failed', tag: 'CreatePassword', error: error);
      if (mounted) {
        setState(() {
          _error = _map(error, l10n);
          _busy = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  String _map(Object error, AppLocalizations l10n) {
    final text = error.toString();
    if (text.contains('已经初始化过了')) {
      // 别处刚设过：不用再设，回到 Gate 重新判断一次。
      unawaited(GateNavigator.go(context));
      return '';
    }
    if (text.contains('没有找到 shepaw')) return l10n.hostInstall_installFailed;
    return l10n.gate_errorGeneric;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final nickname = _nickname.text.trim();
    return PopScope(
      canPop: false,
      child: GateScaffold(
        avatar: CircleAvatar(
          radius: 28,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(Icons.shield_outlined,
              color: Theme.of(context).colorScheme.onPrimaryContainer),
        ),
        title: l10n.createPassword_title,
        subtitle: l10n.createPassword_body,
        body: [
          TextField(
            controller: _nickname,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: l10n.createPassword_nickname,
              hintText: l10n.pouchGate_nameHint,
            ),
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
          ),
          if (nickname.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              l10n.createPassword_nicknameHint(l10n.pouch_namedBag(nickname)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          PasswordField(
            controller: _password,
            enabled: !_busy,
            onSubmitted: (_) => _submit(),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              _busy ? l10n.unlock_entering : l10n.createPassword_submit,
            ),
          ),
        ],
      ),
    );
  }
}
