import 'dart:convert';

import '../../models/mention_entry.dart';
import '../../models/remote_agent.dart';
import 'group_dispatch_parser.dart';

/// First-class tools for group-admin orchestration (tool-first dispatch).
///
/// Injected only for group admin local LLM turns. Replaces free-form
/// ```json``` dispatch blocks as the primary machine contract.
class GroupOrchestrationTools {
  GroupOrchestrationTools._();

  static const dispatchName = 'group_dispatch';
  static const finishName = 'group_finish';

  /// Member-to-member mention declaration tool. Deliberately NOT in [names]:
  /// [names] tools are encoded as legacy JSON blocks for peer-hosted admins
  /// (agent_messaging_service), and group_mention is never offered to remote
  /// agents — they use the reply-metadata convention instead.
  static const mentionName = 'group_mention';

  static const Set<String> names = {dispatchName, finishName};

  /// UI tools that must not be offered in group chat (history is already injected).
  static const Set<String> excludedUiToolNames = {'request_history'};

  /// OpenAI function-calling tool definitions with [agentNames] as enum.
  static List<Map<String, dynamic>> openAITools({
    required List<String> agentNames,
  }) {
    return [
      {
        'type': 'function',
        'function': {
          'name': dispatchName,
          'description':
              'Delegate work to group members. Call this whenever you decide to '
              'assign tasks. Do NOT put dispatch JSON in chat text — use this tool. '
              'Also reply to the user in natural language describing the plan.',
          'parameters': _dispatchSchema(agentNames),
        },
      },
      {
        'type': 'function',
        'function': {
          'name': finishName,
          'description':
              'Signal orchestration control without dispatching members: '
              'done (user need satisfied), continue (you keep working alone), '
              'or pause (wait for user input). Call this instead of emitting '
              '{"done": true} JSON in chat text.',
          'parameters': _finishSchema(),
        },
      },
    ];
  }

  /// Claude / Anthropic tool definitions.
  static List<Map<String, dynamic>> claudeTools({
    required List<String> agentNames,
  }) {
    return [
      {
        'name': dispatchName,
        'description':
            'Delegate work to group members. Call this whenever you decide to '
            'assign tasks. Do NOT put dispatch JSON in chat text — use this tool. '
            'Also reply to the user in natural language describing the plan.',
        'input_schema': _dispatchSchema(agentNames),
      },
      {
        'name': finishName,
        'description':
            'Signal orchestration control without dispatching members: '
            'done (user need satisfied), continue (you keep working alone), '
            'or pause (wait for user input).',
        'input_schema': _finishSchema(),
      },
    ];
  }

  /// `group_mention` tool (Claude format) for LOCAL group members —
  /// the structured way to request another member's help.
  static List<Map<String, dynamic>> claudeMentionTools({
    required List<String> agentNames,
  }) {
    return [
      {
        'name': mentionName,
        'description':
            'Declare that you are mentioning/activating group members for '
            'assistance. Call this instead of writing @name in chat text — '
            'text @ is display-only and never parsed. Also reply to the user '
            'in natural language.',
        'input_schema': _mentionSchema(agentNames),
      },
    ];
  }

  /// `group_mention` tool (OpenAI format) for LOCAL group members.
  static List<Map<String, dynamic>> openAIMentionTools({
    required List<String> agentNames,
  }) {
    return [
      {
        'type': 'function',
        'function': {
          'name': mentionName,
          'description':
              'Declare that you are mentioning/activating group members for '
              'assistance. Call this instead of writing @name in chat text — '
              'text @ is display-only and never parsed. Also reply to the user '
              'in natural language.',
          'parameters': _mentionSchema(agentNames),
        },
      },
    ];
  }

  static Map<String, dynamic> _mentionSchema(List<String> agentNames) {
    final nameItems = <String, dynamic>{
      'type': 'string',
      'description':
          'Registered group member display name, or "all" for every member',
    };
    if (agentNames.isNotEmpty) {
      nameItems['enum'] = [...agentNames, 'all'];
    }
    return {
      'type': 'object',
      'properties': {
        'mentions': {
          'type': 'array',
          'description': 'Members to mention/activate',
          'items': {
            'type': 'object',
            'properties': {
              'name': nameItems,
              'notify': {
                'type': 'boolean',
                'description':
                    'true = activate the member (default); false = cc only (display, no activation)',
              },
              'reason': {
                'type': 'string',
                'description':
                    'Optional brief reason the member is being asked for help',
              },
            },
            'required': ['name'],
          },
        },
      },
      'required': ['mentions'],
    };
  }

  /// Parse `group_mention` tool arguments into structured mention entries.
  /// Delegates to [GroupDispatchParser.resolveMentionDeclarations] so tool
  /// feedback and the unified capture share one resolution path.
  static ({List<MentionEntry> mentions, List<String> unresolvedNames})
      parseMentionArgs(Map<String, dynamic> args, List<RemoteAgent> agents) {
    final resolved =
        GroupDispatchParser.resolveMentionDeclarations([args], agents);
    return (
      mentions: resolved.mentions,
      unresolvedNames: resolved.unresolved,
    );
  }

