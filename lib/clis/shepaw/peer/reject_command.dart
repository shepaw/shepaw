import '../../cli_base.dart';
import '../../../peer/services/peer_pairing_service.dart';
import 'peer_cli_helpers.dart';

/// 拒绝入站配对请求（Responder 侧）。
class PeerRejectCommand extends CliCommand {
  @override
  String get name => 'reject';

  @override
  String get description => 'Reject a pending inbound device pairing request';

  @override
  String get usage => 'shepaw peer reject';

  @override
  String? get icon => '❌';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final svc = PeerPairingService.instance;
    final pending = svc.pendingIncomingRequest;
    if (pending == null) {
      return {
        'success': false,
        'error': 'No pending inbound pairing request.',
        'state': svc.state.name,
      };
    }

    final correlationId = resolveContinuatorCorrelation();
    await svc.rejectPairing(pending);
    return withCorrelationId({
      'success': true,
      'message': 'Pairing request rejected',
      'rejected_device': pending.toJson(),
      'state': svc.state.name,
    }, correlationId);
  }
}
