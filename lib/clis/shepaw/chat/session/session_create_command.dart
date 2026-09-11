import 'dart:convert';

import '../../../../services/group/group_management_service.dart';
import '../../../../services/session/dm_session_create_service.dart';
import '../../../cli_base.dart';
import '../chat_agent_scope.dart';

/// shepaw chat session create — open a new 1:1 session with a handoff summary.
class ChatSessionCreateCommand extends CliCommand {
  ChatSessionCreateCommand({DmSessionCreateService? service})
      : _service = service ?? DmSessionCreateService();

  final DmSessionCreateService _service;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a new 1:1 session with a handoff summary (does not auto-switch)';

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
    if (summary.isEmpty && inlineHandoff == null) {
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

    final args = <String, dynamic>{
      'reason': reason,
      if (flags['reason-detail']?.trim().isNotEmpty == true)
        'reason_detail': flags['reason-detail']!.trim(),
      if (summary.isNotEmpty) 'summary': summary,
      if (inlineHandoff != null) 'handoff': inlineHandoff,
      'post_first_message': flags['no-first-message'] != 'true',
      'suggest_switch': flags['no-switch-card'] != 'true',
    };

    final result = await _service.create(
      channelId: channelId,
      actorId: actorId,
      actorName: actorName,
      args: args,
    );
    return result.toCliJson();
  }
}
