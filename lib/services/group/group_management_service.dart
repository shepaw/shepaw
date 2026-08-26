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

  /// M13d: 每频道成员变更尾随链——addMember/kickMember 的 read-modify-write
  /// 序列（channel_members → 工作空间成员表 → peer ACL）并发交错会留下幽灵
  /// 成员（例如 add 的 grantPeerAccess 晚于 kick 的 revokePeerAccess）。用
  /// 同一频道的 future 链串行化，任何时刻该频道最多一个成员变更在跑。
  final Map<String, Future<GroupManagementResult>> _memberMutationTail = {};

  /// 串行执行一次成员变更；失败不打断链（下一条照常排队）。
  Future<GroupManagementResult> _runSerializedMemberMutation(
    String channelId,
    Future<GroupManagementResult> Function() action,
  ) {
    final prev = _memberMutationTail[channelId] ??
        Future.value(GroupManagementResult.success());
    final next = prev.then((_) => action());
    _memberMutationTail[channelId] = next.catchError(
      (_) => GroupManagementResult.failure('group mutation chain error'),
    );
    return next;
  }

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

    try {
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
            (agentId: m.id,
                role: m.id == SheService.sheId ? 'admin' : 'member'),
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
    } catch (e) {
      // M13e: 中途失败删除已建 channel 与成员会话，不把半成品群当成功返回。
      try {
        await _db.deleteChannel(channelId);
        await GroupMemberSessionService(_db)
            .deleteMemberSessionsForGroupChannel(channelId);
      } catch (rollbackErr) {
        LoggerService().warning(
          'createGroup rollback incomplete: $rollbackErr',
          tag: _tag,
        );
      }
      LoggerService().error(
        'createGroup failed, rolled back: $e',
        tag: _tag,
      );
      return GroupManagementResult.failure('创建群失败：$e');
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
  }) {
    return _runSerializedMemberMutation(channelId, () async {
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
      try {
        await _db.addChannelMember(
          channelId,
          agent.id,
          role: 'member',
          groupBio:
              groupBio?.trim().isNotEmpty == true ? groupBio!.trim() : null,
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
      } catch (e) {
        // M13e: 中途失败回滚 channel_members / workspace / ACL，不留半成品
        //（例如 channel 已加成员但 workspace 未加）。
        await _rollbackAddMember(
          channelId: channelId,
          agentId: agent.id,
          familyId: channel.groupFamilyId,
          peerId: agent.sourcePeerId,
        );
        LoggerService().error(
          'addMember(${agent.name}) failed, rolled back: $e',
          tag: _tag,
        );
        return GroupManagementResult.failure('添加成员失败：$e');
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
    });
  }

  /// M13e: addMember 失败后的补偿——把已写入的 channel_members 行、工作空间
  /// 成员项和 peer ACL 条目一并撤掉。各步骤幂等，重复调用安全。
  Future<void> _rollbackAddMember({
    required String channelId,
    required String agentId,
    required String familyId,
    String? peerId,
  }) async {
    try {
      await _db.removeChannelMember(channelId, agentId);
      await GroupWorkspaceService.instance.removeMember(
        groupId: familyId,
        agentId: agentId,
      );
      if (peerId != null && peerId.isNotEmpty) {
        await GroupWorkspaceService.instance.revokePeerAccess(
          groupId: familyId,
          agentId: agentId,
          peerId: peerId,
        );
      }
    } catch (rollbackErr) {
      LoggerService().warning(
        'addMember rollback incomplete: $rollbackErr',
        tag: _tag,
      );
    }
  }

  Future<GroupManagementResult> kickMember({
    required String channelId,
    required String agentRef,
    required String actorId,
  }) {
    return _runSerializedMemberMutation(channelId, () async {
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

      // 保留原成员角色/bio 以便中途失败时恢复。
      ChannelMember? member;
      for (final m in channel.members) {
        if (m.id == agent.id) {
          member = m;
          break;
        }
      }

      try {
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
        // 回收 peer 成员设备的群工作空间访问（members/<agentId>/ 条目）。
        final peerId = agent.sourcePeerId;
        if (peerId != null && peerId.isNotEmpty) {
          await GroupWorkspaceService.instance.revokePeerAccess(
            groupId: channel.groupFamilyId,
            agentId: agent.id,
            peerId: peerId,
          );
        }
      } catch (e) {
        // M13e: 中途失败恢复 channel_members（工作空间/ACL 步骤幂等，下一次
        // add/kick 会重新对齐），不把「已移除但失败」当成成功返回。
        try {
          await _db.addChannelMember(
            channelId,
            agent.id,
            role: member?.role ?? 'member',
            groupBio: member?.groupBio,
          );
        } catch (restoreErr) {
          LoggerService().warning(
            'kickMember restore failed: $restoreErr',
            tag: _tag,
          );
        }
        LoggerService().error(
          'kickMember(${agent.name}) failed, restored: $e',
          tag: _tag,
        );
        return GroupManagementResult.failure('移除成员失败：$e');
      }

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
    });
  }

  /// Set (or clear) a member's group-specific role description (groupBio)
  /// across every session in the group family.
  ///
  /// Permission model: the group admin and She may update any member; a regular
  /// member may update only their own role description.
  ///
  /// [groupBio] empty / null clears the member's role description, falling back
  /// to the agent's own default bio. Mirrors the UI path
  /// `saveMemberGroupBio` in `chat_controller_group_members.dart`.
  Future<GroupManagementResult> setMemberGroupBio({
    required String channelId,
    required String agentRef,
    required String actorId,
    String? groupBio,
  }) async {
    final channel = await _db.getChannelById(channelId);
    if (channel == null) {
      return GroupManagementResult.failure('Channel not found: $channelId');
    }

    final agent = await resolveAgent(agentRef);
    if (agent == null) {
      return GroupManagementResult.failure('Agent not found: $agentRef');
    }
    if (!channel.agentIds.contains(agent.id)) {
      return GroupManagementResult.failure(
        '${agent.name} is not a member of this group.',
      );
    }

    // 权限：管理员/She 可改任意成员；普通成员只能改自己的。
    final denied = GroupAdminGate.denyReasonForMemberBio(
      channel: channel,
      channelId: channelId,
      actorId: actorId,
      targetAgentId: agent.id,
    );
    if (denied != null) {
      LoggerService().warning(
        'setMemberGroupBio denied for actor=$actorId target=${agent.id}: $denied',
        tag: _tag,
      );
      return GroupManagementResult.failure(denied);
    }

    final bio = groupBio?.trim().isNotEmpty == true ? groupBio!.trim() : null;
    final sessions = await _db.getGroupSessions(channel.groupFamilyId);
    for (final session in sessions) {
      await _db.updateChannelMemberGroupBio(session.id, agent.id, bio);
    }
    _chat.notifyChannelUpdate(channelId);

    return GroupManagementResult.success({
      'channel_id': channelId,
      'group_family_id': channel.groupFamilyId,
      'agent': {'id': agent.id, 'name': agent.name},
      'group_bio': bio ?? '',
    });
  }

  /// Set (or clear) a group's description. Admin only.
  ///
  /// [description] empty / null clears the group description.
  Future<GroupManagementResult> setGroupDescription({
    required String channelId,
    required String description,
    required String actorId,
  }) async {
    final trimmed = description.trim();
    final gate = await _requireAdminGroup(channelId, actorId);
    if (gate.error != null) {
      return GroupManagementResult.failure(gate.error!);
    }
    final channel = gate.channel!;

    final updated = channel.copyWith(
      description: trimmed.isEmpty ? null : trimmed,
    );
    await _db.updateChannel(updated);
    _chat.notifyChannelUpdate(channelId);

    return GroupManagementResult.success({
      'channel_id': channelId,
      'description': updated.description ?? '',
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
