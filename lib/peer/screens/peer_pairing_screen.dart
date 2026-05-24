import 'package:flutter/material.dart';

import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import 'peer_qr_display_screen.dart';
import 'peer_qr_scanner_screen.dart';

/// P2P 配对主页面
///
/// 包含两个 Tab：
/// - "我的二维码"：展示自己的配对 QR 码
/// - "扫一扫"：扫描对方的配对 QR 码
class PeerPairingScreen extends StatefulWidget {
  const PeerPairingScreen({super.key});

  static Future<PairedPeer?> show(BuildContext context) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute(
        builder: (_) => const PeerPairingScreen(),
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
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    PeerPairingService.instance.cancelPairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('配对设备'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.qr_code_2), text: '我的二维码'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: '扫一扫'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          PeerQrDisplayScreen(
            onPaired: (peer) => Navigator.of(context).pop(peer),
          ),
          PeerQrScannerScreen(
            onPaired: (peer) => Navigator.of(context).pop(peer),
          ),
        ],
      ),
    );
  }
}
