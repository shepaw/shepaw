import '../../../cli_base.dart';
import '../../../../services/group/group_management_service.dart';
import '../../../../services/she_service.dart';
import '../chat_agent_scope.dart';

/// shepaw chat group create — create a group with She as admin.
class GroupCreateCommand extends CliCommand {
  GroupCreateCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a group chat; She becomes admin by default';

  @override
  String get usage =>
      'shepaw chat group create --name "Team" [--agents "Coder,Researcher"] '
      '[--description "..."] [--system-prompt "..."]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'name': {
        'description': 'Group display name',
        'required': true,
        'type': 'string',
      },
      'agents': {
        'description':
            'Optional comma-separated agent names or ids to add as members '
            '(She is always included as admin)',
        'required': false,
        'type': 'string',
      },
      'description': {
        'description': 'Optional group purpose / description',
        'required': false,
        'type': 'string',
      },
      'purpose': {
        'description': 'Alias for --description',
        'required': false,
        'type': 'string',
      },
      'system-prompt': {
        'description': 'Optional system prompt for group members',
        'required': false,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name'];
    if (name == null || name.trim().isEmpty) {
      return {'error': 'Missing required flag: --name'};
    }
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final description = flags['description'] ?? flags['purpose'];
    final result = await _service.createGroup(
      name: name,
      actorId: actorId,
      agentRefs: GroupManagementService.parseAgentRefs(flags['agents']),
      description: description,
      systemPrompt: flags['system-prompt'] ?? flags['system_prompt'],
    );
    return result.toJson();
  }
}

/// shepaw chat group add — add an agent (admin only).
class GroupAddCommand extends CliCommand {
  GroupAddCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add an agent to a group (admin only — non-admins are denied)';

  @override
  String get usage =>
      'shepaw chat group add --channel <id> --agent <name|id> [--bio "..."]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'agent': {
        'description': 'Agent name or id to add',
        'required': true,
        'type': 'string',
      },
      'bio': {
        'description': 'Optional group-specific role description for the member',
        'required': false,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final agent = flags['agent']?.trim();
    if (agent == null || agent.isEmpty) {
      return {'error': 'Missing required flag: --agent'};
    }
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.addMember(
      channelId: channelId,
      agentRef: agent,
      actorId: actorId,
      groupBio: flags['bio'],
    );
    return result.toJson();
  }
}

/// shepaw chat group kick — remove an agent (admin only).
class GroupKickCommand extends CliCommand {
  GroupKickCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'kick';

  @override
  String get description =>
      'Remove an agent from a group (admin only — non-admins are denied)';

  @override
  String get usage =>
      'shepaw chat group kick --channel <id> --agent <name|id>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'agent': {
        'description': 'Agent name or id to remove',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final agent = flags['agent']?.trim();
    if (agent == null || agent.isEmpty) {
      return {'error': 'Missing required flag: --agent'};
    }
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.kickMember(
      channelId: channelId,
      agentRef: agent,
      actorId: actorId,
    );
    return result.toJson();
  }
}

/// shepaw chat group rename — rename a group (admin only).
class GroupRenameCommand extends CliCommand {
  GroupRenameCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'rename';

  @override
  String get description =>
      'Rename a group chat (admin only — non-admins are denied)';

  @override
  String get usage =>
      'shepaw chat group rename --channel <id> --name "New name"';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'name': {
        'description': 'New group display name',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final name = flags['name'];
    if (name == null || name.trim().isEmpty) {
      return {'error': 'Missing required flag: --name'};
    }
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.renameGroup(
      channelId: channelId,
      name: name,
      actorId: actorId,
    );
    return result.toJson();
  }
}

/// shepaw chat group set-bio — set/clear a member's role description (admin only).
class GroupSetBioCommand extends CliCommand {
  GroupSetBioCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'set-bio';

  @override
  String get description =>
      'Set or clear a member\'s role description in this group (admin only — '
      'non-admins are denied)';

