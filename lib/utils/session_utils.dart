import '../models/channel.dart';

/// Utility functions for session/channel ID display.
class SessionUtils {
  SessionUtils._();

  /// Extract a short session identifier from a channelId for display.
  ///
  /// For group channels, optionally pass [groupChannel] to detect the default session.
  static String shortSessionId(String channelId, {Channel? groupChannel}) {
    // Group channels: use creation time from channel object if available
    if (groupChannel != null && groupChannel.isGroup) {
      if (groupChannel.parentGroupId == null && channelId == groupChannel.id) {
        return '#default';
      }
    }
    // Synced peer session: id is `psess_<remoteSessionId>` (see
    // kSyncedPeerSessionPrefix). Show the tail of the bound remote session id.
    const peerPrefix = 'psess_';
    if (channelId.startsWith(peerPrefix)) {
      final sid = channelId.substring(peerPrefix.length);
      final tail = sid.length > 6 ? sid.substring(sid.length - 6) : sid;
      return '#$tail';
    }
    // channelId format: dm_userId_agentId or dm_userId_agentId_timestamp
    //                   group_<uuid>
    final parts = channelId.split('_');
    if (parts.length > 3) {
      // DM with timestamp suffix
      return '#${parts.last.substring(parts.last.length > 6 ? parts.last.length - 6 : 0)}';
    }
    if (channelId.startsWith('group_') && parts.length == 2) {
      // group_<uuid> - show last 6 chars of uuid
      final uuid = parts[1];
      return '#${uuid.substring(uuid.length > 6 ? uuid.length - 6 : 0)}';
    }
    return '#default';
  }
}
