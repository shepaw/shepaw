import 'dart:convert';

import '../../../../peer/services/hub_session_create.dart';
import '../../../../services/group/group_management_service.dart';
import '../../../cli_base.dart';
import '../chat_agent_scope.dart';

/// shepaw chat session create — 把建会话交给主机，App 不再本地建。
class ChatSessionCreateCommand extends CliCommand {
  ChatSessionCreateCommand({HubSessionCreate? host})
      : _host = host ?? HubSessionCreate();

  final HubSessionCreate _host;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a new 1:1 session on the host with a handoff summary';

  @override
  String get usage =>
      'shepaw chat session create --reason context_too_long '
      '--summary "key points to keep" '
      '[--reason-detail "..."] [--handoff-json \'{...}\']';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description': 'DM channel id (defaults to injected channel_id)',
        'required': false,
        'type': 'string',
      },
      'reason': {
        'description':
            'topic_shift | post_delivery | noise_reduction | context_too_long | '
            'agent_memory_reset | parallel_track | user_requested',
        'required': true,
        'type': 'string',
      },
      'reason-detail': {
        'description': 'Human-readable explanation for the user',
        'required': false,
        'type': 'string',
      },
      'summary': {
        'description':
            'Key points for the new session (required unless handoff-json '
            'includes task.user_goal)',
        'required': true,
        'type': 'string',
      },
      'handoff-json': {
        'description':
            'Optional structured handoff JSON (task.user_goal used as summary)',
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
    final channelId = GroupManagementService.resolveChannelId(flags) ??
        ChatAgentScope.channelId.trim();
    if (channelId.isEmpty) {
      return {
        'error':
            'Missing --channel or channel_id (must run inside a 1:1 session)',
      };
    }

    final reason = flags['reason']?.trim();
    if (reason == null || reason.isEmpty) {
      return {'error': 'Missing required flag: --reason'};
    }

    final summary = flags['summary']?.trim() ?? '';
    final handoffJson = flags['handoff-json'] ?? flags['handoff_json'];
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
    }
    final goal = inlineHandoff?['task'] is Map
        ? (inlineHandoff!['task'] as Map)['user_goal']?.toString().trim() ?? ''
        : '';
    if (summary.isEmpty && goal.isEmpty) {
      return {'error': 'Provide --summary or --handoff-json'};
    }

    final actorId = (flags['agent_id']?.trim().isNotEmpty == true)
        ? flags['agent_id']!.trim()
        : ChatAgentScope.agentId.trim();
    if (actorId.isEmpty) {
      return {'error': 'Missing executor agent id'};
    }
    final actorName = flags['agent_name']?.trim().isNotEmpty == true
        ? flags['agent_name']!.trim()
        : actorId;
    final callToken = (flags['call_token'] ?? '').trim();

    return _host.create(<String, dynamic>{
      'kind': 'dm',
      'agent_id': actorId,
      'agent_name': actorName,
      if (callToken.isNotEmpty) 'call_token': callToken,
      'channel_id': channelId,
      'reason': reason,
      if (flags['reason-detail']?.trim().isNotEmpty == true)
        'reason_detail': flags['reason-detail']!.trim(),
      if (summary.isNotEmpty) 'summary': summary,
      if (inlineHandoff != null) 'handoff': inlineHandoff,
      'post_first_message': flags['no-first-message'] != 'true',
      'suggest_switch': flags['no-switch-card'] != 'true',
    });
  }
}