  @override
  String get usage =>
      'shepaw chat group set-bio --channel <id> --agent <name|id> --bio "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'agent': {
        'description': 'Agent name or id whose role description to update',
        'required': true,
        'type': 'string',
      },
      'bio': {
        'description':
            'New group-specific role description; omit or pass empty to clear '
            '(falls back to the agent\'s default bio)',
        'required': false,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final agent = flags['agent']?.trim();
    if (agent == null || agent.isEmpty) {
      return {'error': 'Missing required flag: --agent'};
    }
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.setMemberGroupBio(
      channelId: channelId,
      agentRef: agent,
      actorId: actorId,
      groupBio: flags['bio'],
    );
    return result.toJson();
  }
}

/// shepaw chat group set-description — set/clear the group description (admin only).
class GroupSetDescriptionCommand extends CliCommand {
  GroupSetDescriptionCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'set-description';

  @override
  String get description =>
      'Set or clear this group\'s description (admin only — non-admins are denied)';

  @override
  String get usage =>
      'shepaw chat group set-description --channel <id> --description "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'description': {
        'description':
            'New group description; omit or pass empty to clear it',
        'required': false,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final description = flags['description'] ?? '';
    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.setGroupDescription(
      channelId: channelId,
      description: description,
      actorId: actorId,
    );
    return result.toJson();
  }
}

/// shepaw chat group set-config — batch-update group runtime settings (admin only).
///
/// Writable fields (all optional; pass at least one):
/// - `--system-prompt ""` — 群系统提示词（留空=清除）
/// - `--mention-mode adminOnly|allMembers`
/// - `--max-loop-rounds 30`（0 = 回默认 50）
/// - `--flow-mode true|false`、`--enable-stage-gate true|false`
///
/// Settings take effect from the next group message; already-forked She-bound
/// child sessions keep the values copied at fork time (no back-fill).
class GroupSetConfigCommand extends CliCommand {
  GroupSetConfigCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'set-config';

  @override
  String get description =>
      'Update this group\'s settings (system-prompt / mention-mode / '
      'max-loop-rounds / flow-mode / enable-stage-gate) — admin only; '
      'applies from the next group message';

