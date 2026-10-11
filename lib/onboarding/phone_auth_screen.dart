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
import '../storage/pouch_login_keeper.dart';
import '../storage/pouch_session.dart';
import 'phone_host_store.dart';
import 'phone_pouch_memory.dart';

/// 解锁后的手机登录参数。配对成功先记下主机，再进这一页。
class PhoneAuthArgs {
  const PhoneAuthArgs({required this.hostPeerId});

  final String hostPeerId;
}

/// 刚配上的主机已经有袋子。一只就用它；多只时优先上次登录的那只。
PouchDescriptor? choosePhonePouch(
  List<PouchDescriptor> pouches, {
  String? savedId,
}) {
  if (pouches.isEmpty) return null;
  final saved = savedId?.trim() ?? '';
  if (saved.isNotEmpty) {
    for (final pouch in pouches) {
      if (pouch.id == saved) return pouch;
    }
  }
  return pouches.first;
}

/// 主机已经回答就用它的名单，空名单也算回答。还没问到时用记住的。
List<PouchDescriptor> phonePouchesToShow({
  required List<PouchDescriptor>? live,
  required List<PouchDescriptor> remembered,
}) {
  if (live != null) return live;
  return remembered;
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
  String _hostId = '';
  String? _savedId;
  List<PouchDescriptor> _pouches = const [];
  PouchDescriptor? _selected;
  String _error = '';

  @override
  void initState() {
    super.initState();
    PouchLoginKeeper.instance.retainGate();
  }

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
    PouchLoginKeeper.instance.releaseGate();
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
      final remembered = await _loadRemembered(hostId);
      if (remembered.isNotEmpty) {
        await PhonePouchMemory.write(hostId, remembered);
        if (!mounted) return;
        setState(() {
          _passwordSet = true;
          _pouches = remembered;
          _selected = choosePhonePouch(remembered, savedId: _savedId);
          _ready = true;
        });
      }
      await _connect(peer);
      if (!mounted) return;
      final set = await requestPouchPasswordStatus(hostPeerId: hostId);
      final List<PouchDescriptor> live = set
          ? await requestPouchList(hostPeerId: hostId)
          : const <PouchDescriptor>[];
      if (set && live.isNotEmpty) {
        await PhonePouchMemory.write(hostId, live);
      }
      final shown = phonePouchesToShow(live: live, remembered: remembered);
      if (!mounted) return;
      setState(() {
        _passwordSet = set;
        _pouches = shown;
        _selected = choosePhonePouch(shown, savedId: _savedId);
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

  /// 先用本机记住的袋子。连上主机之后再换成那边的名单。
  Future<List<PouchDescriptor>> _loadRemembered(String hostId) async {
    var pouches = await PhonePouchMemory.read(hostId);
    final session = await PouchSessionStore.readActive();
    if (session != null && session.hostPeerId == hostId) {
      _savedId = session.pouchId;
      pouches = rememberPhonePouch(
        pouches,
        id: session.pouchId,
        name: session.pouchName,
      );
    }
    final memory = await PouchLoginMemory.read();
    if (memory != null) {
      final known = pouches.any((pouch) => pouch.id == memory.id);
      if (known) {
        _savedId ??= memory.id;
      } else if (pouches.isEmpty &&
          (session == null || session.hostPeerId == hostId)) {
        _savedId ??= memory.id;
        pouches = rememberPhonePouch(
          pouches,
          id: memory.id,
          name: memory.name,
        );
      }
    }
    return pouches;
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
    final selected = _selected;
    final typedName = _name.text.trim();
    final password = _password.text;
    if (selected == null && typedName.isEmpty) {
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
      final CliPouchAccount account;
      if (selected != null) {
        account = CliPouchAccount(id: selected.id, name: selected.name);
      } else {
        final pouches = await requestPouchList(hostPeerId: _hostId);
        final picked = pickPhonePouch(
          typedName: typedName,
          pouches: pouches,
          savedId: _savedId,
        );
        switch (picked.kind) {
          case PouchPick.found:
            account = picked.account!;
          case PouchPick.missing:
            throw StateError(l10n.pouchGate_missing);
          case PouchPick.ambiguous:
            throw StateError(l10n.pouchGate_ambiguous);
        }
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
      await PouchLoginMemory.write(id: account.id, name: account.name);
      await PhonePouchMemory.write(
        _hostId,
        rememberPhonePouch(
          _pouches,
          id: account.id,
          name: account.name,
        ),
      );
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

  /// 重新配对叠在登录页上。系统返回还能回到刚才那一页。
  void _pairAgain() {
    Navigator.of(context).pushNamed('/remote-connect');
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
    final choosing = !waiting && _pouches.isNotEmpty;
    final title = waiting
        ? l10n.phoneAuth_setTitle
        : choosing
            ? l10n.pouchGate_unlockTitle
            : l10n.login_title;
    final body = waiting
        ? l10n.phoneAuth_setBody
        : choosing
            ? l10n.pouchGate_unlockBody
            : l10n.phoneAuth_confirmBody;
    final selected =
        _selected ?? choosePhonePouch(_pouches, savedId: _savedId);
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
              if (_pouches.isNotEmpty)
                RadioGroup<String>(
                  groupValue: selected?.id,
                  onChanged: (value) {
                    if (_busy || value == null) return;
                    setState(() {
                      _selected = choosePhonePouch(_pouches, savedId: value);
                    });
                  },
                  child: Column(
                    children: [
                      for (final pouch in _pouches)
                        RadioListTile<String>(
                          value: pouch.id,
                          title: Text(pouch.name),
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                )
              else if (!_probing)
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
              onPressed: !_ready || _busy || _probing
                  ? null
                  : waiting
                      ? _prepare
                      : _submit,
              child: Text(
                waiting
                    ? l10n.phoneAuth_setAndEnter
                    : choosing
                        ? l10n.pouchGate_enter
                        : l10n.login_button,
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
              onPressed: _busy ? null : _pairAgain,
              child: Text(l10n.phoneAuth_repair),
            ),
          ],
        ),
      ),
    );
  }
}
