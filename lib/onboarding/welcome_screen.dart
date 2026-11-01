import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/models/pairing_payload.dart';
import '../../peer/pouch_pair.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../services/cli_host.dart';
import '../../services/logger_service.dart';
import '../../utils/platform_utils.dart';
import 'gate_entry.dart';
import 'host_entry.dart';
import 'gate_navigator.dart';

/// 第一次进来选主机放哪。桌面是「这台电脑 / 另一台电脑」两张卡；
/// 手机那一半（扫码加入）在 L5 加到同一个路由上。
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _connecting = false;

  /// 切到「连接另一台电脑」那个视图。
  bool _remote = false;

  @override
  Widget build(BuildContext context) {
    if (_remote) {
      return const ConnectRemoteView();
    }
    return _ChooseHostView(
      onThisComputer: _useThisComputer,
      onRemote: () => setState(() => _remote = true),
      busy: _connecting,
    );
  }

  Future<void> _useThisComputer() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await HostModeStore.write(HostMode.thisComputer);
      if (!mounted) return;
      await Navigator.of(context).pushReplacementNamed('/host-install');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }
}

class _ChooseHostView extends StatelessWidget {
  const _ChooseHostView({
    required this.onThisComputer,
    required this.onRemote,
    required this.busy,
  });

  final VoidCallback onThisComputer;
  final VoidCallback onRemote;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final cards = <Widget>[
      _ChoiceCard(
        icon: Icons.computer_outlined,
        title: l10n.welcome_thisComputer,
        badge: l10n.welcome_recommended,
        body: l10n.welcome_thisComputerDesc,
        action: l10n.welcome_useThisComputer,
        emphasized: true,
        autofocus: true,
        onPressed: busy ? null : onThisComputer,
      ),
      _ChoiceCard(
        icon: Icons.link,
        title: l10n.welcome_otherComputer,
        body: l10n.welcome_otherComputerDesc,
        action: l10n.welcome_goConnect,
        emphasized: false,
        onPressed: busy ? null : onRemote,
      ),
    ];
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 24),
                  Text(
                    l10n.welcome_title,
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.welcome_desktopIntro,
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final card in cards)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: card,
                            ),
                          ),
                      ],
                    )
                  else
                    ...cards.map(
                      (card) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: card,
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.welcome_changeLater,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.emphasized,
    required this.onPressed,
    this.badge,
    this.autofocus = false,
  });

  final IconData icon;
  final String title;
  final String? badge;
  final String body;
  final String action;
  final bool emphasized;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: emphasized
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (badge != null)
                  Text(
                    badge!,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: emphasized
                  ? FilledButton(
                      autofocus: autofocus,
                      onPressed: onPressed,
                      child: Text(action),
                    )
                  : OutlinedButton(
                      onPressed: onPressed,
                      child: Text(action),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连接另一台电脑上的主机：粘贴加入链接。
///
/// 以前这里是 `RemoteHostGuideScreen`，只有终端命令和粘贴框；现在第一步改成
/// 「在主机那台电脑上出示加入码」，粘贴退成第二步。
class ConnectRemoteView extends StatefulWidget {
  const ConnectRemoteView({super.key});

  @override
  State<ConnectRemoteView> createState() => _ConnectRemoteViewState();
}

class _ConnectRemoteViewState extends State<ConnectRemoteView> {
  final _link = TextEditingController();
  bool _busy = false;
  bool _offline = false;
  String? _offlineHost;
  String _error = '';
  bool _fromClipboard = false;

  @override
  void initState() {
    super.initState();
    _link.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _readClipboard());
  }

  void _onChanged() => setState(() {});

  Future<void> _readClipboard() async {
    if (_link.text.trim().isNotEmpty) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty || !mounted) return;
      if (PeerPairingInfo.tryParse(text) == null) return;
      _link.text = text;
      setState(() => _fromClipboard = true);
    } catch (_) {
      // 读剪贴板失败不算错误，用户自己粘就行。
    }
  }

  @override
  void dispose() {
    _link.removeListener(_onChanged);
    _link.dispose();
    super.dispose();
  }

  PeerPairingInfo? get _parsed => PeerPairingInfo.tryParse(_link.text.trim());

  Future<void> _connect() async {
    final info = _parsed;
    final l10n = AppLocalizations.of(context);
    if (info == null || _busy) return;
    setState(() {
      _busy = true;
      _error = '';
      _offline = false;
    });
    try {
      await HostModeStore.write(HostMode.remote);
      final peer = await PouchPairing.request(info);
      if (!mounted) return;
      final online =
          PeerConnectionManager.instance.connectedPeerIds.contains(peer.id);
      if (!online) {
        setState(() {
          _offline = true;
          _offlineHost = peer.deviceName;
          _busy = false;
        });
        return;
      }
      if (!mounted) return;
      await _enter(peer);
    } catch (error) {
      LoggerService().error('remote connect failed',
          tag: 'Welcome', error: error);
      if (mounted) setState(() {
        _error = l10n.gate_errorGeneric;
        _busy = false;
      });
    }
  }

  /// 配对成功：去输主机密码（L6 之后，链接带邀请就直接进主页）。
  Future<void> _enter(PairedPeer peer) async {
    if (!mounted) return;
    await Navigator.of(context).pushReplacementNamed(
      '/unlock',
      arguments: UnlockArgs(hostPeerId: peer.id),
    );
  }

  /// 卡片上的「再试一次」。失败时卡片不消失，只换文案。
  Future<void> _retry() async {
    setState(() => _busy = true);
    final info = _parsed;
    if (info == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final peers = await PeerConnectionManager.instance.getAllPeers();
      final peer = peers
          .where((item) => item.fingerprint == info.fingerprint)
          .firstOrNull;
      if (peer == null) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context).gate_errorGeneric;
        });
        return;
      }
      await PeerConnectionManager.instance.disconnectPeer(peer.id);
      await PeerConnectionManager.instance.connectToPeer(
        peer,
        ignoreTieBreak: true,
      );
      if (!mounted) return;
      if (PeerConnectionManager.instance.connectedPeerIds.contains(peer.id)) {
        await _enter(peer);
        return;
      }
      setState(() => _busy = false);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final install = cliInstallCommand();
    const startPair = 'shepaw start && shepaw pair';
    final invalid =
        _link.text.trim().isNotEmpty && _parsed == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.connect_title),
        leading: BackButton(
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
              return;
            }
            Navigator.of(context).pushReplacementNamed('/welcome');
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(l10n.connect_step1),
                const SizedBox(height: 12),
                Text(
                  l10n.connect_step1Terminal,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                _CommandRow(text: install),
                const SizedBox(height: 4),
                _CommandRow(text: startPair),
                const SizedBox(height: 24),
                Text(l10n.connect_step2),
                const SizedBox(height: 8),
                TextField(
                  controller: _link,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'shepaw://peer?...',
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (invalid) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.connect_invalidLink,
                    style: TextStyle(color: scheme.error),
                  ),
                ] else if (_fromClipboard) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.connect_clipboardDetected,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy || _parsed == null ? null : _connect,
                  child: Text(
                    _busy ? l10n.unlock_entering : l10n.connect_button,
                  ),
                ),
                if (_offline) ...[
                  const SizedBox(height: 16),
                  _OfflineCard(
                    host: _offlineHost ?? '',
                    busy: _busy,
                    onRetry: _retry,
                    onEnterOffline: () => Navigator.of(context)
                        .pushReplacementNamed('/unlock'),
                  ),
                ],
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(_error, style: TextStyle(color: scheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineCard extends StatelessWidget {
  const _OfflineCard({
    required this.host,
    required this.busy,
    required this.onRetry,
    required this.onEnterOffline,
  });

  final String host;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onEnterOffline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.connect_savedButOffline(host),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(l10n.connect_offlineHint),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : onRetry,
                  child: Text(l10n.connect_tryAgain),
                ),
                OutlinedButton(
                  onPressed: onEnterOffline,
                  child: Text(l10n.connect_enterOffline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        IconButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          icon: const Icon(Icons.copy, size: 18),
          tooltip: AppLocalizations.of(context).hostInstall_copyCommand,
        ),
      ],
    );
  }
}

/// 安装命令。Windows 走 PowerShell，其余走 install.sh。
String cliInstallCommand() {
  if (Platform.isWindows) {
    return 'irm https://release.shepaw.com/install.ps1 | iex';
  }
  return 'curl -fsSL https://release.shepaw.com/install.sh | sh';
}
