import '../../models/channel.dart';

/// Pure admin gate for group-management mutations.
class GroupAdminGate {
  GroupAdminGate._();

  /// Returns an error message when [actorId] may not mutate [channel]; null if OK.
  static String? denyReason({
    required Channel? channel,
    required String channelId,
    required String actorId,
  }) {
    if (channel == null) {
      return 'Channel not found: $channelId';
    }
    if (!channel.isGroup) {
      return 'Not a group channel: $channelId';
    }
    if (actorId.trim().isEmpty) {
      return 'Permission denied: missing actor identity.';
    }
    if (!channel.isAdmin(actorId)) {
      final adminId = channel.adminAgentId;
      return 'Permission denied: only the group admin can perform this action. '
          'You are not the admin of "${channel.name}"'
          '${adminId != null ? ' (admin_id=$adminId)' : ''}.';
    }
    return null;
  }

  static bool canMutate({
    required Channel? channel,
    required String actorId,
  }) =>
      channel != null &&
      channel.isGroup &&
      actorId.trim().isNotEmpty &&
      channel.isAdmin(actorId);
}
