import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_connect_tab.dart';
import 'phone_auth_screen.dart';
import 'phone_host_store.dart';

/// 手机连远端主机：扫码，或输入配对地址。
class RemoteConnectScreen extends StatelessWidget {
  const RemoteConnectScreen({super.key, this.popOnPaired = false});

  /// 从储物袋页推进来时，配对成功后把主机交回去。
  /// 首次打开时，配对成功后去登录储物袋。
  final bool popOnPaired;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostSetup_remote)),
      body: PeerConnectTab(
        onPaired: (peer) => _onPaired(context, peer),
      ),
    );
  }

  Future<void> _onPaired(BuildContext context, PairedPeer peer) async {
    if (popOnPaired) {
      Navigator.of(context).pop(peer);
      return;
    }
    await PhoneHostStore.write(peer.id);
    if (!context.mounted) return;
    Navigator.of(context).pushReplacementNamed(
      '/phone-login',
      arguments: PhoneAuthArgs(hostPeerId: peer.id),
    );
  }
}
