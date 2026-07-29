import 'package:uuid/uuid.dart';

import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import '../she_service.dart';
import 'group_admin_gate.dart';
import 'group_member_session_service.dart';

/// Result of a group-management CLI / service operation.
class GroupManagementResult {
  final bool ok;
  final String? error;
  final Map<String, dynamic> data;

  const GroupManagementResult._({
    required this.ok,
    this.error,
    this.data = const {},
  });

  factory GroupManagementResult.success([Map<String, dynamic> data = const {}]) =>
      GroupManagementResult._(ok: true, data: data);

  factory GroupManagementResult.failure(String error) =>
      GroupManagementResult._(ok: false, error: error);

  Map<String, dynamic> toJson() => ok
      ? {'status': 'ok', ...data}
      : {
          'error': error,
          if (error != null && error!.contains('Permission denied'))
            'permission_denied': true,
        };
}

/// Shared group create / member / rename operations for She CLI.
///
/// - [createGroup] is She-only and always installs She as admin.
/// - [addMember] / [kickMember] / [renameGroup] require [actorId] to be the
///   group's admin; non-admins always fail before any DB write.
class GroupManagementService {
  GroupManagementService({
    LocalDatabaseService? db,
    ChatService? chatService,
  })  : _db = db ?? LocalDatabaseService(),
        _chat = chatService ?? ChatService();

  final LocalDatabaseService _db;
  final ChatService _chat;
  static const _tag = 'GroupManagement';

  /// Resolve `--channel` / `--channel_id` (injected when already in a group).
  static String? resolveChannelId(Map<String, String> flags) {
    final explicit = flags['channel']?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final injected = flags['channel_id']?.trim();
    if (injected != null && injected.isNotEmpty) return injected;
    return null;
  }

  /// Split a comma / whitespace separated agent name-or-id list.
  static List<String> parseAgentRefs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(RegExp(r'[,，\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Look up an agent by exact id, else case-insensitive exact name.
  Future<RemoteAgent?> resolveAgent(String ref) async {
    final byId = await _db.getRemoteAgentById(ref);
    if (byId != null) return byId;
    final all = await _db.getAllRemoteAgents();
    final lower = ref.toLowerCase();
    for (final a in all) {
      if (a.name.toLowerCase() == lower) return a;
    }
    return null;
  }

  Future<List<RemoteAgent>> resolveAgents(List<String> refs) async {
    final out = <RemoteAgent>[];
    final seen = <String>{};
    for (final ref in refs) {
      final agent = await resolveAgent(ref);
      if (agent == null) {
        throw StateError('Agent not found: $ref');
      }
      if (seen.add(agent.id)) out.add(agent);
    }
    return out;
  }

  /// Create a group. Only [SheService.sheId] may create; She is always admin.
  Future<GroupManagementResult> createGroup({
    required String name,
    required String actorId,
    List<String> agentRefs = const [],
    String? description,
    String? systemPrompt,
    String? mentionMode,
    int? maxLoopRounds,
    String userId = LocalUserIdentity.id,
  }) async {
    if (actorId != SheService.sheId) {
      return GroupManagementResult.failure(
        'Permission denied: only She can create group chats via CLI.',
      );
    }

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return GroupManagementResult.failure('Missing required flag: --name');
    }

    List<RemoteAgent> extras;
    try {
      extras = await resolveAgents(agentRefs);
    } on StateError catch (e) {
      return GroupManagementResult.failure(e.message);
    }

    final she = await _db.getRemoteAgentById(SheService.sheId);
    if (she == null) {
      return GroupManagementResult.failure(
        'Built-in She agent is not available on this device.',
      );
    }

    final memberAgents = <RemoteAgent>[she];
    final seen = {she.id};
    for (final a in extras) {
      if (seen.add(a.id)) memberAgents.add(a);
    }

    final channelId = 'group_${const Uuid().v4()}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final members = <ChannelMember>[
      ChannelMember(
        id: userId,
        type: 'user',
        role: 'member',
        joinedAt: now,
      ),
      ...memberAgents.map(
        (a) => ChannelMember(
          id: a.id,
          type: 'agent',
          // Creator (She) is always admin; never promote others via create.
          role: a.id == SheService.sheId ? 'admin' : 'member',
          joinedAt: now,
        ),
      ),
    ];

    final channel = Channel(
      id: channelId,
      name: trimmed,
      type: 'group',
      members: members,
      description: description?.trim().isNotEmpty == true
          ? description!.trim()
          : null,
      systemPrompt: systemPrompt?.trim().isNotEmpty == true
          ? systemPrompt!.trim()
          : null,
      maxLoopRounds: maxLoopRounds,
      mentionMode: mentionMode,
      isPrivate: true,
    );

    if (!channel.isAdmin(SheService.sheId)) {
      return GroupManagementResult.failure(
        'Internal error: createGroup failed to assign She as admin.',
      );
    }

    await _db.createChannel(channel, userId);
    await GroupMemberSessionService(_db).ensureMemberSessionsForGroup(
      groupChannel: channel,
      userId: userId,
    );
    _chat.notifyChannelUpdate(channelId);

    LoggerService().info(
      'Created group $channelId "${channel.name}" with admin=She, '
      'members=${memberAgents.map((a) => a.name).join(", ")}',
      tag: _tag,
    );

    return GroupManagementResult.success({
      'channel_id': channelId,
      'name': channel.name,
      'admin': she.name,
      'admin_id': she.id,
      'members': memberAgents
          .map((a) => {
                'id': a.id,
                'name': a.name,
                'role': a.id == SheService.sheId ? 'admin' : 'member',
              })
          .toList(),
      if (channel.description != null) 'description': channel.description,
    });
  }

