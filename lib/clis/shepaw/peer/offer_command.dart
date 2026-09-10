import '../../cli_base.dart';
import '../../../peer/services/peer_pairing_service.dart';
import 'peer_cli_helpers.dart'; // resolveInitiatorCorrelation, withCorrelationId

/// 开启本机配对等候（Responder 侧），生成 shepaw://peer 链接供对方连接。
class PeerOfferCommand extends CliCommand {
  @override
  String get name => 'offer';

  @override
  String get description =>
      'Start hosting a pairing session and return your shepaw://peer link';

  @override
  String get usage => 'shepaw peer offer';

  @override
  String? get icon => '📤';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['notes'] = [
      'Equivalent to opening Contacts → Pair device → My QR code.',
      'Keep the session active until the other side connects; then call peer accept.',
      'Re-running offer cancels any previous pairing session and generates a new code.',
    ];
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    try {
      final correlationId = resolveInitiatorCorrelation(flags);
      final link = await PeerPairingService.instance.startPairing(
        correlationId: correlationId,
      );
      return withCorrelationId({
        'success': true,
        'state': PeerPairingService.instance.state.name,
        'qr_link': link,
        'pairing_code': pairingCodeFromQr(link),
        'message':
            'Pairing session started. Share qr_link with the other device. '
            'When a device connects, She will be notified automatically '
            '(active subscription). Then call peer accept.',
        'events_hint':
            'Do not use long events wait on responder side; use peer accept when notified.',
      }, correlationId);
    } catch (e) {
      return {
        'success': false,
        'error': 'Failed to start pairing session: $e',
        'hint':
            'Ensure local network peer service or Channel tunnel is available.',
      };
    }
  }
}
