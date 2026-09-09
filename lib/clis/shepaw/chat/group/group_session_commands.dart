import 'dart:convert';

import '../../../../services/group/group_management_service.dart';
import '../../../cli_base.dart';

/// shepaw chat group session create — open a new session with handoff (admin only).
class GroupSessionCreateCommand extends CliCommand {
  GroupSessionCreateCommand({GroupManagementService? service})
      : _service = service ?? GroupManagementService();

  final GroupManagementService _service;

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a new group session with a curated handoff package (admin only)';

  @override
  String get usage =>
      'shepaw chat group session create --reason topic_shift '
      '--handoff-json \'{"task":{"user_goal":"...","acceptance_criteria":["..."],"status":"in_progress"}}\' '
      '[--reason-detail "..."] [--handoff-uri store://...] [--no-first-message]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description': 'Group channel id (defaults to injected channel_id)',
        'required': false,
        'type': 'string',
      },
      'reason': {
        'description':
            'topic_shift | post_delivery | noise_reduction | agent_memory_reset | parallel_track | user_requested',
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
    }

    final actorId = flags['agent_id']?.trim() ?? flags['owner']?.trim() ?? '';
    if (actorId.isEmpty) {
      return {'error': 'Missing executor agent id'};
    }
    final actorName = flags['agent_name']?.trim() ?? actorId;

    final args = <String, dynamic>{
      'reason': reason,
      if (flags['reason-detail']?.trim().isNotEmpty == true)
        'reason_detail': flags['reason-detail']!.trim(),
      if (inlineHandoff != null) 'handoff': inlineHandoff,
      if (handoffUri != null && handoffUri.trim().isNotEmpty)
        'handoff_uri': handoffUri.trim(),
      'post_first_message': flags['no-first-message'] != 'true',
      'suggest_switch': flags['no-switch-card'] != 'true',
    };

    final result = await _service.createSessionWithHandoff(
      channelId: channelId,
      actorId: actorId,
      actorName: actorName,
      args: args,
    );
    return result.toCliJson();
  }
}
