import 'dart:async';

import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';

/// The subset of [ACPAgentConnection] the interactive-response path needs.
///
/// Both the real ACP connection and the peer-backed shim ([PeerAcpConnection])
/// implement it, so `submitActionConfirmationResponse` /
/// `InteractiveResponseHandler` don't branch on protocol — they just call
/// `connection.submitResponse(...)` and the right transport is used.
abstract class AcpInteractiveConnection {
  String get agentId;
  bool get isConnected;
  bool get supportsAsyncConfirmation;

  Future<void> submitResponse({
    required String taskId,
    required String responseType,
    required Map<String, dynamic> responseData,
  });
}

/// Peer-backed interactive connection shim.
///
/// Peer agents have no ACP WebSocket (chat goes through
/// `PeerAgentClientService.sendChat`), so they aren't registered in the ACP
/// connection map. But tool-call approvals still need to be SUBMITTED back to
/// the hub when the user taps a verdict. This shim routes `submitResponse` to
/// the hub over the peer channel as `agent_approval_resp`; the hub relays it
/// as `agent.submitResponse` to its local agent.
///
/// Only the interactive path uses this (via `ChatService.getInteractiveConnection`);
/// ACP-specific surfaces (slash commands, reconnect, heartbeat) keep using the
/// concrete `ACPAgentConnection` and simply see `null` for peer agents.
class PeerAcpConnection implements AcpInteractiveConnection {
  @override
  final String agentId;
  final String peerId;

  PeerAcpConnection({required this.agentId, required this.peerId});

  @override
  bool get isConnected =>
      PeerConnectionManager.instance.connectedPeerIds.contains(peerId);

  /// Peer approval is in-band — the hub's agent turn blocks in
  /// `waitForResponse` until the phone replies — so it behaves like a SYNC
  /// (legacy blocking) agent, not an async-confirmation one.
  @override
  bool get supportsAsyncConfirmation => false;

  @override
  Future<void> submitResponse({
    required String taskId,
    required String responseType,
    required Map<String, dynamic> responseData,
  }) async {
    final approvalId = responseData['confirmation_id'] as String? ?? '';
    final selectedActionId = responseData['selected_action_id'] as String? ?? '';
    await PeerAgentClientService.instance.submitApproval(
      peerId: peerId,
      approvalId: approvalId,
      selectedActionId: selectedActionId,
    );
  }
}
