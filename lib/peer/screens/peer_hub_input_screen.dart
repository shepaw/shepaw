import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../service_locator.dart';
import '../../services/hub_address.dart';
import '../../services/remote_hub_pairing_service.dart';
import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import '../widgets/peer_pairing_confirm_card.dart';

/// 通过对方电脑上的 Agent Hub 配对（Initiator 侧）。
///
/// 与 [PeerManualInputScreen] 同构，也是两步式：先向对方 Hub 要一个配对码，
/// 展示确认卡片，用户核对后才真正连接。
///
/// 为什么非要有这张卡片：Agent Hub 的 peer 服务握手时**只校验配对码，不校验
/// 是谁**，码对就直接 accept。所以「填地址 → 自动配对」实际等价于
/// 「谁能访问到对方 Hub 的仪表盘 API，谁就能把自己配上去」。对方不会收到
/// 二次确认，这张卡片就是唯一的闸门 —— 让用户有机会核对地址与指纹。
class PeerHubInputScreen extends StatefulWidget {
  const PeerHubInputScreen({
    super.key,
    this.onPaired,
    this.showGuide = false,
  });

  final void Function(PairedPeer peer)? onPaired;

  /// 打开时是否直接展开「怎么装 Agent Hub」的指引。
  final bool showGuide;

  static Future<PairedPeer?> show(
    BuildContext context, {
    bool showGuide = false,
  }) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute<PairedPeer?>(
        builder: (_) => PeerHubInputScreen(showGuide: showGuide),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerHubInputScreen> createState() => _PeerHubInputScreenState();
}

class _PeerHubInputScreenState extends State<PeerHubInputScreen> {
  final TextEditingController _addrController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  /// 只在探测出对方 Hub 需要令牌时才展开令牌输入框。
  ///
  /// 一上来就要两个框既吓人、也容易让人把令牌发给一个根本不需要它的 Hub。
  bool _tokenVisible = false;

  late bool _guideExpanded = widget.showGuide;

  bool _fetching = false;
  bool _connecting = false;
  String? _error;
  String? _statusMessage;

  /// 已取到、等待用户确认的票据。非空时页面渲染确认卡片。
  RemoteHubTicket? _pending;

  @override
  void dispose() {
    _addrController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  // ── 第一步：填地址 → 取码 ────────────────────────────────────────────

  Future<void> _fetchTicket() async {
    final l10n = AppLocalizations.of(context);
    final raw = _addrController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.peerHub_emptyError);
      return;
    }
    // 配对链接粘错框是很常见的失误，给一句指路的提示，别报「地址非法」。
    if (raw.startsWith('shepaw://')) {
      setState(() => _error = l10n.peerHub_pairLinkError);
      return;
    }
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
      final ticket = await getIt<RemoteHubPairingService>()
          .mintTicket(uri, token: _tokenController.text);
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _pending = ticket;
      });
    } on RemoteHubException catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        // 需要令牌：把输入框亮出来，别让用户对着「需要令牌」四个字找不到地方填。
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

  void _cancelPending() {
    setState(() {
      _pending = null;
      _error = null;
    });
  }

  // ── 第二步：确认卡片 → 配对 ──────────────────────────────────────────

  Future<void> _connect(RemoteHubTicket ticket) async {
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
      final peer =
          await PeerPairingService.instance.requestPairing(ticket.info);
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
      _showError(l10n.peerPairing_failed('$e'));
    }
  }

  /// 失败时**保留** `_pending`：错误渲染在确认卡片内，重试只需再点一次确认。
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _connecting = false;
      _statusMessage = null;
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
    final colorScheme = Theme.of(context).colorScheme;

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

    final pending = _pending;
    if (pending != null) return _buildConfirmCard(context, l10n, pending);
    return _buildForm(context, l10n, colorScheme);
  }

  Widget _buildForm(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.dns_outlined, size: 48, color: colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          l10n.peerHub_title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.peerHub_desc,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _addrController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.peerHub_addrLabel,
            hintText: l10n.peerHub_addrHint,
            helperText: l10n.peerHub_addrHelp,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.dns_outlined),
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
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
          onPressed: _fetching ? null : _fetchTicket,
          icon: _fetching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined),
          label: Text(
            _fetching ? l10n.peerHub_probing : l10n.peerHub_submit,
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
    RemoteHubTicket ticket,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return PeerPairingConfirmCard(
      info: ticket.info,
      error: _error,
      onConfirm: () => _connect(ticket),
      onCancel: _cancelPending,
      extraRows: [
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
      warnings: [
        const SizedBox(height: 16),
        _WarningRow(
          text: l10n.peerHub_confirmWarning,
          color: colorScheme.error,
        ),
        // 公网 + 明文 http 才提示；内网/回环提示了只是噪音。
        if (isInsecureDashboard(ticket.dashboardUri)) ...[
          const SizedBox(height: 8),
          _WarningRow(
            text: l10n.peerHub_insecureWarning,
            color: colorScheme.error,
          ),
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
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
