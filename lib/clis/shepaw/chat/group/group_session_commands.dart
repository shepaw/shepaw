import 'dart:convert';

import '../../../../peer/services/hub_session_create.dart';
import '../../../../services/group/group_management_service.dart';
import '../../../../storage/store_uri_reader.dart';
import '../../../cli_base.dart';
import '../chat_agent_scope.dart';

/// shepaw chat group session create — 把建群会话交给主机，App 不再本地建。
class GroupSessionCreateCommand extends CliCommand {
  GroupSessionCreateCommand({HubSessionCreate? host})
      : _host = host ?? HubSessionCreate();

  final HubSessionCreate _host;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a group session on the host with a curated handoff package';

  @override
  String get usage =>
      'shepaw chat group session create --reason topic_shift '
      '--handoff-json \'{"task":{"user_goal":"...","acceptance_criteria":["..."],"status":"in_progress"}}\' '
      '[--reason-detail "..."] [--handoff-uri pouch://...] [--no-first-message]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description': 'Group channel id (defaults to injected channel_id)',
        'required': false,
        'type': 'string',
      },
      'group-id': {
        'description': 'Host group id (defaults to the channel id)',
        'required': false,
        'type': 'string',
      },
      'reason': {
        'description':
            'topic_shift | post_delivery | noise_reduction | context_too_long | agent_memory_reset | parallel_track | user_requested',
        'required': true,
        'type': 'string',
      },
      'reason-detail': {
        'description': 'Human-readable reason for the user',
        'required': false,
        'type': 'string',
      },
      'handoff-json': {
        'description':
            'Inline handoff JSON (task.user_goal, acceptance_criteria, status)',
        'required': false,
        'type': 'string',
      },
      'handoff-uri': {
        'description': 'Existing handoff JSON store URI (alternative to handoff-json)',
        'required': false,
        'type': 'string',
      },
      'no-first-message': {
        'description': 'Skip writing the handoff summary into the new session',
        'required': false,
        'type': 'boolean',
      },
      'no-switch-card': {
        'description': 'Do not mark the session action as pending switch',
        'required': false,
        'type': 'boolean',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channelId = GroupManagementService.resolveChannelId(flags);
    if (channelId == null || channelId.isEmpty) {
      return {
        'error': 'Missing --channel or channel_id (must run inside a group)',
      };
    }
    final groupId = (flags['group-id'] ?? flags['group_id'] ?? channelId).trim();

    final reason = flags['reason']?.trim();
    if (reason == null || reason.isEmpty) {
      return {'error': 'Missing required flag: --reason'};
    }

    final handoffJson = flags['handoff-json'] ?? flags['handoff_json'];
    final handoffUri = flags['handoff-uri'] ?? flags['handoff_uri'];
    if ((handoffJson == null || handoffJson.trim().isEmpty) &&
        (handoffUri == null || handoffUri.trim().isEmpty)) {
      return {
        'error': 'Provide --handoff-json or --handoff-uri',
      };
    }

    Map<String, dynamic>? inlineHandoff;
    if (handoffJson != null && handoffJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(handoffJson);
        if (decoded is! Map) {
          return {'error': '--handoff-json must be a JSON object'};
        }
        inlineHandoff = Map<String, dynamic>.from(decoded);
      } catch (e) {
        return {'error': 'Invalid --handoff-json: $e'};
      }
    } else if (handoffUri != null && handoffUri.trim().isNotEmpty) {
      // 主机不读 pouch://，App 在这里把交接包读成对象再带上，内容才不会丢。
      try {
        final bytes = await StoreUriReader.instance.read(handoffUri.trim());
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          inlineHandoff = Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        return {'error': 'Failed to read --handoff-uri: $e'};
      }
    }
    if (inlineHandoff == null) {
      return {'error': 'Provide --handoff-json or --handoff-uri'};
    }

    // HubCliExecute 会把身份字段从 flags 里剥掉，注入到 Zone。群 admin
    //（通常是 She）执行时必须回退到 ChatAgentScope，否则拿不到 actor。
    final actorId = (flags['agent_id']?.trim().isNotEmpty == true)
        ? flags['agent_id']!.trim()
        : ((flags['owner']?.trim().isNotEmpty == true)
            ? flags['owner']!.trim()
            : ChatAgentScope.agentId.trim());
    if (actorId.isEmpty) {
      return {'error': 'Missing executor agent id'};
    }
    final actorName = (flags['agent_name']?.trim().isNotEmpty == true)
        ? flags['agent_name']!.trim()
        : actorId;
    final task = inlineHandoff['task'];
    final goal = task is Map
        ? task['user_goal']?.toString().trim() ?? ''
        : '';

    return _host.create(<String, dynamic>{
      'kind': 'group',
      'group_id': groupId,
      'channel_id': channelId,
      'agent_id': actorId,
      'agent_name': actorName,
      'reason': reason,
      if (flags['reason-detail']?.trim().isNotEmpty == true)
        'reason_detail': flags['reason-detail']!.trim(),
      if (goal.isNotEmpty) 'summary': goal,
      'handoff': inlineHandoff,
      if (handoffUri != null && handoffUri.trim().isNotEmpty)
        'handoff_uri': handoffUri.trim(),
      'post_first_message': flags['no-first-message'] != 'true',
      'suggest_switch': flags['no-switch-card'] != 'true',
    });
  }
}
