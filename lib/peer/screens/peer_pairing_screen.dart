import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import 'peer_connect_tab.dart';
import 'peer_qr_display_screen.dart';

/// 设备配对的两个**方向**。
///
/// 刻意不是「方式」：[扫码 / 输入地址 / 粘贴链接] 都是 [connect] 下的手段，
/// 平铺成同级 tab 会让人先想清楚「哪个 tab 对应哪个方向」才敢点。
/// 扫码另外抽成了独立全屏页（`PeerScanScreen`），一点即达。
enum PeerPairingTab {
  /// 我连它：扫码 / 输入对方 Hub 地址 / 粘贴配对链接。
  connect,

  /// 它连我：展示自己的二维码，等待对方扫描。
  beConnected,
}

/// P2P 配对主页面
class PeerPairingScreen extends StatefulWidget {
  /// 配对成功回调。
  ///
  /// - 未提供（默认）：作为独立全屏对话框时，配对成功后 `pop` 返回 [PairedPeer]。
  /// - 提供时（如桌面端内嵌右侧面板）：由调用方接管后续导航，不再 `pop`。
  final void Function(PairedPeer peer)? onPaired;

  /// 初始方向。默认「我连它」—— 从「+」菜单进来的人多半是想连别人。
  final PeerPairingTab initialTab;

  const PeerPairingScreen({
    super.key,
    this.onPaired,
    this.initialTab = PeerPairingTab.connect,
  });

  static Future<PairedPeer?> show(
    BuildContext context, {
    PeerPairingTab initialTab = PeerPairingTab.connect,
  }) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute(
        builder: (_) => PeerPairingScreen(initialTab: initialTab),
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
      length: PeerPairingTab.values.length,
      vsync: this,
      initialIndex: widget.initialTab.index,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    // 整个配对流程的最终清理点：切 tab 不会走到这里（父页面还活着），
    // 所以「它连我」那侧的 Responder 会话由这里兜底收掉。
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
            Tab(
              icon: const Icon(Icons.qr_code_scanner),
              text: l10n.peerPairing_tabConnect,
            ),
            Tab(
              icon: const Icon(Icons.qr_code_2),
              text: l10n.peerPairing_tabBeConnected,
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          PeerConnectTab(onPaired: _handlePaired),
          PeerQrDisplayScreen(onPaired: _handlePaired),
        ],
      ),
    );
  }
}
