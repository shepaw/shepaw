import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import '../she_service.dart';
import '../../storage/group_workspace_service.dart';
import 'group_admin_gate.dart';
import 'group_member_session_service.dart';
import 'she_group_approval_bridge.dart';

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
    SheGroupApprovalBridge? approvalBridge,
  })  : _db = db ?? LocalDatabaseService(),
        _chat = chatService ?? ChatService(),
        _approvalBridge = approvalBridge ??
            SheGroupApprovalBridge(
              db: db,
              chatService: chatService,
            );

  final LocalDatabaseService _db;
  final ChatService _chat;
  final SheGroupApprovalBridge _approvalBridge;
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
    // 初始化群工作空间（骨架 + 成员表；She 恒为 admin）。
    await GroupWorkspaceService.instance.ensureGroupWorkspace(
      groupId: channelId,
      members: [
        for (final m in memberAgents)
          (agentId: m.id, role: m.id == SheService.sheId ? 'admin' : 'member'),
      ],
    );
    // 跨设备 ACL：peer 来源成员设备自动获得群工作空间访问白名单。
    for (final m in memberAgents) {
      final peerId = m.sourcePeerId;
      if (peerId != null && peerId.isNotEmpty) {
        await GroupWorkspaceService.instance.grantPeerAccess(
          groupId: channelId,
          agentId: m.id,
          peerId: peerId,
        );
      }
    }
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

    // 新成员进入群工作空间成员表（空间按群家族归属）。
    await GroupWorkspaceService.instance.upsertMember(
      groupId: channel.groupFamilyId,
      agentId: agent.id,
      role: 'member',
    );
    // 跨设备 ACL：peer 来源成员设备自动获得群工作空间访问白名单。
    final peerId = agent.sourcePeerId;
    if (peerId != null && peerId.isNotEmpty) {
      await GroupWorkspaceService.instance.grantPeerAccess(
        groupId: channel.groupFamilyId,
        agentId: agent.id,
        peerId: peerId,
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

    // 移出群工作空间成员表（只更新元数据，不删成员文件）。
    await GroupWorkspaceService.instance.removeMember(
      groupId: channel.groupFamilyId,
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

  /// Send a message into a She-bound group session (external trigger).
  ///
  /// Requires [actorId] to be the group admin. Uses [sheChannelId] (She↔user
  /// DM) to ensure/create a dedicated group session so the group's current
  /// chat is not affected. Orchestration reuses [ChatService.sendMessageToGroup].
  Future<GroupManagementResult> sendToGroup({
    required String channelId,
    required String message,
    required String actorId,
    required String sheChannelId,
    String userId = LocalUserIdentity.id,
    String userName = LocalUserIdentity.displayName,
  }) async {
    final content = message.trim();
    if (content.isEmpty) {
      return GroupManagementResult.failure('Missing required flag: --message');
    }
    if (sheChannelId.trim().isEmpty) {
      return GroupManagementResult.failure(
        'Missing She session channel_id. Run group send from a She conversation.',
      );
    }

    final gate = await _requireAdminGroup(channelId, actorId);
    if (gate.error != null) {
      return GroupManagementResult.failure(gate.error!);
    }
    final channel = gate.channel!;

    final String boundChannelId;
    try {
      boundChannelId = await _chat.ensureSheBoundGroupSession(
        channelId: channel.id,
        sheChannelId: sheChannelId,
        userId: userId,
      );
    } catch (e) {
      return GroupManagementResult.failure(
        'Failed to open She-bound group session: $e',
      );
    }

    final bound = await _db.getChannelById(boundChannelId);
    if (bound == null) {
      return GroupManagementResult.failure(
        'Bound group session not found: $boundChannelId',
      );
    }
    final agentIds = bound.agentIds;
    if (agentIds.isEmpty) {
      return GroupManagementResult.failure(
        'Group has no agent members to notify.',
      );
    }

    final groupName = bound.name;
    unawaited(() async {
      try {
        await _chat.sendMessageToGroup(
          channelId: boundChannelId,
          content: content,
          userId: userId,
          userName: userName,
          agentIds: agentIds,
          adminAgentId: bound.adminAgentId,
          flowMode: bound.flowMode,
          onInteractionRequest: (agentId, agentName, interactionType, data) =>
              _approvalBridge.handleInteraction(
            sheChannelId: sheChannelId,
            groupChannelId: boundChannelId,
            groupName: groupName,
            agentId: agentId,
            agentName: agentName,
            interactionType: interactionType,
            data: data,
          ),
        );
      } catch (e, st) {
        LoggerService().error(
          'She group send orchestration failed for $boundChannelId',
          tag: _tag,
          error: e,
          stackTrace: st,
        );
      }
    }());

    LoggerService().info(
      'She group send queued: she=$sheChannelId → bound=$boundChannelId '
      '(family=${bound.groupFamilyId})',
      tag: _tag,
    );

    return GroupManagementResult.success({
      'channel_id': boundChannelId,
      'group_family_id': bound.groupFamilyId,
      'group_name': groupName,
      'she_channel_id': sheChannelId,
      'note':
          'Message posted to a She-bound group session; orchestration started. '
          'Approvals appear in that group session; a jump notice will be '
          'injected here when master review is needed.',
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
