import '../../models/channel.dart';
import '../she_service.dart';

/// Pure admin gate for group-management mutations.
///
/// Permission model:
/// - Full permissions (admin operations) → the group admin, or She (the
///   built-in agent), who is granted all group-management permissions.
/// - Member-bio updates (`setMemberGroupBio`) → full-permission actors may
///   update anyone; a regular member may update only their own.
class GroupAdminGate {
  GroupAdminGate._();

  /// True when [actorId] has full group-management permissions on [channel]:
  /// the group admin, or She (granted all group permissions).
  static bool hasFullPermissions(Channel channel, String actorId) {
    return channel.isAdmin(actorId) || actorId == SheService.sheId;
  }

  /// Returns an error message when [actorId] may not perform a full-permission
  /// group mutation on [channel]; null if OK.
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
    if (!hasFullPermissions(channel, actorId)) {
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
      hasFullPermissions(channel, actorId);

  /// Returns an error message when [actorId] may not update [targetAgentId]'s
  /// group role description on [channel]; null if OK.
  ///
  /// Full-permission actors (admin / She) may update anyone; a regular member
  /// may update only their own role description.
  static String? denyReasonForMemberBio({
    required Channel? channel,
    required String channelId,
    required String actorId,
    required String targetAgentId,
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
    if (hasFullPermissions(channel, actorId)) return null;
    if (actorId == targetAgentId) return null; // 普通成员可改自己的职责
    return 'Permission denied: you may only update your own group role '
        'description in "${channel.name}".';
  }

  static bool canMutateMemberBio({
    required Channel? channel,
    required String actorId,
    required String targetAgentId,
  }) =>
      channel != null &&
      channel.isGroup &&
      actorId.trim().isNotEmpty &&
      (hasFullPermissions(channel, actorId) || actorId == targetAgentId);
}
