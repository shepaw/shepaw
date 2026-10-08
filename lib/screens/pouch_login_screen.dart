import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_manual_input_screen.dart';
import '../peer/screens/peer_scan_screen.dart';
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../onboarding/host_entry.dart';
import '../onboarding/remote_connect_screen.dart';
import '../peer/pairing_endpoints.dart';
import '../services/cli_host.dart';
import '../services/local_user_identity.dart';
import '../services/logger_service.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_login.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';

/// 先选主机，再选这台主机上的一只袋子进入。
class PouchLoginScreen extends StatefulWidget {
  const PouchLoginScreen({super.key});

  @override
  State<PouchLoginScreen> createState() => _PouchLoginScreenState();
}

class _PouchLoginScreenState extends State<PouchLoginScreen> {
  final _nameController = TextEditingController();

  static const _localChoice = '__this_computer__';

  bool _switching = false;
  bool _hostUnresponsive = false;
  String? _preferredHostId;
  LocalCliStatus _cliStatus = LocalCliStatus.notInstalled;
  bool _argsRead = false;
  bool _desktop = false;
  bool _busy = false;
  bool _hostReady = false;
  bool _autoEntered = false;
  String _error = '';
  String? _binary;
  CliHostEndpoint? _cli;
  List<PairedPeer> _hosts = const [];
  String? _hostId;
  PairedPeer? _host;
  List<PouchDescriptor> _pouches = const [];
  String? _currentPouchId;

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _desktop = _isDesktop;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    _switching = args is PouchLoginArgs && args.switching;
    _hostUnresponsive = args is PouchLoginArgs && args.hostUnresponsive;
    _preferredHostId = args is PouchLoginArgs ? args.hostPeerId : null;
    _reload();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = '';
      _hostReady = false;
    });
    try {
      final session = await PouchSessionStore.readActive();
      if (mounted) _currentPouchId = session?.pouchId;
      if (_desktop) {
        await _loadDesktop();
      } else {
        await _loadPhone(_preferredHostId ?? session?.hostPeerId);
      }
    } catch (error) {
      LoggerService()
          .error('pouch hosts failed', tag: 'PouchLogin', error: error);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (_hostReady) {
            _hostUnresponsive = false;
          } else if (_hostUnresponsive && _error.isEmpty) {
            _error = AppLocalizations.of(context).hostAttach_unresponsive;
          }
        });
      }
    }
  }

  Future<void> _restartHost() async {
    final binary = _binary ?? _cli?.binary ?? await CliHost.resolveBinary();
    if (binary == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await CliHost.restart(binary);
      if (mounted) await _reload();
    } catch (error) {
      LoggerService()
          .error('shepaw restart failed', tag: 'PouchLogin', error: error);
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).hostAttach_unresponsive,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadDesktop() async {
    final status = await CliHost.probe();
    final cli = await CliHost.detect();
    final binary = cli?.binary ?? await CliHost.resolveBinary();
    final peers = await PeerStorageService().loadAllPeers();
    final remotes = peers
        .where((peer) =>
            !peer.isBlocked &&
            !sameFingerprint(peer.fingerprint, cli?.fingerprint))
        .toList();
    if (!mounted) return;
    final preferRemote = _preferredHostId != null &&
        remotes.any((peer) => peer.id == _preferredHostId);
    setState(() {
      _cliStatus = status;
      _cli = cli;
      _binary = binary;
      _hosts = remotes;
      _hostId = preferRemote ? _preferredHostId : _localChoice;
      _host = preferRemote
          ? remotes.where((peer) => peer.id == _preferredHostId).firstOrNull
          : null;
    });
    if (preferRemote) {
      final host = _host;
      if (host == null) return;
      await _connect(host);
      if (_hostReady) await _loadPouches(host.id);
      return;
    }
    if (cli == null) return;
    final peer = await CliHost.ensurePaired(cli);
    if (!mounted) return;
    setState(() => _host = peer);
    await _connect(peer, redial: true);
    await _loadPouches(peer.id);
  }

  Future<void> _loadPhone(String? preferredHostId) async {
    final peers = await PeerStorageService().loadAllPeers();
    final hosts = peers.where((peer) => !peer.isBlocked).toList();
    if (!mounted) return;
    String? selected;
    if (preferredHostId != null &&
        hosts.any((peer) => peer.id == preferredHostId)) {
      selected = preferredHostId;
    } else if (hosts.isNotEmpty) {
      selected = hosts.first.id;
    }
    setState(() {
      _hosts = hosts;
      _hostId = selected;
      _host = selected == null
          ? null
          : hosts.where((peer) => peer.id == selected).firstOrNull;
    });
    final host = _host;
    if (host == null) return;
    await _connect(host);
    if (_hostReady) await _loadPouches(host.id);
  }

  Future<void> _connect(PairedPeer peer, {bool redial = false}) async {
    final already =
        PeerConnectionManager.instance.connectedPeerIds.contains(peer.id);
    if (redial || !already) {
      if (already) {
        await PeerConnectionManager.instance.disconnectPeer(peer.id);
      }
      final stored = await PeerStorageService().getPeerById(peer.id) ?? peer;
      await PeerConnectionManager.instance.connectToPeer(
        stored,
        ignoreTieBreak: true,
      );
    }
    final connected = await _waitConnected(peer.id);
    if (!mounted) return;
    setState(() {
      _hostReady = connected;
      if (!connected) _error = AppLocalizations.of(context).pouch_hostOffline;
    });
  }

  Future<bool> _waitConnected(String peerId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<void> _loadPouches(String hostPeerId) async {
    final pouches = await requestPouchList(hostPeerId: hostPeerId);
    if (!mounted) return;
    setState(() => _pouches = pouches);
    if (pouches.isEmpty) _prefillPouchName();
    if (!_switching && !_autoEntered && pouches.length == 1) {
      _autoEntered = true;
      await _enter(pouches.single);
    }
  }

  void _prefillPouchName() {
    if (_nameController.text.trim().isNotEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context);
    final display = LocalUserIdentity.displayName.trim();
    _nameController.text =
        display.isEmpty ? l10n.pouch_defaultName : l10n.pouch_namedBag(display);
  }

  Future<void> _startCli() async {
    final binary = _binary;
    if (binary == null || _busy) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await CliHost.start(binary);
      if (mounted) await _loadDesktop();
    } catch (error) {
      LoggerService()
          .error('shepaw start failed', tag: 'PouchLogin', error: error);
      if (mounted) setState(() => _error = l10n.pouch_startFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectHost(PairedPeer peer) async {
    if (_busy || peer.id == _hostId) return;
    setState(() {
      _busy = true;
      _error = '';
      _hostId = peer.id;
      _host = peer;
      _hostReady = false;
      _pouches = const [];
    });
    try {
      await _connect(peer);
      if (_hostReady) await _loadPouches(peer.id);
    } catch (error) {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).pouch_hostOffline);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addHost() async {
    if (!_desktop) {
      final peer = await Navigator.of(context).push<PairedPeer>(
        MaterialPageRoute<PairedPeer>(
          builder: (_) => const RemoteConnectScreen(popOnPaired: true),
        ),
      );
      if (!mounted) return;
      final session = await PouchSessionStore.readActive();
      await _loadPhone(peer?.id ?? session?.hostPeerId ?? _hostId);
      return;
    }
    final cameraOk = await _cameraUsable();
    if (!mounted) return;
    if (!cameraOk) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const PeerManualInputScreen(),
        ),
      );
    } else {
      await PeerScanScreen.show(context);
    }
    if (!mounted) return;
    final session = await PouchSessionStore.readActive();
    await _loadPhone(session?.hostPeerId ?? _hostId);
  }

  Future<bool> _cameraUsable() async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return false;
    }
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _create() async {
    final host = _host;
    final l10n = AppLocalizations.of(context);
    if (_busy || host == null || !_hostReady) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.pouch_nameRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final pouch = await requestPouchCreate(
        hostPeerId: host.id,
        name: name,
      );
      _nameController.clear();
      await _enter(pouch);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      LoggerService()
          .error('pouch create failed', tag: 'PouchLogin', error: error);
      if (mounted) setState(() => _error = l10n.pouch_createFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enter(PouchDescriptor pouch) async {
    final host = _host;
    final l10n = AppLocalizations.of(context);
    if (host == null || !_hostReady) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final grant = await requestPouchLogin(
        hostPeerId: host.id,
        pouchId: pouch.id,
      );
      final hubUrl = _desktop
          ? (_cli?.localEndpoint ??
              host.localEndpoint ??
              host.channelEndpoint ??
              '')
          : ((host.localEndpoint?.trim().isNotEmpty ?? false)
              ? host.localEndpoint!
              : (host.channelEndpoint ?? ''));
      final session = PouchSession(
        hubUrl: hubUrl,
        pouchId: pouch.id,
        pouchName: pouch.name,
        hostPeerId: host.id,
        token: grant.token,
        sessionId: grant.sessionId,
        expiresAtMs: grant.expiresAtMs,
      );
      await PouchSessionStore(await PouchSessionStore.appFile()).save(session);
      PouchChannel.install(session);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } on StateError catch (error) {
      LoggerService()
          .error('pouch login failed', tag: 'PouchLogin', error: error);
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      LoggerService()
          .error('pouch login failed', tag: 'PouchLogin', error: error);
      if (mounted) setState(() => _error = l10n.pouch_loginFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pouchesEnabled = _hostReady && !_busy;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pouch_title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.pouch_intro, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          Text(l10n.pouch_hostSection,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._hostSection(l10n),
          const SizedBox(height: 24),
          Text(l10n.pouch_pouchSection,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_busy && !_hostReady)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (_hostReady && _pouches.isEmpty)
            Text(l10n.pouch_noPouches)
          else
            ..._pouches.map(
              (pouch) => ListTile(
                title: Text(pouch.name),
                subtitle: pouch.id == _currentPouchId
                    ? Text(l10n.pouch_current)
                    : null,
                enabled: pouchesEnabled,
                onTap: () => _enter(pouch),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(labelText: l10n.pouch_newName),
            enabled: pouchesEnabled,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: pouchesEnabled ? _create : null,
            child: Text(_busy ? l10n.pouch_busy : l10n.pouch_createAndEnter),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_hostUnresponsive) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : _restartHost,
              child: Text(l10n.hostAttach_restart),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _hostSection(AppLocalizations l10n) {
    if (_desktop) {
      final localSubtitle = switch (_cliStatus) {
        LocalCliStatus.notInstalled => l10n.pouch_notInstalled,
        LocalCliStatus.installedStopped => l10n.pouch_hostOffline,
        LocalCliStatus.running => _cli?.localEndpoint ?? l10n.home_statusOnline,
      };
      return [
        RadioGroup<String>(
          groupValue: _hostId,
          onChanged: (value) {
            if (_busy || value == null) return;
            if (value == _localChoice) {
              if (_cliStatus == LocalCliStatus.notInstalled) {
                Navigator.of(context).pushNamed('/host-setup');
                return;
              }
              _preferredHostId = null;
              unawaited(_reload());
              return;
            }
            final peer = _hosts.where((item) => item.id == value).firstOrNull;
            if (peer != null) unawaited(_selectHost(peer));
          },
          child: Column(
            children: [
              RadioListTile<String>(
                value: _localChoice,
                title: Text(l10n.pouch_thisComputer),
                subtitle: Text(localSubtitle),
              ),
              for (final peer in _hosts)
                RadioListTile<String>(
                  value: peer.id,
                  title: Text(peer.deviceName),
                  subtitle: Text(
                    PeerConnectionManager.instance.connectedPeerIds
                            .contains(peer.id)
                        ? l10n.peerList_connected
                        : l10n.peerList_disconnected,
                  ),
                ),
            ],
          ),
        ),
        if (_cliStatus == LocalCliStatus.installedStopped && _binary != null)
          FilledButton(
            onPressed: _busy ? null : _startCli,
            child: Text(l10n.pouch_startCli),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : _addHost,
            child: Text(l10n.pouch_addHost),
          ),
        ),
      ];
    }
    if (_hosts.isEmpty) {
      return [
        Text(l10n.pouch_pairFirst),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _addHost,
          child: Text(l10n.pouch_pair),
        ),
      ];
    }
    final connected = PeerConnectionManager.instance.connectedPeerIds;
    return [
      RadioGroup<String>(
        groupValue: _hostId,
        onChanged: (value) {
          if (_busy || value == null) return;
          final peer = _hosts.where((item) => item.id == value).firstOrNull;
          if (peer != null) unawaited(_selectHost(peer));
        },
        child: Column(
          children: [
            for (final peer in _hosts)
              RadioListTile<String>(
                value: peer.id,
                title: Text(peer.deviceName),
                subtitle: Text(
                  connected.contains(peer.id)
                      ? l10n.peerList_connected
                      : l10n.peerList_disconnected,
                ),
              ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy ? null : _addHost,
          child: Text(l10n.pouch_addHost),
        ),
      ),
    ];
  }
}
