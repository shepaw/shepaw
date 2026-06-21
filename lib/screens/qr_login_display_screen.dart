import 'package:flutter/material.dart';

import '../identity/services/account_join_service.dart';
import '../peer/screens/peer_pairing_screen.dart';

/// 主存储设备展示扫码登录二维码，供移动端扫描加入同一账号。
class QrLoginDisplayScreen extends StatelessWidget {
  const QrLoginDisplayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    AccountJoinService.instance.start();
    return const PeerPairingScreen(displayQrOnly: true);
  }
}
