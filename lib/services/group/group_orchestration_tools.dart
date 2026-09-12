import 'dart:convert';

import '../../models/group_task.dart';
import '../../models/mention_entry.dart';
import '../../models/remote_agent.dart';
import '../logger_service.dart';
import 'group_dispatch_parser.dart';

/// First-class tools for group-admin orchestration (tool-first dispatch).
///
/// Injected only for group admin local LLM turns. Replaces free-form
/// ```json``` dispatch blocks as the primary machine contract.
class GroupOrchestrationTools {
  GroupOrchestrationTools._();

  static const dispatchName = 'group_dispatch';
  static const finishName = 'group_finish';
  static const planPublishName = 'group_plan_publish';
  static const sessionCreateName = 'group_session_create';

  /// Member-to-member mention declaration tool. Deliberately NOT in [names]:
  /// [names] tools are encoded as legacy JSON blocks for peer-hosted admins
  /// (agent_messaging_service), and group_mention is never offered to remote
  /// agents — they use the reply-metadata convention instead.
  static const mentionName = 'group_mention';

  static const Set<String> names = {
    dispatchName,
    finishName,
    planPublishName,
  };

  /// UI tools that must not be offered in group chat (history is already injected).
  static const Set<String> excludedUiToolNames = {'request_history'};

