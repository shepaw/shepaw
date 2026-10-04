/// 本机 CLI 正在听的回环地址。由 [CliHost] 在启动时挂上，避免配对层反向依赖它。
typedef LocalCliSnapshot = ({String fingerprint, String localEndpoint});

Future<LocalCliSnapshot?> Function()? lookupLocalCli;

bool sameFingerprint(String? a, String? b) {
  final left = a?.trim().toLowerCase() ?? '';
  final right = b?.trim().toLowerCase() ?? '';
  return left.isNotEmpty && left == right;
}

/// 对方就是本机 CLI 时，留下回环地址，不用二维码里的局域网地址覆盖。
({String? localEndpoint, String? channelEndpoint}) pairingEndpointsForPeer({
  required String peerFingerprint,
  required String? localCliFingerprint,
  required String? loopbackEndpoint,
  required String? offeredLocal,
  required String? offeredChannel,
}) {
  final loopback = loopbackEndpoint?.trim() ?? '';
  if (sameFingerprint(peerFingerprint, localCliFingerprint) &&
      loopback.isNotEmpty) {
    return (localEndpoint: loopback, channelEndpoint: null);
  }
  return (localEndpoint: offeredLocal, channelEndpoint: offeredChannel);
}
