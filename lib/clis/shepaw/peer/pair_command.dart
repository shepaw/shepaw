import '../../cli_base.dart';
import '../../../peer/models/pairing_payload.dart';
import '../../../peer/services/peer_pairing_service.dart';
import '../../../services/pair_deeplink.dart';
import 'peer_cli_helpers.dart';

/// 通过配对深链发起设备配对（Initiator 侧）。
///
/// 用法：
///   shepaw peer pair --link "shepaw://peer?local=...&code=...#fp=...&pk=..."
///
/// 对方设备须正在展示「我的二维码」，并在收到请求后于 UI 确认。
/// 配对过程可能耗时数秒至数分钟，需等待对方确认。
class PeerPairCommand extends CliCommand {
  @override
  String get name => 'pair';

  @override
  String get description =>
      'Pair with another ShePaw device using a shepaw://peer?... link';

  @override
  String get usage =>
      'shepaw peer pair --link "shepaw://peer?local=...&code=...#fp=...&pk=..."';

  @override
  String? get icon => '🔗';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'link': {
        'description':
            'Full device pairing deep link from the other device\'s QR page '
            '(shepaw://peer?...)',
        'required': true,
        'type': 'string',
      },
    };
    base['notes'] = [
      'This is device-to-device pairing, not remote Agent enrollment.',
      'For shepaw://pair?... (ACP agent QR), use Add Agent → scan in the UI.',
      'The other device must keep its pairing session open (peer offer or My QR tab) '
      'and confirm via peer accept or the UI dialog.',
    ];
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final raw = (flags['link'] ?? flags['url'] ?? '').trim();
    if (raw.isEmpty) {
      return {'error': 'Missing required flag: --link'};
    }

    final info = PeerPairingInfo.tryParse(raw);
    if (info == null) {
      return _invalidLinkError(raw);
    }

    try {
      final correlationId = resolveInitiatorCorrelation(flags);
      final peer = await PeerPairingService.instance.requestPairing(
        info,
        correlationId: correlationId,
      );
      return withCorrelationId({
        'success': true,
        'message': 'Device paired successfully',
        'peer': peer.toJson(),
        'events_hint':
            'Pairing completed synchronously; result is in peer. '
            'Do not call events wait for peer.pairing.completed (event already '
            'occurred). Use shepaw events ack --correlation $correlationId '
            'to clear inbox if subscribed.',
      }, correlationId);
    } on PairingRejectedException catch (e) {
      return {
        'success': false,
        'error': 'Pairing rejected by the other device',
        'reason': e.reason,
      };
    } on PairingTimeoutException {
      return {
        'success': false,
        'error':
            'Pairing timed out. Ensure the other device keeps its QR page open and confirms.',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Pairing failed: $e',
      };
    }
  }

  Map<String, dynamic> _invalidLinkError(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('shepaw://pair')) {
      return {
        'error':
            'This is an ACP agent enrollment link (shepaw://pair), not a device '
            'pairing link. Add it via Add Agent → scan QR or paste the pairing code.',
      };
    }
    try {
      parsePairDeeplink(trimmed);
      return {
        'error':
            'Parsed as shepaw://pair (agent enrollment). Use Add Agent in the UI, '
            'not peer pair.',
      };
    } catch (_) {}
    return {
      'error':
          'Invalid device pairing link. Expected shepaw://peer?local=...&code=...#fp=...&pk=...',
    };
  }
}