  static Map<String, dynamic> _dispatchSchema(List<String> agentNames) {
    final agentItems = <String, dynamic>{
      'type': 'string',
      'description': 'Registered group member display name',
    };
    if (agentNames.isNotEmpty) {
      agentItems['enum'] = agentNames;
    }

    return {
      'type': 'object',
      'properties': {
        'mode': {
          'type': 'string',
          'enum': ['concurrent', 'sequential'],
          'description':
              'concurrent = run steps in parallel; sequential = by step order',
        },
        'steps': {
          'type': 'array',
          'description': 'Dispatch steps',
          'items': {
            'type': 'object',
            'properties': {
              'step': {
                'type': 'integer',
                'description': 'Step number (1-based). Optional; defaults to order.',
              },
              'agents': {
                'type': 'array',
                'items': agentItems,
                'minItems': 1,
                'description': 'Member registered names to assign',
              },
              'task': {
                'type': 'string',
                'description':
                    'Full task brief: background, goal, acceptance criteria. '
                    'Members may not see the user message.',
              },
            },
            'required': ['agents', 'task'],
          },
        },
      },
      'required': ['mode', 'steps'],
    };
  }

  static Map<String, dynamic> _finishSchema() => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['done', 'continue', 'pause'],
            'description':
                'done = end orchestration; continue = admin keeps working alone; '
                'pause = wait for user (e.g. pending needs input)',
          },
        },
        'required': ['action'],
      };

  /// Parse `group_dispatch` tool arguments into [DispatchStep]s.
  static ({
    List<DispatchStep> steps,
    List<String> unresolvedNames,
    String? parseError,
  }) parseDispatchArgs(
    Map<String, dynamic> args,
    List<RemoteAgent> agents,
  ) {
    final rawMode = args['mode'];
    final mode = (rawMode is String && rawMode.isNotEmpty) ? rawMode : 'concurrent';
    final rawSteps = args['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      return (
        steps: const [],
        unresolvedNames: const [],
        parseError: 'group_dispatch.steps must be a non-empty array',
      );
    }

    final steps = <DispatchStep>[];
    final unresolved = <String>[];
    var malformed = 0;

    for (final s in rawSteps) {
      if (s is! Map) {
        malformed++;
        continue;
      }
      final map = Map<String, dynamic>.from(s);
      final rawAgents = map['agents'];
      final agentNames = rawAgents is List
          ? rawAgents.map((e) => '$e').toList()
          : rawAgents is String
              ? [rawAgents]
              : <String>[];
      if (agentNames.isEmpty) {
        malformed++;
        continue;
      }
      final agentIds = <String>[];
      for (final name in agentNames) {
        final agent = GroupDispatchParser.findAgentByDispatchName(agents, name);
        if (agent == null) {
          unresolved.add(name);
          continue;
        }
        if (!agentIds.contains(agent.id)) agentIds.add(agent.id);
      }
      if (agentIds.isEmpty) continue;
      final rawStep = map['step'];
      final stepNo = rawStep is num
          ? rawStep.toInt()
          : int.tryParse('$rawStep') ?? (steps.length + 1);
      steps.add(DispatchStep(
        step: stepNo,
        agentIds: agentIds,
        task: map['task']?.toString() ?? '',
        mode: mode,
      ));
    }

    steps.sort((a, b) => a.step.compareTo(b.step));

    if (steps.isEmpty) {
      final err = malformed > 0
          ? 'group_dispatch steps are malformed'
          : unresolved.isNotEmpty
              ? 'no group members matched: ${unresolved.join(", ")}'
              : 'group_dispatch produced no usable steps';
      return (steps: const [], unresolvedNames: unresolved, parseError: err);
    }

    return (steps: steps, unresolvedNames: unresolved, parseError: null);
  }

  /// Parse `group_finish` action: done | continue | pause.
  static String? parseFinishAction(Map<String, dynamic> args) {
    final action = args['action']?.toString().trim().toLowerCase();
    if (action == 'done' || action == 'continue' || action == 'pause') {
      return action;
    }
    return null;
  }

  /// Encode a tool call as the legacy ```json``` block so remote/peer
  /// admins that cannot receive extraTools still parse via text fallback.
  static String legacyJsonBlock(String name, Map<String, dynamic> args) {
    if (name == dispatchName) {
      return jsonEncode({
        'dispatch': {
          'mode': args['mode'] ?? 'concurrent',
          'steps': args['steps'] ?? [],
        },
        'continue': false,
        'done': false,
      });
    }
    if (name == finishName) {
      final action = parseFinishAction(args);
      if (action == 'continue') return jsonEncode({'continue': true});
      if (action == 'pause') return jsonEncode({'pause': true});
      return jsonEncode({'done': true});
    }
    return jsonEncode({'done': true});
  }
}
