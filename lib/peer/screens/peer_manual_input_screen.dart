import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../services/peer_pairing_service.dart';

/// P2P 手动输入配对页面（Initiator 侧）
///
/// 适用于桌面端等无法使用摄像头扫码的场景：
/// 用户粘贴对方二维码对应的配对深链（shepaw://peer?...）发起配对。
class PeerManualInputScreen extends StatefulWidget {
  final void Function(PairedPeer peer)? onPaired;

  const PeerManualInputScreen({super.key, this.onPaired});

  @override
  State<PeerManualInputScreen> createState() => _PeerManualInputScreenState();
}

class _PeerManualInputScreenState extends State<PeerManualInputScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _processing = false;
  String? _error;
  String? _statusMessage;

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

  Future<void> _submit() async {
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
        widget.onPaired?.call(peer);
      }
    } on PairingRejectedException {
      _showError(l10n.peerManual_rejected);
    } on PairingTimeoutException {
      _showError(l10n.peerManual_timeout);
    } catch (e) {
      _showError(l10n.peerManual_failed('$e'));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _processing = false;
      _statusMessage = null;
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
              _statusMessage ?? '处理中...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

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
