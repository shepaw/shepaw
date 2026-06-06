import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import 'peer_manual_input_screen.dart';
import 'peer_qr_display_screen.dart';
import 'peer_qr_scanner_screen.dart';

/// P2P 配对主页面
///
/// 包含三个 Tab：
/// - "我的二维码"：展示自己的配对 QR 码
/// - "扫一扫"：扫描对方的配对 QR 码
/// - "输入"：手动粘贴对方配对链接发起配对（桌面端等无摄像头场景）
class PeerPairingScreen extends StatefulWidget {
  /// 配对成功回调。
  ///
  /// - 未提供（默认）：作为独立全屏对话框时，配对成功后 `pop` 返回 [PairedPeer]。
  /// - 提供时（如桌面端内嵌右侧面板）：由调用方接管后续导航，不再 `pop`。
  final void Function(PairedPeer peer)? onPaired;

  /// 初始 Tab 索引：0=我的二维码，1=扫一扫，2=输入。
  final int initialTabIndex;

  const PeerPairingScreen({
    super.key,
    this.onPaired,
    this.initialTabIndex = 0,
  });

  static const int scanTabIndex = 1;

  static Future<PairedPeer?> show(
    BuildContext context, {
    int initialTabIndex = 0,
  }) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute(
        builder: (_) => PeerPairingScreen(initialTabIndex: initialTabIndex),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerPairingScreen> createState() => _PeerPairingScreenState();
}

class _PeerPairingScreenState extends State<PeerPairingScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 2),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    PeerPairingService.instance.cancelPairing();
    super.dispose();
  }

  void _handlePaired(PairedPeer peer) {
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
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.peerPairing_title),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: const Icon(Icons.qr_code_2), text: l10n.peerPairing_tabMyQr),
            Tab(icon: const Icon(Icons.qr_code_scanner), text: l10n.peerPairing_tabScan),
            Tab(icon: const Icon(Icons.keyboard_alt_outlined), text: l10n.peerPairing_tabManual),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          PeerQrDisplayScreen(onPaired: _handlePaired),
          PeerQrScannerScreen(onPaired: _handlePaired),
          PeerManualInputScreen(onPaired: _handlePaired),
        ],
      ),
    );
  }
}
