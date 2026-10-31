import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import 'gate_controller.dart';
import 'gate_pouch.dart';
import 'gate_entry.dart';
import 'gate_errors.dart';
import 'widgets/gate_widgets.dart';

/// 两端共用的解锁页：只有一个主机密码框。
///
/// 一台主机只有一只袋子，所以袋子在界面上不出现 —— 它在 [GateController] 里
/// 推出来，只在欢迎语里露个名字。以前桌面和手机各有三个不同的袋子页，
/// 这里合成一个。
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, this.args, this.deps});

  final UnlockArgs? args;

  /// 测试注入。生产走 [GateDeps.production]。
  final GateDeps? deps;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  late final GateController _gate;
  UnlockArgs? _args;
  bool _argsRead = false;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _gate = GateController(deps: widget.deps ?? GateDeps.production());
    _gate.addListener(_onChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readArgs();
  }

  @override
  void didUpdateWidget(covariant UnlockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一条路由上参数换了（比如 keeper 换了一台主机）要重新认一遍。
    if (widget.args != oldWidget.args) _readArgs();
  }

  void _readArgs() {
    final raw = ModalRoute.of(context)?.settings.arguments;
    final next = raw is UnlockArgs ? raw : widget.args;
    if (next == null) return;
    if (_argsRead && _args == next) return;
    _argsRead = true;
    _args = next;
    _gate.thisComputer = next.hostPeerId.isEmpty;
    unawaited(_gate.load(next.hostPeerId));
  }

  void _onChanged() {
    if (!mounted) return;
    // 主机连上之后凭据续期成功，不用用户再点一次。
    if (_gate.restored && !_entered) {
      _entered = true;
      Navigator.of(context).pushReplacementNamed('/home');
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _gate.removeListener(_onChanged);
    _gate.dispose();
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_gate.busy || _gate.locked) return;
    final password = _password.text;
    if (password.length < 6) {
      setState(() {});
      return;
    }
    final ok = await _gate.submitPassword(password);
    if (!mounted) return;
    if (ok) {
      _entered = true;
      Navigator.of(context).pushReplacementNamed('/home');
      return;
    }
    _password.clear();
    _focus.requestFocus();
    LoggerService().info('unlock failed: ${_gate.error?.kind}', tag: 'Gate');
    setState(() {});
    if (_gate.error?.kind == GateErrorKind.wrongPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.unlock_wrongPassword)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final args = _args;
    final scheme = Theme.of(context).colorScheme;
    final host = _gate.peer;
    final hostName = host?.deviceName ?? '';
    final reason = args?.reason ?? UnlockReason.expired;
    final locked = _gate.lockedFor;
    final error = _gate.error;

    return PopScope(
      canPop: false,
      child: GateScaffold(
        avatar: CircleAvatar(
          radius: 30,
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.lock_outline, color: scheme.onPrimaryContainer),
        ),
        title: _welcome(l10n),
        body: [
          Center(
            child: HostStatusPill(
              hostName: hostName.isEmpty ? l10n.appTitle : hostName,
              status: _gate.reach,
              thisComputer: _gate.thisComputer,
              onRetry: () => _gate.retryConnect(),
            ),
          ),
          if (_reasonText(l10n, reason) != null) ...[
            const SizedBox(height: 16),
            _ReasonBar(text: _reasonText(l10n, reason)!),
          ],
          const SizedBox(height: 20),
          PasswordField(
            controller: _password,
            focusNode: _focus,
            autofocus: true,
            enabled: !_gate.busy && locked == null,
            shakeKey: _gate.shakeKey,
            onSubmitted: (_) => _submit(),
          ),
          if (error != null &&
              error.kind != GateErrorKind.credentialRejected) ...[
            const SizedBox(height: 12),
            Text(
              gateErrorTitle(l10n, error),
              style: TextStyle(color: scheme.error),
            ),
          ],
          if (_gate.reach == HostReachability.offline) ...[
            const SizedBox(height: 16),
            GateStatusCard(
              title: _gate.thisComputer
                  ? l10n.hostOffline_local
                  : l10n.hostOffline_remote(hostName),
              primaryLabel: l10n.gate_retry,
              onPrimary: () => _gate.retryConnect(),
              detail: error?.detail,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _gate.busy || locked != null ? null : _submit,
            child: Text(_buttonLabel(l10n, locked)),
          ),
        ],
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _gate.busy ? null : _forgot,
              child: Text(l10n.unlock_forgot),
            ),
            const Text(' · '),
            TextButton(
              onPressed: _gate.busy ? null : _switchHost,
              child: Text(l10n.unlock_switchHost),
            ),
          ],
        ),
      ),
    );
  }

  String _welcome(AppLocalizations l10n) {
    final name = welcomeName(_gate.pouchName);
    return name.isEmpty
        ? l10n.unlock_welcomeBackPlain
        : l10n.unlock_welcomeBack(name);
  }

  String _buttonLabel(AppLocalizations l10n, Duration? locked) {
    if (locked != null) {
      return l10n.unlock_lockedCountdown(locked.inSeconds.toString());
    }
    return _gate.busy ? l10n.unlock_entering : l10n.unlock_enter;
  }

  String? _reasonText(AppLocalizations l10n, UnlockReason reason) {
    switch (reason) {
      case UnlockReason.expired:
      case UnlockReason.switched:
        return null;
      case UnlockReason.credentialRejected:
        return l10n.unlock_whyCredential;
      case UnlockReason.hostRestarted:
        return l10n.unlock_whyRestarted;
      case UnlockReason.inviteInvalid:
        return l10n.unlock_whyInvite;
    }
  }

  void _forgot() {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.unlock_forgot),
        content: Text(
          _gate.thisComputer
              ? l10n.forgot_localBody
              : l10n.forgot_remoteBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  void _switchHost() {
    Navigator.of(context).pushNamed('/hosts');
  }
}

class _ReasonBar extends StatelessWidget {
  const _ReasonBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
