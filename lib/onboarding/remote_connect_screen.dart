import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../peer/models/paired_peer.dart';
import '../peer/screens/peer_connect_tab.dart';
import '../peer/services/peer_storage_service.dart';
import 'host_entry.dart';
import 'phone_auth_screen.dart';
import 'phone_host_store.dart';

/// 手机连远端主机：扫码，或输入配对地址。
///
/// 已经配过主机、这一页又是栈底时，返回回到登录页。
class RemoteConnectScreen extends StatefulWidget {
  const RemoteConnectScreen({super.key, this.popOnPaired = false});

  /// 从储物袋页推进来时，配对成功后把主机交回去。
  /// 首次打开时，配对成功后去登录储物袋。
  final bool popOnPaired;

  @override
  State<RemoteConnectScreen> createState() => _RemoteConnectScreenState();
}

class _RemoteConnectScreenState extends State<RemoteConnectScreen> {
  String? _rememberedHostId;

  @override
  void initState() {
    super.initState();
    _loadRememberedHost();
  }

  Future<void> _loadRememberedHost() async {
    final id = await PhoneHostStore.read();
    if (!mounted || id == null) return;
    final peer = await PeerStorageService().getPeerById(id);
    if (!mounted || peer == null) return;
    setState(() => _rememberedHostId = peer.id);
  }

  void _returnToLogin(String hostId) {
    Navigator.of(context).pushReplacementNamed(
      '/phone-login',
      arguments: PhoneAuthArgs(hostPeerId: hostId),
    );
  }

  Future<void> _onPaired(PairedPeer peer) async {
    if (widget.popOnPaired) {
      Navigator.of(context).pop(peer);
      return;
    }
    await PhoneHostStore.write(peer.id);
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/phone-login',
      (_) => false,
      arguments: PhoneAuthArgs(hostPeerId: peer.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final returnHostId = remoteConnectLoginHost(
      canPop: Navigator.of(context).canPop(),
      rememberedHostId: _rememberedHostId,
    );
    return PopScope(
      canPop: returnHostId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || returnHostId == null) return;
        _returnToLogin(returnHostId);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.hostSetup_remote),
          leading: returnHostId == null
              ? null
              : BackButton(onPressed: () => _returnToLogin(returnHostId)),
        ),
        body: PeerConnectTab(
          onPaired: (peer) => _onPaired(peer),
        ),
      ),
    );
  }
}
