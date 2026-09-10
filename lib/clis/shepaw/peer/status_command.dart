import '../../cli_base.dart';
import '../../../peer/services/peer_pairing_service.dart';
import 'peer_cli_helpers.dart';

/// 查询当前设备配对会话状态（Responder / Initiator 通用）。
class PeerStatusCommand extends CliCommand {
  @override
  String get name => 'status';

  @override
  String get description =>
      'Show current pairing session state, QR link, and pending inbound request';

  @override
  String get usage => 'shepaw peer status';

  @override
  String? get icon => '📡';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final svc = PeerPairingService.instance;
    final pending = svc.pendingIncomingRequest;
    final qr = svc.currentQrContent;

    return {
      'state': svc.state.name,
      'waiting_for_scanner': svc.state == PairingSessionState.waitingForScanner,
      'pending_inbound_request': pending?.toJson(),
      'qr_link': qr,
      'pairing_code': pairingCodeFromQr(qr),
    };
  }
}
