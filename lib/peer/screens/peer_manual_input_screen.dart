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

class _PeerManualInputScreenState extends State<PeerManualInputScreen> {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  /// 只在探测出对方 Hub 需要令牌时才展开令牌输入框。
  bool _tokenVisible = false;

  late bool _guideExpanded = widget.showGuide;

  bool _fetching = false;
  bool _connecting = false;
  String? _error;
  String? _statusMessage;

  /// 已解析、等待用户确认的配对信息。非空时页面渲染确认卡片。
  PeerPairingInfo? _pendingInfo;

  /// 非空表示票据来自远端 Hub，确认卡片要多展示地址与「不会二次确认」警告。
  RemoteHubTicket? _pendingTicket;

  @override
  void dispose() {
    _controller.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.trim().isNotEmpty) {
      setState(() {
        _controller.text = text.trim();
        _error = null;
      });
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.peerManual_title)),
      body: SafeArea(child: _buildBody(context, l10n)),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_connecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _statusMessage ?? l10n.common_processing,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    final pending = _pendingInfo;
    if (pending != null) {
      return _buildConfirmCard(context, l10n, pending, _pendingTicket);
    }
    return _buildInputForm(context, l10n);
  }

  Widget _buildInputForm(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final busy = _fetching;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.link, size: 48, color: colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          l10n.peerManual_desc,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _controller,
          maxLines: 4,
          minLines: 2,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: l10n.peerManual_inputHint,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.link),
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: l10n.peerManual_paste,
              onPressed: _pasteFromClipboard,
            ),
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: busy ? null : (_) => _submit(),
        ),
        if (_tokenVisible) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _tokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.peerHub_tokenLabel,
              hintText: l10n.peerHub_tokenHint,
              helperText: l10n.peerHub_tokenHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key_outlined),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 20, color: colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colorScheme.error),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: busy ? null : _submit,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text(
            busy ? l10n.peerHub_probing : l10n.peerManual_submit,
          ),
        ),
        const SizedBox(height: 24),
        _buildGuideCard(context, l10n, colorScheme),
      ],
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

  Widget _buildGuideCard(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _guideExpanded = !_guideExpanded),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.peerHub_guideTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Icon(
                  _guideExpanded ? Icons.expand_less : Icons.expand_more,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_guideExpanded) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                l10n.peerHub_guideBody,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _copyGuide,
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l10n.peerHub_guideCopy),
              ),
            ),
          ],
        ],
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
