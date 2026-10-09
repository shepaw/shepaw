import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/cli_host.dart';
import '../services/cli_pouch.dart';
import '../services/logger_service.dart';
import '../services/noise_identity.dart';
import '../storage/pouch_session.dart';
import 'host_entry_flow.dart';

/// 桌面首次进入：创建储物袋。之后每次用名称和密码进入。
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
  bool _ready = false;
  String _error = '';
  String? _savedId;

  @override
  void initState() {
    super.initState();
    _loadSavedName();
  }

  Future<void> _loadSavedName() async {
    if (widget.initializing) {
      if (mounted) setState(() => _ready = true);
      return;
    }
    final session = await PouchSessionStore.readActive();
    if (!mounted) return;
    _savedId = session?.pouchId;
    if (session != null && session.pouchName.isNotEmpty) {
      _name.text = session.pouchName;
    }
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_busy || !_ready) return;
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
    if (widget.initializing && password != _confirm.text) {
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
      final CliLoginGrant grant;
      if (widget.initializing) {
        grant = await CliPouch.init(
          binary: binary,
          name: name,
          password: password,
          fingerprint: fingerprint,
        );
      } else {
        grant = await CliPouch.login(
          binary: binary,
          name: name,
          password: password,
          fingerprint: fingerprint,
          savedId: _savedId,
        );
      }
      await CliPouch.openLocal(grant);
      if (!mounted) return;
      await HostEntryNavigator.go(context, isDesktop: true);
    } on StateError catch (error) {
      if (mounted) {
        setState(() => _error = switch (error.message) {
              '没有这只袋子' => l10n.pouchGate_missing,
              '有多只同名袋子' => l10n.pouchGate_ambiguous,
              _ => error.message,
            });
      }
    } catch (error) {
      LoggerService()
          .error('pouch gate failed', tag: 'PouchGate', error: error);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final initializing = widget.initializing;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          initializing ? l10n.pouchGate_initTitle : l10n.pouchGate_unlockTitle,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            initializing ? l10n.pouchGate_initBody : l10n.pouchGate_unlockBody,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            enabled: _ready && !_busy,
            decoration: InputDecoration(
              labelText: l10n.pouchGate_name,
              hintText: l10n.pouchGate_nameHint,
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: _ready && !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.passwordSetup_password,
            ),
            onSubmitted: (_) {
              if (!initializing) _submit();
            },
          ),
          if (initializing) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              enabled: _ready && !_busy,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.passwordSetup_confirmPassword,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy || !_ready ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    initializing ? l10n.pouchGate_create : l10n.pouchGate_enter,
                  ),
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
