import '../../cli_base.dart';
import '../../../peer/services/peer_connection_manager.dart';

/// 列出已配对的 ShePaw 设备及连接状态。
class PeerListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List paired ShePaw devices and connection status';

  @override
  String get usage => 'shepaw peer list';

  @override
  String? get icon => '📱';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final peers = await PeerConnectionManager.instance.getAllPeers();
    return {
      'count': peers.length,
      'peers': peers.map((p) => p.toJson()).toList(),
    };
  }
}
