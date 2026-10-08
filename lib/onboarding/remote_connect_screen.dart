import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_connect_tab.dart';
import 'host_entry.dart';

/// 手机连远端主机：扫码，或输入配对地址。
class RemoteConnectScreen extends StatelessWidget {
  const RemoteConnectScreen({super.key, this.popOnPaired = false});

  /// 从储物袋页推进来时，配对成功后把主机交回去。
  /// 解锁后作为下一页时，配对成功后进入选袋子。
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

  void _onPaired(BuildContext context, PairedPeer peer) {
    if (popOnPaired) {
      Navigator.of(context).pop(peer);
      return;
    }
    Navigator.of(context).pushReplacementNamed(
      '/pouch',
      arguments: PouchLoginArgs(hostPeerId: peer.id),
    );
  }
}