  @override
  String get usage =>
      'shepaw chat group set-config --channel <id> '
      '[--system-prompt ""|--mention-mode adminOnly|allMembers|'
      '--max-loop-rounds 30|--flow-mode true|--enable-stage-gate true]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Group channel id (or rely on injected channel_id when already in that group)',
        'required': false,
        'type': 'string',
      },
      'system-prompt': {
        'description':
            'New system prompt for group members; pass empty string to clear',
        'required': false,
        'type': 'string',
      },
      'mention-mode': {
        'description': "Mention mode: 'adminOnly' or 'allMembers'",
        'required': false,
        'type': 'string',
      },
      'max-loop-rounds': {
        'description':
            'Max orchestration rounds (0 resets to the default 50)',
        'required': false,
        'type': 'int',
      },
      'flow-mode': {
        'description': 'Enable/disable Flow mode (true/false/1/0/yes/no)',
        'required': false,
        'type': 'boolean',
      },
      'enable-stage-gate': {
        'description':
            'Enable/disable the stage gate (true/false/1/0/yes/no)',
        'required': false,
        'type': 'boolean',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }

    // 兼容 `-` / `_` 键写法（与 GroupCreateCommand 读 system-prompt 同款）。
    final systemPrompt = flags['system-prompt'] ?? flags['system_prompt'];
    final mentionMode = flags['mention-mode'] ?? flags['mention_mode'];
    final maxLoopRoundsRaw =
        flags['max-loop-rounds'] ?? flags['max_loop_rounds'];
    final flowModeRaw = flags['flow-mode'] ?? flags['flow_mode'];
    final enableStageGateRaw =
        flags['enable-stage-gate'] ?? flags['enable_stage_gate'];

    if (systemPrompt == null &&
        mentionMode == null &&
        maxLoopRoundsRaw == null &&
        flowModeRaw == null &&
        enableStageGateRaw == null) {
      return {
        'error': 'At least one setting flag is required: --system-prompt, '
            '--mention-mode, --max-loop-rounds, --flow-mode, '
            '--enable-stage-gate',
      };
    }

    int? maxLoopRounds;
    if (maxLoopRoundsRaw != null) {
      maxLoopRounds = int.tryParse(maxLoopRoundsRaw.trim());
      if (maxLoopRounds == null || maxLoopRounds < 0) {
        return {
          'error': 'Invalid --max-loop-rounds: "$maxLoopRoundsRaw" '
              '(expected an integer >= 0; 0 resets to the default 50)',
        };
      }
    }

    final bool? flowMode = parseBoolFlag(flowModeRaw);
    if (flowModeRaw != null && flowMode == null) {
      return {
        'error': 'Invalid --flow-mode: "$flowModeRaw" '
            '(expected true/false/1/0/yes/no)',
      };
    }
    final bool? enableStageGate = parseBoolFlag(enableStageGateRaw);
    if (enableStageGateRaw != null && enableStageGate == null) {
      return {
        'error': 'Invalid --enable-stage-gate: "$enableStageGateRaw" '
            '(expected true/false/1/0/yes/no)',
      };
    }

    if (mentionMode != null &&
        !const {'adminOnly', 'allMembers'}.contains(mentionMode.trim())) {
      return {
        'error': 'Invalid --mention-mode: "$mentionMode" '
            '(expected adminOnly | allMembers)',
      };
    }

    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.updateGroupSettings(
      channelId: channelId,
      actorId: actorId,
      systemPrompt: systemPrompt,
      mentionMode: mentionMode?.trim(),
      maxLoopRounds: maxLoopRounds,
      flowMode: flowMode,
      enableStageGate: enableStageGate,
    );
    return result.toJson();
  }

  /// 布尔 flag 解析：`'' / true / 1 / yes → true`，`false / 0 / no → false`。
  /// 空串视为 true（CLI 无值布尔 flag），其余非法值返回 null。
  static bool? parseBoolFlag(String? raw) {
    if (raw == null) return null;
    switch (raw.trim().toLowerCase()) {
      case '':
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
      default:
        return null;
    }
  }
}

/// shepaw chat group send — post into a She-bound group session (admin only).
class GroupSendCommand extends CliCommand {
  GroupSendCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'send';

  @override
  String get description =>
      'Send a message to a group you admin via a She-bound group session '
      '(does not affect the group\'s current open chat)';

  @override
  String get usage =>
      'shepaw chat group send --channel <id> --message "requirement..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description':
            'Target group channel id (any session in the family, or the parent id)',
        'required': true,
        'type': 'string',
      },
      'message': {
        'description': 'Requirement / message text to post into the bound group session',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    // Target group: prefer explicit --channel; do NOT fall back to injected
    // channel_id (that is the She DM when called from a She conversation).
    final channelId = flags['channel']?.trim();
    if (channelId == null || channelId.isEmpty) {
      return {
        'error':
            'Missing --channel. List groups with `shepaw chat channels --type group`.',
      };
    }
    final message = flags['message'];
    if (message == null || message.trim().isEmpty) {
      return {'error': 'Missing required flag: --message'};
    }

    // She session that triggered the send (injected when She runs CLI).
    final sheChannelId = flags['channel_id']?.trim() ?? '';
    if (sheChannelId.isEmpty) {
      return {
        'error':
            'Cannot determine the current She session. Run group send from a She conversation.',
      };
    }

    final actorId = ChatAgentScope.agentId.isNotEmpty
        ? ChatAgentScope.agentId
        : SheService.sheId;
    final result = await _service.sendToGroup(
      channelId: channelId,
      message: message,
      actorId: actorId,
      sheChannelId: sheChannelId,
    );
    return result.toJson();
  }
}
