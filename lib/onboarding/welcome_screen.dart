import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/models/pairing_payload.dart';
import '../../peer/pouch_pair.dart';
import '../../peer/screens/peer_scan_screen.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../services/logger_service.dart';
import '../../utils/platform_utils.dart';
import 'gate_entry.dart';
import 'host_entry.dart';
import 'joining_view.dart';
import 'wait_host_view.dart';
import 'widgets/gate_widgets.dart';
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

  /// 手机上：正在加入哪条链接。
  PeerPairingInfo? _joining;

  /// 手机上：等电脑设密码。
  String? _waitingHostId;

  /// 手机上：上一次加入失败（连不上），保留主机名再给一次机会。
  _OfflineJoin? _offline;

  @override
  Widget build(BuildContext context) {
    if (_joining != null) {
      return JoiningView(
        key: ValueKey<Object?>(_joining!.fingerprint),
        info: _joining!,
        onCancel: () => setState(() => _joining = null),
        onDone: _onJoined,
      );
    }
    final waiting = _waitingHostId;
    if (waiting != null) {
      return WaitHostView(
        hostPeerId: waiting,
        onReady: () => _goUnlock(waiting),
      );
    }
    if (_remote) {
      return const ConnectRemoteView();
    }
    if (!isDesktopPlatform) {
      return _PhoneJoinView(
        onScan: _scan,
        onPaste: () => setState(() => _remote = true),
        offline: _offline,
        onRetry: () {
          final offline = _offline;
          if (offline == null) return;
          setState(() {
            _offline = null;
            _joining = offline.info;
          });
        },
      );
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
      // 交给统一的进门判断：新电脑还没有袋子时要直接去「建袋子 + 设密码」，
      // 不能先去「准备主机」——Hub 要 active_pouch 才起得来，会卡在启动那步。
      await GateNavigator.go(context);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// 扫码。`PeerScanScreen` 自己完成配对并返回设备；返回 null 时可能是权限
  /// 被拒，这时给一个「去设置开启」的出口。
  Future<void> _scan() async {
    final peer = await PeerScanScreen.show(context);
    if (!mounted) return;
    if (peer != null) {
      await _goUnlock(peer.id);
      return;
    }
    final status = await Permission.camera.status;
    if (!mounted) return;
    if (!status.isGranted) {
      await _cameraDenied();
    }
  }

  Future<void> _cameraDenied() async {
    final l10n = AppLocalizations.of(context);
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.gate_camera),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.gate_usePaste),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.gate_cameraSettings),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (goSettings == true) {
      await openAppSettings();
      return;
    }
    setState(() => _remote = true);
  }

  void _onJoined(PairedPeer? peer, JoinOutcome outcome) {
    if (peer == null) {
      setState(() {
        _joining = null;
        _offline = _OfflineJoin(info: _joining!, hostName: '');
      });
      return;
    }
    switch (outcome) {
      case JoinOutcome.entered:
        unawaited(_goHome());
      case JoinOutcome.unlock:
        unawaited(_goUnlock(peer.id));
      case JoinOutcome.waitHost:
        setState(() {
          _joining = null;
          _waitingHostId = peer.id;
        });
      case JoinOutcome.offline:
        setState(() {
          _joining = null;
          _offline = _OfflineJoin(info: _joining!, hostName: peer.deviceName);
        });
    }
  }

  /// 免密进去了：直接去主页。
  Future<void> _goHome() async {
    if (!mounted) return;
    await Navigator.of(context).pushReplacementNamed('/home');
  }

  Future<void> _goUnlock(String hostPeerId) async {
    if (!mounted) return;
    await Navigator.of(context).pushReplacementNamed(
      '/unlock',
      arguments: UnlockArgs(hostPeerId: hostPeerId),
    );
  }
}

/// 加入失败时记住的那点状态：还要能「再试一次」。
class _OfflineJoin {
  const _OfflineJoin({required this.info, required this.hostName});

  final PeerPairingInfo info;
  final String hostName;
}

/// 手机上第一次进来：扫码加入，或者粘贴链接。
class _PhoneJoinView extends StatelessWidget {
  const _PhoneJoinView({
    required this.onScan,
    required this.onPaste,
    this.offline,
    this.onRetry,
  });

  final VoidCallback onScan;
  final VoidCallback onPaste;
  final _OfflineJoin? offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 48),
                  Center(
                    child: Icon(
                      Icons.pets_outlined,
                      size: 64,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.welcome_phoneTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.welcome_phoneIntro,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: onScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(l10n.welcome_scan),
                  ),
                  TextButton(
                    onPressed: onPaste,
                    child: Text(l10n.welcome_paste),
                  ),
                  if (offline != null) ...[
                    const SizedBox(height: 16),
                    GateStatusCard(
                      title: l10n.connect_savedButOffline(offline!.hostName),
                      body: l10n.connect_offlineHint,
                      primaryLabel: l10n.connect_tryAgain,
                      onPrimary: onRetry,
                    ),
                  ],
                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text(
                    l10n.welcome_whereCode,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.welcome_whereCodeBody),
                  const SizedBox(height: 16),
                  Text(l10n.welcome_noDesktop),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
  const ConnectRemoteView({super.key, this.popOnPaired = false});

  /// 从别的页面推进来时，配对成功后把设备交回去，不自己导航。
  final bool popOnPaired;

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
      if (widget.popOnPaired) {
        Navigator.of(context).pop(peer);
        return;
      }
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
      if (mounted) {
        setState(() {
          _error = l10n.gate_errorGeneric;
          _busy = false;
        });
      }
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
                const _CommandRow(text: startPair),
                const SizedBox(height: 24),
                Text(l10n.connect_step2),
                const SizedBox(height: 8),
                TextField(
                  controller: _link,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'shepaw://peer?...',
                    border: OutlineInputBorder(),
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
