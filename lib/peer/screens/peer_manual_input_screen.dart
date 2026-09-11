import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../services/peer_pairing_service.dart';
import '../widgets/peer_pairing_confirm_card.dart';

/// P2P 手动输入配对页面（Initiator 侧）
///
/// 适用于桌面端等无法使用摄像头扫码的场景：
/// 用户粘贴对方二维码对应的配对深链（shepaw://peer?...）发起配对。
///
/// 拆成两步：先解析并展示「确认卡片」，用户核对无误后再连接。
/// 目的是让用户在**连接之前**知道对方是谁 —— 多人共用一个内网时，
/// 粘贴的人需要一个判断「我贴的是不是那个人的链接」的机会。
///
/// 卡片里的设备名是对方**自述**的、未经认证的标签；真正的凭据是指纹。
class PeerManualInputScreen extends StatefulWidget {
  final void Function(PairedPeer peer)? onPaired;

  const PeerManualInputScreen({super.key, this.onPaired});

  static Future<PairedPeer?> show(BuildContext context) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute<PairedPeer?>(
        builder: (_) => const PeerManualInputScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerManualInputScreen> createState() => _PeerManualInputScreenState();
}

class _PeerManualInputScreenState extends State<PeerManualInputScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _processing = false;
  String? _error;
  String? _statusMessage;

  /// 已解析、等待用户确认的配对信息。非空时页面渲染确认卡片。
  PeerPairingInfo? _pendingInfo;

  @override
  void dispose() {
    _controller.dispose();
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

  /// 第一步：只解析，不连接。成功则进入确认卡片。
  void _submit() {
    final l10n = AppLocalizations.of(context);
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.peerManual_emptyError);
      return;
    }

    final info = PeerPairingInfo.tryParse(raw);
    if (info == null) {
      setState(() => _error = l10n.peerManual_invalidError);
      return;
    }

    setState(() {
      _error = null;
      _pendingInfo = info;
    });
  }

  /// 第二步：用户在卡片上确认后才真正发起连接。
  Future<void> _connect(PeerPairingInfo info) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _processing = true;
      _error = null;
      _statusMessage = l10n.peerManual_connecting;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _processing && _error == null) {
        setState(() => _statusMessage = l10n.peerManual_waitingConfirm);
      }
    });

    try {
      final peer = await PeerPairingService.instance.requestPairing(info);
      if (mounted) {
        setState(() => _statusMessage = l10n.peerManual_success);
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        // 统一出口：内嵌（有 onPaired）交给调用方，独立路由 pop 回 PairedPeer。
        // 三个「我连它」入口都走这一条，谁也不自己判断内嵌与否。
        final onPaired = widget.onPaired;
        if (onPaired != null) {
          onPaired(peer);
        } else {
          Navigator.of(context).pop(peer);
        }
      }
    } on PairingRejectedException {
      _showError(l10n.peerManual_rejected);
    } on PairingTimeoutException {
      _showError(l10n.peerManual_timeout);
    } catch (e) {
      _showError(l10n.peerManual_failed('$e'));
    }
  }

  /// 失败时**保留** `_pendingInfo`：错误渲染在确认卡片内，重试只需再点一次确认。
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _processing = false;
      _statusMessage = null;
    });
  }

  void _cancelPending() {
    setState(() {
      _pendingInfo = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    if (_processing) {
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
      return PeerPairingConfirmCard(
        info: pending,
        error: _error,
        onConfirm: () => _connect(pending),
        onCancel: _cancelPending,
      );
    }
    return _buildInputForm(context, l10n, colorScheme);
  }

  Widget _buildInputForm(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.keyboard_alt_outlined, size: 48, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            l10n.peerManual_title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
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
            minLines: 3,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: l10n.peerManual_inputHint,
              border: const OutlineInputBorder(),
              errorText: _error,
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: l10n.peerManual_paste,
                onPressed: _pasteFromClipboard,
              ),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.link),
            label: Text(l10n.peerManual_submit),
          ),
        ],
      ),
    );
  }
}
