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
