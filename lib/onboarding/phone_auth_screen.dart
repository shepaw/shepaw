import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import 'phone_host_store.dart';

/// 解锁后的手机登录参数。配对成功先记下主机，再进这一页。
class PhoneAuthArgs {
  const PhoneAuthArgs({required this.hostPeerId, this.justPaired = false});

  final String hostPeerId;
  final bool justPaired;
}

/// 已有袋子时用上次那只，否则用列表里的第一只。没有就返回 null，由调用方新建。
PouchDescriptor? chooseExistingPouch(
  List<PouchDescriptor> pouches, {
  String? preferredId,
}) {
  if (pouches.isEmpty) return null;
  final want = preferredId?.trim() ?? '';
  if (want.isNotEmpty) {
    for (final pouch in pouches) {
      if (pouch.id == want) return pouch;
    }
  }
  return pouches.first;
}

/// 手机登录：密码在主机上。没设过就在这里设，设过了就输入确认。
class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _argsRead = false;
  bool _justPaired = false;
  bool _busy = false;
  bool _ready = false;
  bool _passwordSet = false;
  String _hostId = '';
  String _error = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is PhoneAuthArgs) {
      _hostId = args.hostPeerId;
      _justPaired = args.justPaired;
    }
    _prepare();
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _busy = true;
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
      if (!mounted) return;
      setState(() {
        _passwordSet = set;
        _ready = true;
      });
    } catch (error) {
      LoggerService()
          .error('phone auth prepare failed', tag: 'PhoneAuth', error: error);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = l10n.login_emptyPassword);
      return;
    }
    if (password.length < 6) {
      setState(() => _error = l10n.passwordSetup_tooShort);
      return;
    }
    if (!_passwordSet && password != _confirm.text) {
      setState(() => _error = l10n.passwordSetup_mismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (!_passwordSet) {
        await requestPouchPasswordSet(hostPeerId: _hostId, password: password);
        _passwordSet = true;
      }
      final sessionBefore = await PouchSessionStore.readActive();
      final pouches = await requestPouchList(hostPeerId: _hostId);
      final existing = chooseExistingPouch(
        pouches,
        preferredId: sessionBefore?.pouchId,
      );
      final pouch = existing ??
          await requestPouchCreate(
            hostPeerId: _hostId,
            name: l10n.pouch_defaultName,
          );
      final grant = await requestPouchLogin(
        hostPeerId: _hostId,
        pouchId: pouch.id,
        password: password,
      );
      final peer = await PeerStorageService().getPeerById(_hostId);
      final local = peer?.localEndpoint?.trim() ?? '';
      final hubUrl = local.isNotEmpty ? local : (peer?.channelEndpoint ?? '');
      final session = PouchSession(
        hubUrl: hubUrl,
        pouchId: pouch.id,
        pouchName: pouch.name,
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
    final setting = _ready && !_passwordSet;
    final title = setting ? l10n.phoneAuth_setTitle : l10n.login_title;
    final body = setting
        ? l10n.phoneAuth_setBody
        : (_justPaired ? l10n.phoneAuth_confirmBody : l10n.phoneAuth_loginBody);
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
            if (!_ready && _busy) const LinearProgressIndicator(),
            TextField(
              controller: _password,
              obscureText: true,
              enabled: _ready && !_busy,
              decoration: InputDecoration(
                labelText:
                    setting ? l10n.phoneAuth_newPassword : l10n.login_password,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (setting) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.phoneAuth_confirmPassword,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _ready && !_busy ? _submit : null,
              child: Text(
                setting ? l10n.phoneAuth_setAndEnter : l10n.login_button,
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
