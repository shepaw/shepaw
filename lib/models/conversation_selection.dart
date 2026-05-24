/// Immutable data class representing a selected conversation in the desktop
/// split-panel layout.
class ConversationSelection {
  final String? agentId;
  final String? agentName;
  final String? agentAvatar;
  final String? channelId;
  final String? groupFamilyId;

  /// P2P peer ID (for device-to-device chat)
  final String? peerId;

  /// When set, the chat screen should scroll to and highlight this message.
  final String? highlightMessageId;

  const ConversationSelection({
    this.agentId,
    this.agentName,
    this.agentAvatar,
    this.channelId,
    this.groupFamilyId,
    this.peerId,
    this.highlightMessageId,
  });

  /// Unique key used to force ChatScreen recreation via ValueKey.
  /// Includes highlightMessageId so that clicking different messages in the
  /// same channel still forces a fresh ChatScreen.
  String get key {
    final base = peerId ?? channelId ?? agentId ?? '';
    return highlightMessageId != null ? '$base#$highlightMessageId' : base;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationSelection &&
          agentId == other.agentId &&
          channelId == other.channelId &&
          groupFamilyId == other.groupFamilyId &&
          peerId == other.peerId;

  @override
  int get hashCode => Object.hash(agentId, channelId, groupFamilyId, peerId);
}
