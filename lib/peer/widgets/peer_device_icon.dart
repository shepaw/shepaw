import 'package:flutter/material.dart';

import '../models/paired_peer.dart';

/// 配对设备图标与标签的配色。
///
/// - [PeerPairingRole.initiator]（本机发起）：绿色，表示主动连接、相对更安全。
/// - [PeerPairingRole.responder]（对方发起）：警告色，表示被动接受、需留意来源。
class PeerDeviceStyle {
  final Color backgroundColor;
  final Color iconColor;
  final Color labelColor;

  const PeerDeviceStyle({
    required this.backgroundColor,
    required this.iconColor,
    required this.labelColor,
  });

  factory PeerDeviceStyle.forPeer(PairedPeer peer) {
    switch (peer.pairingRole) {
      case PeerPairingRole.initiator:
        return PeerDeviceStyle(
          backgroundColor: Colors.green.shade50,
          iconColor: Colors.green.shade700,
          labelColor: Colors.green.shade700,
        );
      case PeerPairingRole.responder:
        return PeerDeviceStyle(
          backgroundColor: Colors.amber.shade50,
          iconColor: Colors.amber.shade800,
          labelColor: Colors.amber.shade800,
        );
      case null:
        return PeerDeviceStyle(
          backgroundColor: Colors.green.shade50,
          iconColor: Colors.green.shade700,
          labelColor: Colors.green.shade700,
        );
    }
  }
}

/// 配对设备统一头像图标（smartphone + 按发起方着色的背景）。
class PeerDeviceIcon extends StatelessWidget {
  final PairedPeer peer;
  final double size;
  final double borderRadius;

  const PeerDeviceIcon({
    super.key,
    required this.peer,
    this.size = 48,
    this.borderRadius = 12,
  });

  @override
  Widget build(BuildContext context) {
    final style = PeerDeviceStyle.forPeer(peer);
    final iconSize = size * 0.5;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: style.backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.smartphone, size: iconSize, color: style.iconColor),
    );
  }
}