  /// `group_dispatch.intent` values.
  ///
  /// [dispatchIntentRecon] is a fact-finding turn: the admin asks members what
  /// the current state is before the requirement is finalized. It exempts the
  /// dispatch from the `group_plan_publish` gate (there is no settled
  /// requirement to publish yet) and does not flip the task to `executing`.
  static const String dispatchIntentWork = 'work';
  static const String dispatchIntentRecon = 'recon';

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
              'Delegate work to group members, or run a recon turn to find out '
              'facts only they can verify (intent=recon, needs no published '
              'plan). Call this whenever you assign tasks or need to consult '
              'members. Do NOT put dispatch JSON in chat text — use this tool. '
              'For intent=work also reply to the user in natural language '
              'describing the plan.',
          'parameters': _dispatchSchema(agentNames),
        },
      },
      {
        'type': 'function',
        'function': {
          'name': planPublishName,
          'description':
              'Publish the finalized task requirement and formal plan to the '
              'group workspace (shared/tasks/). Call after user confirms the '
              'need and before group_dispatch. Members read this plan; do NOT '
              'dispatch until this succeeds.',
          'parameters': _planPublishSchema(agentNames),
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
      {
        'type': 'function',
        'function': {
          'name': sessionCreateName,
          'description':
              'Open a new group session with a curated handoff package when '
              'staying in the current session would add noise or stale context. '
              'Do NOT use for simple dev/review rework — keep the current session. '
              'Requires handoff (user goal + acceptance criteria). Shows the user '
              'a switch-session card; do not assume they already switched.',
          'parameters': _sessionCreateSchema(),
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
        'name': planPublishName,
        'description':
            'Publish the finalized task requirement and formal plan to the '
            'group workspace (shared/tasks/). Call after user confirms the '
            'need and before group_dispatch. Members read this plan; do NOT '
            'dispatch until this succeeds.',
        'input_schema': _planPublishSchema(agentNames),
      },
      {
        'name': finishName,
        'description':
            'Signal orchestration control without dispatching members: '
            'done (user need satisfied), continue (you keep working alone), '
            'or pause (wait for user input).',
        'input_schema': _finishSchema(),
      },
      {
        'name': sessionCreateName,
        'description':
            'Open a new group session with a curated handoff package when '
            'staying in the current session would add noise or stale context. '
            'Do NOT use for simple dev/review rework — keep the current session. '
            'Requires handoff (user goal + acceptance criteria). Shows the user '
            'a switch-session card; do not assume they already switched.',
        'input_schema': _sessionCreateSchema(),
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
        'intent': {
          'type': 'string',
          'enum': [dispatchIntentWork, dispatchIntentRecon],
          'description':
              'work (default) = assign real deliverables, requires a published '
              'plan first. recon = fact-finding: ask members what the current '
              'state actually is (which items exist, what is already '
              'implemented) before the requirement is finalized. recon needs no '
              'published plan, does not create a workflow or plan-approval card, '
              'and expects answers, not deliverables. Use recon whenever the '
              'missing detail is something a member can look up — never ask the '
              'user for a fact your team can verify. Do not call workflow create '
              'just to talk with members.',
        },
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
                    'This member\'s local objective + acceptance criteria. '
                    'The user\'s full requirement is auto-injected as 全局需求 '
                    'for every member — focus this on what THIS member must do.',
              },
            },
            'required': ['agents', 'task'],
          },
        },
      },
      'required': ['mode', 'steps'],
    };
  }

  static Map<String, dynamic> _planPublishSchema(List<String> agentNames) {
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
        'goal': {
          'type': 'string',
          'description': 'Finalized user goal after any clarification',
        },
        'requirement_text': {
          'type': 'string',
          'description':
              'Human-readable finalized requirement (Markdown). Becomes '
              'shared/tasks/.../requirement.md for all members.',
        },
        'acceptance_criteria': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'How to judge the task complete',
        },
        'constraints': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Optional limits or non-goals',
        },
        'requirement_notes': {
          'type': 'string',
          'description':
              'Optional summary of clarification Q&A merged into the plan',
        },
        'steps_preview': {
          'type': 'array',
          'description':
              'Planned delegation preview (must match upcoming group_dispatch)',
          'items': {
            'type': 'object',
            'properties': {
              'step': {'type': 'integer'},
              'agents': {
                'type': 'array',
                'items': agentItems,
                'minItems': 1,
              },
              'task': {
                'type': 'string',
                'description': 'Member-local brief + acceptance for this step',
              },
              'mode': {
                'type': 'string',
                'enum': ['concurrent', 'sequential'],
              },
            },
            'required': ['agents', 'task'],
          },
        },
      },
      'required': ['goal', 'requirement_text', 'steps_preview'],
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

  static Map<String, dynamic> _sessionCreateSchema() => {
        'type': 'object',
        'properties': {
          'reason': {
            'type': 'string',
            'enum': [
              'topic_shift',
              'post_delivery',
              'noise_reduction',
              'context_too_long',
              'agent_memory_reset',
              'parallel_track',
              'user_requested',
            ],
            'description': 'Why a new session is recommended',
          },
          'reason_detail': {
            'type': 'string',
            'description': 'Human-readable explanation for the user',
          },
          'handoff': {
            'type': 'object',
            'description':
                'Structured handoff package (preferred). Must include '
                'task.user_goal, task.acceptance_criteria[], task.status, '
                'and reason.code unless reason is set at top level.',
            'properties': {
              'task': {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                  'user_goal': {'type': 'string'},
                  'acceptance_criteria': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                  'status': {
                    'type': 'string',
                    'enum': [
                      'not_started',
                      'in_progress',
                      'delivered',
                      'blocked',
                    ],
                  },
                  'status_note': {'type': 'string'},
                },
                'required': ['user_goal', 'acceptance_criteria', 'status'],
              },
              'reason': {
                'type': 'object',
                'properties': {
                  'code': {'type': 'string'},
                  'detail': {'type': 'string'},
                },
              },
              'constraints': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'artifacts': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'uri': {'type': 'string'},
                    'label': {'type': 'string'},
                    'required_read': {'type': 'boolean'},
                  },
                  'required': ['uri'],
                },
              },
              'open_items': {'type': 'array'},
              'roles': {'type': 'array'},
              'first_message_draft': {'type': 'string'},
            },
          },
          'handoff_uri': {
            'type': 'string',
            'description':
                'Existing handoff JSON in store (alternative to inline handoff)',
          },
          'post_first_message': {
            'type': 'boolean',
            'description':
                'Write handoff summary as first system message in new session '
                '(default true)',
          },
          'suggest_switch': {
            'type': 'boolean',
            'description':
                'Show user a tappable switch-session card (default true)',
          },
        },
        'required': ['reason'],
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
    // L11: 校验 mode，非法值不再静默按 concurrent 处理（记告警，步骤仍执行）。
    const validModes = {'concurrent', 'sequential'};
    if (rawMode is String && rawMode.isNotEmpty && !validModes.contains(rawMode)) {
      LoggerService().warning(
        'group_dispatch mode "$rawMode" is not supported; falling back to concurrent',
        tag: 'GroupOrchestrationTools',
      );
    }
    final mode =
        (rawMode is String && validModes.contains(rawMode)) ? rawMode : 'concurrent';
    // 非法 intent 回落 work（保守：宁可要求先发计划，也不要误判成摸底而跳过门禁）。
    final rawIntent = args['intent'];
    if (rawIntent is String &&
        rawIntent.isNotEmpty &&
        rawIntent != dispatchIntentWork &&
        rawIntent != dispatchIntentRecon) {
      LoggerService().warning(
        'group_dispatch intent "$rawIntent" is not supported; falling back to $dispatchIntentWork',
        tag: 'GroupOrchestrationTools',
      );
    }
    final isRecon = rawIntent == dispatchIntentRecon;
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
        isRecon: isRecon,
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

  /// Parsed payload for `group_plan_publish`.
  static ({
    GroupTaskPlan? plan,
    String requirementText,
    String requirementNotes,
    List<String> unresolvedNames,
    String? parseError,
  }) parsePlanPublishArgs(
    Map<String, dynamic> args,
    List<RemoteAgent> agents, {
    required String orchestrationId,
  }) {
    final goal = args['goal']?.toString().trim() ?? '';
    final requirementText = args['requirement_text']?.toString().trim() ?? '';
    final requirementNotes = args['requirement_notes']?.toString().trim() ?? '';
    if (goal.isEmpty) {
      return (
        plan: null,
        requirementText: requirementText,
        requirementNotes: requirementNotes,
        unresolvedNames: const [],
        parseError: 'group_plan_publish.goal is required',
      );
    }
    if (requirementText.isEmpty) {
      return (
        plan: null,
        requirementText: requirementText,
        requirementNotes: requirementNotes,
        unresolvedNames: const [],
        parseError: 'group_plan_publish.requirement_text is required',
      );
    }

    final criteria = <String>[];
    final rawCriteria = args['acceptance_criteria'];
    if (rawCriteria is List) {
      for (final c in rawCriteria) {
        if (c is String && c.trim().isNotEmpty) criteria.add(c.trim());
      }
    }

    final constraints = <String>[];
    final rawConstraints = args['constraints'];
    if (rawConstraints is List) {
      for (final c in rawConstraints) {
        if (c is String && c.trim().isNotEmpty) constraints.add(c.trim());
      }
    }

    final rawSteps = args['steps_preview'];
    if (rawSteps is! List || rawSteps.isEmpty) {
      return (
        plan: null,
        requirementText: requirementText,
        requirementNotes: requirementNotes,
        unresolvedNames: const [],
        parseError: 'group_plan_publish.steps_preview must be a non-empty array',
      );
    }

    final steps = <GroupTaskPlanStep>[];
    final unresolved = <String>[];
    for (final raw in rawSteps) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final rawAgents = map['agents'];
      final agentNames = rawAgents is List
          ? rawAgents.map((e) => '$e').toList()
          : rawAgents is String
              ? [rawAgents]
              : <String>[];
      if (agentNames.isEmpty) continue;

      final agentIds = <String>[];
      final resolvedNames = <String>[];
      for (final name in agentNames) {
        final agent = GroupDispatchParser.findAgentByDispatchName(agents, name);
        if (agent == null) {
          unresolved.add(name);
          continue;
        }
        if (!agentIds.contains(agent.id)) {
          agentIds.add(agent.id);
          resolvedNames.add(agent.name);
        }
      }
      if (resolvedNames.isEmpty) continue;

      final rawStep = map['step'];
      final stepNo = rawStep is num
          ? rawStep.toInt()
          : int.tryParse('$rawStep') ?? (steps.length + 1);
      final modeRaw = map['mode']?.toString().trim();
      steps.add(GroupTaskPlanStep(
        step: stepNo,
        agents: resolvedNames,
        agentIds: agentIds,
        task: map['task']?.toString().trim() ?? '',
        mode: modeRaw == 'sequential' ? 'sequential' : 'concurrent',
      ));
    }

    steps.sort((a, b) => a.step.compareTo(b.step));
    if (steps.isEmpty) {
      final err = unresolved.isNotEmpty
          ? 'no group members matched in steps_preview: ${unresolved.join(", ")}'
          : 'group_plan_publish.steps_preview produced no usable steps';
      return (
        plan: null,
        requirementText: requirementText,
        requirementNotes: requirementNotes,
        unresolvedNames: unresolved,
        parseError: err,
      );
    }

    for (final step in steps) {
      if (step.task.isEmpty) {
        return (
          plan: null,
          requirementText: requirementText,
          requirementNotes: requirementNotes,
          unresolvedNames: unresolved,
          parseError: 'each steps_preview entry needs a non-empty task',
        );
      }
    }

    return (
      plan: GroupTaskPlan(
        orchestrationId: orchestrationId,
        goal: goal,
        acceptanceCriteria: criteria,
        constraints: constraints,
        steps: steps,
      ),
      requirementText: requirementText,
      requirementNotes: requirementNotes,
      unresolvedNames: unresolved,
      parseError: null,
    );
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
