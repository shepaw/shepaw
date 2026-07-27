import '../../services/channel_tunnel_service.dart';
import 'peer_local_server.dart';

/// 本机当前可对外广告的 peer 端点（重连 / 配对握手用）。
Future<({String? local, String? channel})> advertisePeerEndpoints() async {
  final local = PeerLocalServer.instance.getLocalEndpoint();
  String? channel;
  try {
    final tunnelConfig = await ChannelTunnelService.instance.loadConfig();
    if (tunnelConfig != null &&
        ChannelTunnelService.instance.currentStatus == TunnelStatus.connected) {
      final endpoint =
          ChannelTunnelService.instance.getPublicEndpoint(tunnelConfig);
      if (endpoint != null) {
        channel = endpoint.replaceFirst('/acp/ws', '/peer/ws');
      }
    }
  } catch (_) {}
  return (local: local, channel: channel);
}
