/// One pattern an agent is currently listening for (subscription or wait).
class AgentEventListenEntry {
  final String agentId;
  final AgentEventListenKind kind;
  final String pattern;
  final String? delivery;
  final String? correlationId;
  final DateTime? expiresAt;

  const AgentEventListenEntry({
    required this.agentId,
    required this.kind,
    required this.pattern,
    this.delivery,
    this.correlationId,
    this.expiresAt,
  });

  bool get isWait => kind == AgentEventListenKind.wait;
}

enum AgentEventListenKind { subscription, wait }
