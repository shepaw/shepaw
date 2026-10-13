import '../../peer/services/peer_agent_client_service.dart';

/// Live probe snapshot for one member before [group_dispatch] delegation.
class MemberCapabilitySnapshot {
  const MemberCapabilitySnapshot({
    required this.reachable,
    this.storeCliAvailable,
    this.notes = const [],
  });

  /// Agent / tunnel reachable at dispatch time.
  final bool reachable;

  /// `true`/`false` when probed; `null` when not applicable or inconclusive.
  final bool? storeCliAvailable;

  /// Human-readable probe notes for delivery hints / results.json.
  final List<String> notes;

  Map<String, dynamic> toDeliveryExtras() => {
        'reachable': reachable,
        if (storeCliAvailable != null) 'store_cli_live': storeCliAvailable,
        if (notes.isNotEmpty) 'probe_notes': notes,
      };
}

/// Preflight member capability checks before group dispatch.
///
/// Combines connectivity ([RemoteAgentService.checkAgentHealth]), Hub peer
/// runtime metadata, and a best-effort `hub.cli.execute store list` when an
/// ACP connection is already warm.
typedef MemberHealthCheck = Future<bool> Function(
  String agentId, {
  Duration timeout,
});

/// Live Hub roster + `/api/v1/health` via peer `agent_manage list`.
typedef PeerHubManageLister = Future<PeerAgentManageResult> Function(
  String peerId,
);
