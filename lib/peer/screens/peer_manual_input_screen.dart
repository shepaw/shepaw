import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../service_locator.dart';
import '../../services/hub_address.dart';
import '../../services/remote_hub_pairing_service.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../services/peer_pairing_service.dart';
import '../widgets/peer_pairing_confirm_card.dart';

/// 「我连它」的手动输入页：粘贴配对链接，或填对方 Hub 地址。
///
/// 两种输入跑的是同一套握手，只是票据来源不同：
/// - `shepaw://peer?...`：对方已经把配对码打进链接，本地解析即可；
/// - Hub 仪表盘地址：先向对方 Hub 要一张票，再进入同一张确认卡片。
///
/// 拆成两步：先解析 / 取票并展示确认卡片，用户核对无误后再连接。
/// 卡片里的设备名是对方**自述**的、未经认证的标签；真正的凭据是指纹。
///
/// Hub 路径多一道闸门：Agent Hub 的 peer 服务握手时**只校验配对码，不校验
/// 是谁**，码对就直接 accept。确认卡片是用户核对地址与指纹的唯一机会。
class PeerManualInputScreen extends StatefulWidget {
  const PeerManualInputScreen({
    super.key,
    this.onPaired,
    this.showGuide = false,
    this.hubPairingService,
  });

  final void Function(PairedPeer peer)? onPaired;

  /// 打开时是否直接展开「怎么装 Agent Hub」的指引。
  final bool showGuide;

  /// 测试注入；生产路径走 [getIt]。
  final RemoteHubPairingService? hubPairingService;

  static Future<PairedPeer?> show(
    BuildContext context, {
    bool showGuide = false,
  }) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute<PairedPeer?>(
        builder: (_) => PeerManualInputScreen(showGuide: showGuide),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerManualInputScreen> createState() => _PeerManualInputScreenState();
}

enum _InputKind { empty, link, hub, unknown }

class _PeerManualInputScreenState extends State<PeerManualInputScreen> {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// 只在探测出对方 Hub 需要令牌时才展开令牌输入框。
  bool _tokenVisible = false;

  late bool _guideExpanded = widget.showGuide;

  bool _fetching = false;
  bool _connecting = false;
  String? _error;
  String? _statusMessage;
  _InputKind _kind = _InputKind.empty;

  /// 已解析、等待用户确认的配对信息。非空时页面渲染确认卡片。
  PeerPairingInfo? _pendingInfo;

