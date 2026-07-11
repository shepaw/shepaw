import '../models/channel.dart';

/// Pure helpers for resolving "source device" labels on peer-related chats.
class PeerDeviceLabelResolver {
  PeerDeviceLabelResolver._();

  static const channelNameSep = ' ← ';

  /// Extract `peer:{peerId}` member id payload.
  static String? peerIdFromMembers(Iterable<ChannelMember> members) {
    for (final m in members) {
      if (m.id.startsWith('peer:')) {
        return m.id.substring('peer:'.length);
      }
    }
    return null;
  }

  /// Fallback label from channel names like `Agent ← Device`.
  static String? labelFromChannelName(
    String name, {
    String sep = channelNameSep,
  }) {
    final idx = name.lastIndexOf(sep);
    if (idx < 0) return null;
    final label = name.substring(idx + sep.length).trim();
    return label.isEmpty ? null : label;
  }

  /// Look up a paired device display name by peer id.
  static String? deviceNameById(
    Iterable<({String id, String deviceName})> peers,
    String? peerId,
  ) {
    if (peerId == null || peerId.isEmpty) return null;
    for (final p in peers) {
      if (p.id == peerId && p.deviceName.isNotEmpty) return p.deviceName;
    }
    return null;
  }

  /// Host inbound (`peer__…`) session label: live peer name, else channel suffix.
  static String? hostInboundLabel({
    required Channel channel,
    required Iterable<({String id, String deviceName})> peers,
  }) {
    final byId = deviceNameById(peers, peerIdFromMembers(channel.members));
    return byId ?? labelFromChannelName(channel.name);
  }

  /// Prefer channel agent member; else constructor [fallbackAgentId].
  static String? clientAgentId({
    required Channel? channel,
    required String? fallbackAgentId,
  }) {
    final agentMembers =
        channel?.members.where((m) => m.isAgent).toList() ?? const [];
    if (agentMembers.isNotEmpty) return agentMembers.first.id;
    return fallbackAgentId;
  }

  /// Client DM label for a peer-shared agent.
  static String? clientPeerAgentLabel({
    required bool isPeerAgent,
    required String? sourcePeerId,
    required String? sourcePeerNameSnapshot,
    required Iterable<({String id, String deviceName})> peers,
  }) {
    if (!isPeerAgent) return null;
    final byId = deviceNameById(peers, sourcePeerId);
    if (byId != null) return byId;
    if (sourcePeerNameSnapshot != null && sourcePeerNameSnapshot.isNotEmpty) {
      return sourcePeerNameSnapshot;
    }
    return null;
  }
}
