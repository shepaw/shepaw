import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/cli_host.dart';
import '../services/cli_pouch.dart';
import '../services/logger_service.dart';
import '../services/noise_identity.dart';
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';

/// 桌面首次进入：这台电脑还没设过主机密码，创建第一只储物袋。
///
/// 解锁（选袋子 + 输密码）已经搬到 `UnlockScreen`，`/pouch-unlock` 现在转到那里。
/// TODO(L4)：本页会被 `CreatePasswordScreen` 取代，届时整个文件删掉。
class PouchGateScreen extends StatefulWidget {
  const PouchGateScreen({super.key, required this.initializing});

  /// 还没有主机密码。创建第一只储物袋。
  final bool initializing;

  @override
  State<PouchGateScreen> createState() => _PouchGateScreenState();
}

class _PouchGateScreenState extends State<PouchGateScreen> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

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
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    final name = _name.text.trim();
    final password = _password.text;
    if (name.isEmpty) {
      setState(() => _error = l10n.pouch_nameRequired);
      return;
    }
    if (password.length < 6) {
      setState(() => _error = l10n.passwordSetup_tooShort);
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = l10n.passwordSetup_mismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final binary = await CliHost.resolveBinary();
      if (binary == null) throw StateError('没有找到 shepaw');
      final fingerprint = (await NoiseIdentity.loadOrCreate()).fingerprintHex;
      final grant = await CliPouch.init(
        binary: binary,
        name: name,
        password: password,
        fingerprint: fingerprint,
      );
      await CliPouch.openLocal(grant);
      if (!mounted) return;
      // openLocal 已经写好登录态并连上本机主机，不必再 probe / attach 一遍。
      Navigator.of(context).pushReplacementNamed('/home');
    } on StateError catch (error) {
      if (mounted) {
        setState(() => _error = switch (error.message) {
              '没有这只袋子' => l10n.pouchGate_missing,
              '有多只同名袋子' => l10n.pouchGate_ambiguous,
              '没有找到 shepaw' => l10n.gate_errorGeneric,
              _ => l10n.gate_errorGeneric,
            });
        LoggerService().warning(
          'pouch init failed: ${error.message}',
          tag: 'PouchGate',
        );
      }
    } catch (error) {
      LoggerService()
          .error('pouch gate failed', tag: 'PouchGate', error: error);
      if (mounted) setState(() => _error = l10n.gate_errorGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pouchGate_initTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.pouchGate_initBody),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: l10n.pouchGate_name,
              hintText: l10n.pouchGate_nameHint,
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.passwordSetup_password,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.passwordSetup_confirmPassword,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.pouchGate_create),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () =>
                    Navigator.of(context).pushReplacementNamed('/host-setup'),
            child: Text(l10n.pouchGate_remote),
          ),
        ],
      ),
    );
  }
}