  Future<GroupManagementResult> addMember({
    required String channelId,
    required String agentRef,
    required String actorId,
    String? groupBio,
    String userId = LocalUserIdentity.id,
  }) async {
    final gate = await _requireAdminGroup(channelId, actorId);
    if (gate.error != null) {
      return GroupManagementResult.failure(gate.error!);
    }
    final channel = gate.channel!;

    final agent = await resolveAgent(agentRef);
    if (agent == null) {
      return GroupManagementResult.failure('Agent not found: $agentRef');
    }
    if (channel.agentIds.contains(agent.id)) {
      return GroupManagementResult.failure(
        '${agent.name} is already a member of this group.',
      );
    }

    // New members are never admin; admin cannot be granted via add.
    await _db.addChannelMember(
      channelId,
      agent.id,
      role: 'member',
      groupBio: groupBio?.trim().isNotEmpty == true ? groupBio!.trim() : null,
    );

    final refreshed = await _db.getChannelById(channelId);
    if (refreshed != null) {
      await GroupMemberSessionService(_db).ensureMemberSession(
        groupChannel: refreshed,
        agentId: agent.id,
        userId: userId,
      );
    }

    await _chat.notifyGroupMembershipChange(
      channelId,
      agent.id,
      agent.name,
      isJoin: true,
    );

    return GroupManagementResult.success({
      'channel_id': channelId,
      'added': {'id': agent.id, 'name': agent.name, 'role': 'member'},
    });
  }

  Future<GroupManagementResult> kickMember({
    required String channelId,
    required String agentRef,
    required String actorId,
  }) async {
    final gate = await _requireAdminGroup(channelId, actorId);
    if (gate.error != null) {
      return GroupManagementResult.failure(gate.error!);
    }
    final channel = gate.channel!;

    final agent = await resolveAgent(agentRef);
    if (agent == null) {
      return GroupManagementResult.failure('Agent not found: $agentRef');
    }
    if (!channel.agentIds.contains(agent.id)) {
      return GroupManagementResult.failure(
        '${agent.name} is not a member of this group.',
      );
    }
    if (agent.id == actorId || channel.isAdmin(agent.id)) {
      return GroupManagementResult.failure(
        'Cannot kick the group admin. Transfer admin first or leave via UI.',
      );
    }
    if (channel.agentIds.length <= 1) {
      return GroupManagementResult.failure(
        'Cannot remove the last agent from the group.',
      );
    }

    await _db.removeChannelMember(channelId, agent.id);
    await GroupMemberSessionService(_db).deleteMemberSession(
      groupChannelId: channelId,
      agentId: agent.id,
    );

    await _chat.notifyGroupMembershipChange(
      channelId,
      agent.id,
      agent.name,
      isJoin: false,
    );

    return GroupManagementResult.success({
      'channel_id': channelId,
      'removed': {'id': agent.id, 'name': agent.name},
    });
  }

  Future<GroupManagementResult> renameGroup({
    required String channelId,
    required String name,
    required String actorId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return GroupManagementResult.failure('Missing required flag: --name');
    }

    final gate = await _requireAdminGroup(channelId, actorId);
    if (gate.error != null) {
      return GroupManagementResult.failure(gate.error!);
    }
    final channel = gate.channel!;

    final updated = channel.copyWith(name: trimmed);
    await _db.updateChannel(updated);
    await GroupMemberSessionService(_db).syncTitlesForGroupFamily(
      parentGroupId: updated.groupFamilyId,
      groupName: trimmed,
    );
    _chat.notifyChannelUpdate(channelId);

    return GroupManagementResult.success({
      'channel_id': channelId,
      'name': trimmed,
      'previous_name': channel.name,
    });
  }

  /// Loads the channel and denies unless [actorId] is its admin.
  Future<({Channel? channel, String? error})> _requireAdminGroup(
    String channelId,
    String actorId,
  ) async {
    final channel = await _db.getChannelById(channelId);
    final denied = GroupAdminGate.denyReason(
      channel: channel,
      channelId: channelId,
      actorId: actorId,
    );
    if (denied != null) {
      LoggerService().warning(
        'Group mutation denied for actor=$actorId channel=$channelId: $denied',
        tag: _tag,
      );
      return (channel: null, error: denied);
    }
    return (channel: channel, error: null);
  }
}
