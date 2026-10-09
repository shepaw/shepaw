import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/cli_pouch.dart';
import '../services/logger_service.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import 'phone_host_store.dart';

/// 解锁后的手机登录参数。配对成功先记下主机，再进这一页。
class PhoneAuthArgs {
  const PhoneAuthArgs({required this.hostPeerId});

  final String hostPeerId;
}

/// 按名称选出储物袋。名称只对上一只就用它；同名多只时只认上次的 ID。
PouchPickResult pickPhonePouch({
  required String typedName,
  required List<PouchDescriptor> pouches,
  String? savedId,
}) {
  return pickPouchAccount(
    typedName: typedName,
    accounts: [
      for (final pouch in pouches)
        CliPouchAccount(id: pouch.id, name: pouch.name),
    ],
    savedId: savedId,
  );
}

/// 手机登录：主机已经在电脑上初始化。这里只输入名称和密码。
class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _name = TextEditingController();
  final _password = TextEditingController();

  bool _argsRead = false;
  bool _busy = false;
  bool _probing = false;
  bool _ready = false;
  bool _passwordSet = false;
  bool _nameFilled = false;
  String _hostId = '';
  String? _savedId;
  String _error = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is PhoneAuthArgs) {
      _hostId = args.hostPeerId;
    }
    _prepare();
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _probing = true;
      _error = '';
      _ready = false;
    });
    try {
      var hostId = _hostId;
      if (hostId.isEmpty) {
        hostId = await PhoneHostStore.read() ?? '';
      }
      if (hostId.isEmpty) {
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/remote-connect');
        }
        return;
      }
      _hostId = hostId;
      final peer = await PeerStorageService().getPeerById(hostId);
      if (peer == null) {
        await _repair();
        return;
      }
      await _connect(peer);
      if (!mounted) return;
      final set = await requestPouchPasswordStatus(hostPeerId: hostId);
      if (!_nameFilled) {
        final session = await PouchSessionStore.readActive();
        _savedId = session?.pouchId;
        final savedName = session?.pouchName.trim() ?? '';
        if (savedName.isNotEmpty && _name.text.isEmpty) {
          _name.text = savedName;
        }
        _nameFilled = true;
      }
      if (!mounted) return;
      setState(() {
        _passwordSet = set;
        _ready = true;
      });
    } catch (error) {
      LoggerService()
          .error('phone auth prepare failed', tag: 'PhoneAuth', error: error);
      if (mounted) {
        setState(() {
          // 问失败也要能输入。返回用户按已有密码登录，刚配对的按首次设置。
          _ready = true;
          _passwordSet = true;
          _error = error is TimeoutException
              ? '主机没有回应。请确认电脑上的 shepaw 已重启，然后再登录。'
              : error is StateError
                  ? error.message
                  : '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _connect(PairedPeer peer) async {
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peer.id)) {
      await PeerConnectionManager.instance.connectToPeer(
        peer,
        ignoreTieBreak: true,
      );
    }
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (PeerConnectionManager.instance.connectedPeerIds.contains(peer.id)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    throw StateError(AppLocalizations.of(context).pouch_hostOffline);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_busy || !_ready) return;
    if (!_passwordSet) return;
    final name = _name.text.trim();
    final password = _password.text;
    if (name.isEmpty) {
      setState(() => _error = l10n.pouch_nameRequired);
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = l10n.login_emptyPassword);
      return;
    }
    if (password.length < 6) {
      setState(() => _error = l10n.passwordSetup_tooShort);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final pouches = await requestPouchList(hostPeerId: _hostId);
      final picked = pickPhonePouch(
        typedName: name,
        pouches: pouches,
        savedId: _savedId,
      );
      final CliPouchAccount account;
      switch (picked.kind) {
        case PouchPick.found:
          account = picked.account!;
        case PouchPick.missing:
          throw StateError(l10n.pouchGate_missing);
        case PouchPick.ambiguous:
          throw StateError(l10n.pouchGate_ambiguous);
      }
      final grant = await requestPouchLogin(
        hostPeerId: _hostId,
        pouchId: account.id,
        password: password,
      );
      final peer = await PeerStorageService().getPeerById(_hostId);
      final local = peer?.localEndpoint?.trim() ?? '';
      final hubUrl = local.isNotEmpty ? local : (peer?.channelEndpoint ?? '');
      final session = PouchSession(
        hubUrl: hubUrl,
        pouchId: account.id,
        pouchName: account.name,
        hostPeerId: _hostId,
        token: grant.token,
        sessionId: grant.sessionId,
        expiresAtMs: grant.expiresAtMs,
      );
      await PouchSessionStore(await PouchSessionStore.appFile()).save(session);
      PouchChannel.install(session);
      await PhoneHostStore.write(_hostId);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } on PouchPasswordRequired catch (error) {
      if (mounted) {
        setState(() {
          _passwordSet = true;
          _error = error.reason;
        });
      }
    } catch (error) {
      LoggerService()
          .error('phone auth failed', tag: 'PhoneAuth', error: error);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repair() async {
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/remote-connect');
  }

  void _forgot() {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.login_forgotPassword),
        content: Text(l10n.phoneAuth_forgotBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final waiting = _ready && !_passwordSet;
    final title = waiting ? l10n.phoneAuth_setTitle : l10n.login_title;
    final body = waiting ? l10n.phoneAuth_setBody : l10n.phoneAuth_loginBody;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(body, textAlign: TextAlign.center),
            const SizedBox(height: 32),
            if (_probing) const LinearProgressIndicator(),
            if (!waiting) ...[
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
                obscureText: true,
                enabled: _ready && !_busy,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.login_password,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: !_ready || _busy
                  ? null
                  : waiting
                      ? _prepare
                      : _submit,
              child: Text(
                waiting ? l10n.phoneAuth_setAndEnter : l10n.login_button,
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            TextButton(
              onPressed: _busy ? null : _forgot,
              child: Text(l10n.login_forgotPassword),
            ),
            TextButton(
              onPressed: _busy ? null : _repair,
              child: Text(l10n.phoneAuth_repair),
            ),
          ],
        ),
      ),
    );
  }
}
