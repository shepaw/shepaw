import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/qr_scanner_view.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../services/peer_pairing_service.dart';

/// P2P 配对扫码页（Initiator 侧）—— 独立全屏路由。
///
/// 不挂在「设备配对」的 tab 里：扫码是「我连它」方向下最常用的一种**方式**，
/// 而 tab 表达的是**方向**。把两者分开，扫码才能一点即达。
///
/// 相机 / 权限 / 生命周期那套样板在 [QrScannerView] 里，这里只有业务：
/// 扫到码 → 跑完整配对握手 → 成功才 pop。
///
/// 三种出口：
/// - 成功：显示「配对成功」0.5s 后带着 [PairedPeer] 返回；
/// - 被拒 / 超时 / 异常：错误条留在页内，冷却后自动恢复取景，可以直接再扫；
/// - 用户返回 / 权限被拒 / 桌面端：返回 `null`。
class PeerScanScreen extends StatefulWidget {
  const PeerScanScreen({super.key, this.onPaired});

  /// 配对成功回调。不提供时由本页 `pop(peer)` 返回给调用方。
  final void Function(PairedPeer peer)? onPaired;

  static Future<PairedPeer?> show(BuildContext context) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute<PairedPeer?>(
        builder: (_) => const PeerScanScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerScanScreen> createState() => _PeerScanScreenState();
}

class _PeerScanScreenState extends State<PeerScanScreen> {
  bool _processing = false;
  String? _statusMessage;
  String? _error;

  /// 本页是否在共享的配对会话槽上留下过痕迹。
  ///
  /// [PeerPairingService] 是单例 + 单一会话槽，`cancelPairing()` 会顺手取消
  /// `_localSub`（即 Responder 会话）。所以只有在**本页真的发起过配对**时才
  /// 配清理 —— 否则「打开看一眼就返回」也会去清掉一个不属于自己的会话。
  bool _ownsSession = false;

  @override
  void dispose() {
    if (_ownsSession) {
      // 不 await：dispose 是同步契约。cancelPairing 只是取消订阅 / 关流，
      // 不需要等它完成；这里同步点火即可。
      PeerPairingService.instance.cancelPairing();
    }
    super.dispose();
  }

  Future<QrScannerOutcome> _handlePayload(String raw) async {
    final l10n = AppLocalizations.of(context);
    final info = PeerPairingInfo.tryParse(raw);
    if (info == null) {
      // 不是配对码（可能是 agent 的 enroll 码、普通网址…）。
      _showError(l10n.peerScan_notPairingQr);
      return QrScannerOutcome.retry;
    }

    setState(() {
      _processing = true;
      _error = null;
      _statusMessage = l10n.peerManual_connecting;
    });

    // 握手头 2 秒几乎必然在「正在连接」，之后才轮到对方确认。
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _processing && _error == null) {
        setState(() => _statusMessage = l10n.peerManual_waitingConfirm);
      }
    });

    _ownsSession = true;
    try {
      final peer = await PeerPairingService.instance.requestPairing(info);
      if (!mounted) return QrScannerOutcome.consumed;
      setState(() => _statusMessage = l10n.peerManual_success);
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return QrScannerOutcome.consumed;
      _finish(peer);
      return QrScannerOutcome.consumed;
    } on PairingRejectedException {
      _showError(l10n.peerManual_rejected);
      return QrScannerOutcome.retry;
    } on PairingTimeoutException {
      _showError(l10n.peerManual_timeout);
      return QrScannerOutcome.retry;
    } catch (e) {
      _showError(l10n.peerPairing_failed('$e'));
      return QrScannerOutcome.retry;
    }
  }

  /// 失败时**保留** `_error`：错误条留在页内，壳冷却 2s 后恢复取景。
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _processing = false;
      _statusMessage = null;
    });
  }

  void _finish(PairedPeer peer) {
    final onPaired = widget.onPaired;
    if (onPaired != null) {
      onPaired(peer);
    } else {
      Navigator.of(context).pop(peer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return QrScannerView(
      title: l10n.peerConnect_scanTitle,
      hint: l10n.peerScan_frameHint,
      onPayload: _handlePayload,
      unsupportedBody: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.peerScan_desktopUnsupported),
          const SizedBox(height: 8),
          Text(
            l10n.peerScan_useMobile,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
      overlay: _buildOverlay(context, l10n),
    );
  }

  Widget? _buildOverlay(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_processing) {
      // 握手期间相机是停的，盖一层不透明底把冻住的那一帧藏掉。
      return Positioned.fill(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.85),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 24),
                Text(
                  _statusMessage ?? l10n.common_processing,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final error = _error;
    if (error == null) return null;
    return Positioned(
      left: 32,
      right: 32,
      bottom: 100,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: TextStyle(color: colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
