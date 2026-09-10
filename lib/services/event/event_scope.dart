/// Routing scope attached to every [EventEnvelope].
class EventScope {
  final String? channelId;
  final String? agentId;
  final String? peerId;
  final String? deviceId;
  final String? ownerId;

  const EventScope({
    this.channelId,
    this.agentId,
    this.peerId,
    this.deviceId,
    this.ownerId,
  });

  Map<String, dynamic> toJson() => {
        if (channelId != null) 'channel_id': channelId,
        if (agentId != null) 'agent_id': agentId,
        if (peerId != null) 'peer_id': peerId,
        if (deviceId != null) 'device_id': deviceId,
        if (ownerId != null) 'owner_id': ownerId,
      };

  factory EventScope.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const EventScope();
    return EventScope(
      channelId: json['channel_id'] as String?,
      agentId: json['agent_id'] as String?,
      peerId: json['peer_id'] as String?,
      deviceId: json['device_id'] as String?,
      ownerId: json['owner_id'] as String?,
    );
  }

  /// Whether [other] satisfies this filter (null filter field = wildcard).
  bool contains(EventScope other) {
    bool match(String? filter, String? value) =>
        filter == null || filter == '*' || filter == value;
    return match(channelId, other.channelId) &&
        match(agentId, other.agentId) &&
        match(peerId, other.peerId) &&
        match(deviceId, other.deviceId) &&
        match(ownerId, other.ownerId);
  }
}