  /// 非空表示票据来自远端 Hub，确认卡片要多展示地址与「不会二次确认」警告。
  RemoteHubTicket? _pendingTicket;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onInputChanged);
    _controller.dispose();
    _tokenController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final next = _classify(_controller.text);
    if (next == _kind && _error == null) return;
    setState(() {
      _kind = next;
      _error = null;
    });
  }

  _InputKind _classify(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return _InputKind.empty;
    if (PeerPairingInfo.tryParse(trimmed) != null) return _InputKind.link;
    if (looksLikeHubDashboardInput(trimmed)) return _InputKind.hub;
    return _InputKind.unknown;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    _controller.text = text.trim();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    if (!mounted) return;
    setState(() => _error = null);
    // 贴进来就是完整配对链接时，少点一次「发起配对」。
    if (_classify(_controller.text) == _InputKind.link) {
      await _submit();
    }
  }

  /// 第一步：识别输入 → 解析链接或向 Hub 取票。成功则进入确认卡片。
  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.peerManual_emptyError);
      return;
    }

    final info = PeerPairingInfo.tryParse(raw);
    if (info != null) {
      setState(() {
        _error = null;
        _pendingInfo = info;
        _pendingTicket = null;
      });
      return;
    }

    // 链接形状对、内容不对：别再当成主机名去探测 Hub。
    if (raw.toLowerCase().startsWith('shepaw://')) {
      setState(() => _error = l10n.peerManual_invalidError);
      return;
    }

    if (looksLikeHubDashboardInput(raw)) {
      await _fetchTicket(raw);
      return;
    }

    setState(() => _error = l10n.peerManual_invalidError);
  }

  Future<void> _fetchTicket(String raw) async {
    final l10n = AppLocalizations.of(context);
    final uri = normalizeHubDashboardUrl(raw);
    if (uri == null) {
      setState(() => _error = l10n.peerHub_invalidError);
      return;
    }

    setState(() {
      _fetching = true;
      _error = null;
    });

    try {
      final service =
          widget.hubPairingService ?? getIt<RemoteHubPairingService>();
      final ticket = await service.mintTicket(
        uri,
        token: _tokenController.text,
      );
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _pendingInfo = ticket.info;
        _pendingTicket = ticket;
      });
    } on RemoteHubException catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        if (e.code == 'auth-required') _tokenVisible = true;
        _error = _messageFor(e, l10n);
      });
    }
  }

  String _messageFor(RemoteHubException e, AppLocalizations l10n) {
    switch (e.code) {
      case 'unreachable':
        return l10n.peerHub_unreachableError;
      case 'not-hub':
        return l10n.peerHub_notHubError;
      case 'auth-required':
        return l10n.peerHub_tokenRequired;
      case 'unauthorized':
        return l10n.peerHub_tokenInvalid;
      case 'start-failed':
        return l10n.peerHub_startFailed(e.message);
      case 'pair-failed':
      case 'bad-response':
        return l10n.peerHub_ticketFailed(e.message);
      case 'bad-qr':
      case 'fingerprint-mismatch':
        return l10n.peerHub_ticketMismatch;
      default:
        return l10n.peerPairing_failed(e.message);
    }
  }

  /// 第二步：用户在卡片上确认后才真正发起连接。
  Future<void> _connect(PeerPairingInfo info) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _connecting = true;
      _error = null;
      _statusMessage = l10n.peerManual_connecting;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _connecting && _error == null) {
        setState(() => _statusMessage = l10n.peerManual_waitingConfirm);
      }
    });

    try {
      final peer = await PeerPairingService.instance.requestPairing(info);
      if (!mounted) return;
      setState(() => _statusMessage = l10n.peerManual_success);
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final onPaired = widget.onPaired;
      if (onPaired != null) {
        onPaired(peer);
      } else {
        Navigator.of(context).pop(peer);
      }
    } on PairingRejectedException {
      _showError(l10n.peerManual_rejected);
    } on PairingTimeoutException {
      _showError(l10n.peerManual_timeout);
    } catch (e) {
      _showError(l10n.peerManual_failed('$e'));
    }
  }

  /// 失败时**保留**确认卡片：错误渲染在卡片内，重试只需再点一次确认。
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _connecting = false;
      _statusMessage = null;
    });
  }

  void _cancelPending() {
    setState(() {
      _pendingInfo = null;
      _pendingTicket = null;
      _error = null;
    });
  }

  Future<void> _copyGuide() async {
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: l10n.peerHub_guideBody));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.peerHub_guideCopied)),
    );
  }

  void _toggleGuide() {
    HapticFeedback.selectionClick();
    setState(() => _guideExpanded = !_guideExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.peerManual_title)),
      body: SafeArea(child: _buildBody(context, l10n)),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final Widget child;
    if (_connecting) {
      child = _buildConnecting(context, l10n);
    } else if (_pendingInfo != null) {
      child = _buildConfirmCard(context, l10n, _pendingInfo!, _pendingTicket);
    } else {
      child = _buildInputForm(context, l10n);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(
        key: ValueKey<String>(
          _connecting
              ? 'connecting'
              : _pendingInfo != null
                  ? 'confirm'
                  : 'input',
        ),
        child: child,
      ),
    );
  }

  Widget _buildConnecting(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage ?? l10n.common_processing,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputForm(BuildContext context, AppLocalizations l10n) {
    final busy = _fetching;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            children: [
              _buildGuideCard(context, l10n),
              const SizedBox(height: 16),
              _buildInputCard(context, l10n, busy),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _tokenVisible
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _buildTokenField(context, l10n),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
        _buildSubmitBar(context, l10n, busy),
      ],
    );
  }

  Widget _buildGuideCard(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.onPrimaryContainer,
        );
    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _toggleGuide,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: colorScheme.surface.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.terminal,
                            size: 20,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.peerHub_guideTitle,
                            style: titleStyle,
                          ),
                        ),
                        AnimatedRotation(
                          turns: _guideExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 48, right: 8),
                      child: Text(
                        l10n.peerManual_guideHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.78),
                              height: 1.4,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _guideExpanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: _buildGuideCommands(context, l10n, colorScheme),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuideCommands(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.peerHub_guideCopy,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.peerHub_guideCopy,
                  onPressed: () {
                    // 点复制时不要再触发外层展开/收起。
                    _copyGuide();
                  },
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              l10n.peerHub_guideBody,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputCard(
    BuildContext context,
    AppLocalizations l10n,
    bool busy,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasError = _error != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasError ? colorScheme.error : colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.peerConnect_pasteTitle,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.peerManual_desc,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              focusNode: _inputFocus,
              enabled: !busy,
              maxLines: 4,
              minLines: 3,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: InputDecoration(
                hintText: l10n.peerManual_inputHint,
                filled: true,
                fillColor: colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.45),
                  ),
                ),
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              ),
              onSubmitted: busy ? null : (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildKindChip(context, l10n, colorScheme)),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(l10n.peerManual_paste),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: hasError
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _ErrorBanner(message: _error!),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKindChip(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    final recognized = switch (_kind) {
      _InputKind.link => (
          l10n.peerManual_recognizedLink,
          Icons.link,
          colorScheme.primary,
        ),
      _InputKind.hub => (
          l10n.peerManual_recognizedHub,
          Icons.dns_outlined,
          colorScheme.primary,
        ),
      _InputKind.empty || _InputKind.unknown => null,
    };
    if (recognized == null) return const SizedBox.shrink();
    final (label, icon, color) = recognized;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenField(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: TextField(
          controller: _tokenController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.peerHub_tokenLabel,
            hintText: l10n.peerHub_tokenHint,
            helperText: l10n.peerHub_tokenHelp,
            helperMaxLines: 3,
            filled: true,
            fillColor: colorScheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(Icons.key_outlined),
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ),
    );
  }

  Widget _buildSubmitBar(
    BuildContext context,
    AppLocalizations l10n,
    bool busy,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(height: 1, color: colorScheme.outlineVariant),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: busy
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.peerHub_probing),
                      ],
                    )
                  : Text(l10n.peerManual_submit),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmCard(
    BuildContext context,
    AppLocalizations l10n,
    PeerPairingInfo info,
    RemoteHubTicket? ticket,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return PeerPairingConfirmCard(
      info: info,
      error: _error,
      onConfirm: () => _connect(info),
      onCancel: _cancelPending,
      extraRows: [
        if (ticket != null) ...[
          const SizedBox(height: 12),
          PeerPairingInfoRow(
            icon: Icons.dns_outlined,
            child: Text(
              l10n.peerHub_confirmHub(ticket.dashboardUri.toString()),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ],
      warnings: [
        if (ticket != null) ...[
          const SizedBox(height: 16),
          _WarningRow(
            text: l10n.peerHub_confirmWarning,
            color: colorScheme.error,
          ),
          if (isInsecureDashboard(ticket.dashboardUri)) ...[
            const SizedBox(height: 8),
            _WarningRow(
              text: l10n.peerHub_insecureWarning,
              color: colorScheme.error,
            ),
          ],
        ],
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                      height: 1.35,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_outlined, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
