import '../../cli_base.dart';
import '../../../peer/services/peer_pairing_service.dart';
import 'peer_cli_helpers.dart';

/// 确认入站配对请求（Responder 侧，替代 UI 确认弹窗）。
class PeerAcceptCommand extends CliCommand {
  @override
  String get name => 'accept';

  @override
  String get description =>
      'Accept a pending inbound device pairing request';

  @override
  String get usage =>
      'shepaw peer accept [--trust owner|friend] [--agents all|none|id1,id2]';

  @override
  String? get icon => '✅';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'trust': {
        'description': 'Trust level for the paired device',
        'required': false,
        'type': 'string',
        'enum': ['owner', 'friend'],
        'default': 'owner',
      },
      'agents': {
        'description':
            'Agents to share: all (default), none, or comma-separated agent ids',
        'required': false,
        'type': 'string',
        'default': 'all',
      },
    };
    base['notes'] = [
      'Requires an active pairing session (peer offer) and a pending inbound request (peer status).',
      'Defaults match the UI confirm dialog: trust=owner, share all eligible local agents.',
    ];
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final svc = PeerPairingService.instance;
    final pending = svc.pendingIncomingRequest;
    if (pending == null) {
      return {
        'success': false,
        'error':
            'No pending inbound pairing request. Run peer status to check, '
            'or peer offer to start hosting.',
        'state': svc.state.name,
      };
    }

    final trustLevel = parsePeerTrustLevel(flags['trust']);
    try {
      final agentShares = await resolveAgentSharesForAccept(
        request: pending,
        agentsFlag: flags['agents'],
      );
      final storeShares = await resolveStoreSharesForAccept(
        request: pending,
        trustLevel: trustLevel,
      );

      final peer = await svc.confirmPairing(
        pending,
        agentShares: agentShares,
        storeShares: storeShares,
        trustLevel: trustLevel,
      );

      final correlationId = resolveContinuatorCorrelation();
      return withCorrelationId({
        'success': true,
        'message': 'Inbound pairing accepted',
        'peer': peer.toJson(),
        'trust_level': trustLevel,
        'shared_agent_count':
            agentShares?.values.where((v) => v).length ?? 0,
      }, correlationId);
    } catch (e) {
      return {
        'success': false,
        'error': 'Failed to accept pairing: $e',
        'state': svc.state.name,
      };
    }
  }
}
