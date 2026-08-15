import 'dart:convert';
import '../../models/planning_models.dart';
import '../../models/remote_agent.dart';
import '../local_database_service.dart';
import '../logger_service.dart';

/// A single dispatch step from Admin's structured JSON dispatch block.
class DispatchStep {
  final int step;
  final List<String> agentIds;
  final String task;
  final String mode; // "concurrent" | "sequential"

  const DispatchStep({
    required this.step,
    required this.agentIds,
    required this.task,
    required this.mode,
  });

  /// Member-facing brief for this step; empty task falls back to [fallback].
  String contentOr(String fallback) {
    final trimmed = task.trim();
    return trimmed.isNotEmpty ? trimmed : fallback;
  }
}

/// Pure parsing/utility functions for group chat dispatch.
class GroupDispatchParser {
  final LocalDatabaseService _db;

  GroupDispatchParser(this._db);

  /// Whether [requestedName] matches [agent]'s registered group display name.
  static bool matchesAgentName(RemoteAgent agent, String requestedName) {
    final requested = requestedName.trim();
    if (requested.isEmpty) return false;
    return agent.name == requested ||
        agent.name.toLowerCase() == requested.toLowerCase();
  }

  /// Resolve a dispatch/workflow agent label to a group member (case-insensitive).
  static RemoteAgent? findAgentByDispatchName(
    List<RemoteAgent> agents,
    String requestedName,
  ) {
    for (final agent in agents) {
      if (matchesAgentName(agent, requestedName)) return agent;
    }
    return null;
  }

  static List<String> resolveAgentIdsForDispatchNames(
    List<RemoteAgent> agents,
    List<String> requestedNames, {
    String logTag = 'GroupDispatchParser',
  }) {
    final agentIds = <String>[];
    for (final requestedName in requestedNames) {
      final agent = findAgentByDispatchName(agents, requestedName);
      if (agent == null) {
        LoggerService().warning(
          'Dispatch agent name "$requestedName" did not match any group member '
          '(known: ${agents.map((a) => a.name).join(', ')})',
          tag: logTag,
        );
        continue;
      }
      if (!agentIds.contains(agent.id)) {
        agentIds.add(agent.id);
      }
    }
    return agentIds;
  }

  /// Look up the dispatch brief for [agentId]. Concurrent rounds may have
  /// several steps; the first matching non-empty [DispatchStep.task] wins.
  static String taskContentForAgent({
    required String agentId,
    required List<DispatchStep> steps,
    required String fallback,
  }) {
    for (final step in steps) {
      if (step.agentIds.contains(agentId)) {
        return step.contentOr(fallback);
      }
    }
    return fallback;
  }

  /// Parse @mentions from an agent's response content, returning matching agent IDs.
  List<String> parseAgentMentions(String content, List<RemoteAgent> agents) {
    if (content.contains('@all')) {
      return agents.map((a) => a.id).toList();
    }
    final mentioned = <String>[];
    for (final agent in agents) {
      if (content.contains('@${agent.name}')) {
        mentioned.add(agent.id);
      }
    }
    return mentioned;
  }

  /// Parse Admin's structured JSON dispatch block.
  ///
  /// Expects a ```json … ``` code block in [content] with the schema:
  /// ```
  /// {
  ///   "dispatch": {
  ///     "mode": "concurrent" | "sequential",
  ///     "steps": [{"step": 1, "agents": ["Name"], "task": "…"}]
  ///   },
  ///   "continue": false,
  ///   "done": false
  /// }
  /// ```
  ({List<DispatchStep> steps, bool wantsContinue, bool isDone, bool isPause, String? parseError, List<String> unresolvedNames})
      parseStructuredDispatch(String content, List<RemoteAgent> agents) {
    const noError = null;
    const noUnresolved = <String>[];
    final match = RegExp(r'```json\s*([\s\S]*?)\s*```', caseSensitive: false).firstMatch(content);
    if (match == null) {
      return (steps: [], wantsContinue: false, isDone: true, isPause: false, parseError: noError, unresolvedNames: noUnresolved);
    }

    Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(match.group(1)!);
      if (decoded is! Map<String, dynamic>) {
        return (
          steps: [],
          wantsContinue: false,
          isDone: true,
          isPause: false,
          parseError: 'dispatch JSON root is not an object',
          unresolvedNames: noUnresolved,
        );
      }
      parsed = decoded;
    } catch (e) {
      return (
        steps: [],
        wantsContinue: false,
        isDone: true,
        isPause: false,
        parseError: 'invalid dispatch JSON: $e',
        unresolvedNames: noUnresolved,
      );
    }

    final isPause = parsed['pause'] == true;
    final isDone = parsed['done'] == true || isPause;
    final wantsContinue = parsed['continue'] == true;
    final rawDispatch = parsed['dispatch'];
    final dispatchData = rawDispatch is Map ? rawDispatch : null;

    if (dispatchData == null || isDone) {
      return (
        steps: [],
        wantsContinue: wantsContinue,
        isDone: isDone,
        isPause: isPause,
        parseError: noError,
        unresolvedNames: noUnresolved,
      );
    }

    final rawMode = dispatchData['mode'];
    final mode = (rawMode is String && rawMode.isNotEmpty) ? rawMode : 'concurrent';
    final rawStepsValue = dispatchData['steps'];
    final rawSteps = rawStepsValue is List ? rawStepsValue : const [];

    final steps = <DispatchStep>[];
    final unresolved = <String>[];
    var malformedSteps = 0;
    for (final s in rawSteps) {
      if (s is! Map) {
        malformedSteps++;
        continue;
      }
      // Tolerate "agents": "Name" (string instead of list).
      final rawAgents = s['agents'];
      final agentNames = rawAgents is List
          ? rawAgents.map((e) => '$e').toList()
          : rawAgents is String
              ? [rawAgents]
              : <String>[];
      if (agentNames.isEmpty) {
        malformedSteps++;
        continue;
      }
      final agentIds = <String>[];
      for (final requestedName in agentNames) {
        final agent = findAgentByDispatchName(agents, requestedName);
        if (agent == null) {
          unresolved.add(requestedName);
          LoggerService().warning(
            'Dispatch agent name "$requestedName" did not match any group member '
            '(known: ${agents.map((a) => a.name).join(', ')})',
            tag: 'GroupDispatchParser',
          );
          continue;
        }
        if (!agentIds.contains(agent.id)) {
          agentIds.add(agent.id);
        }
      }
      if (agentIds.isEmpty) continue;
      // Tolerate "step": "1" (string) or a missing step number.
      final rawStep = s['step'];
      final stepNo = rawStep is num
          ? rawStep.toInt()
          : int.tryParse('$rawStep') ?? (steps.length + 1);
      final rawTask = s['task'];
      steps.add(DispatchStep(
        step: stepNo,
        agentIds: agentIds,
        task: rawTask?.toString() ?? '',
        mode: mode,
      ));
    }

    steps.sort((a, b) => a.step.compareTo(b.step));

    // A dispatch block that yielded no usable step at all is a parse failure
    // the caller may want to nudge the admin about — not a silent "done".
    String? parseError;
    if (steps.isEmpty) {
      if (malformedSteps > 0) {
        parseError = 'dispatch steps are malformed (missing/invalid agents or step)';
      } else if (unresolved.isNotEmpty) {
        parseError = 'none of the dispatched agent names matched a group member: ${unresolved.join(', ')}';
      }
    }

    return (steps: steps, wantsContinue: wantsContinue, isDone: false, isPause: false, parseError: parseError, unresolvedNames: unresolved);
  }

  /// Convert structured dispatch steps into a [FlowPlan] for workflow tracking.
  FlowPlan buildFlowPlanFromDispatch({
    required List<DispatchStep> steps,
    required String mode,
    required List<RemoteAgent> agents,
    required String summary,
    String? title,
  }) {
    if (steps.isEmpty) {
      return FlowPlan(
        title: title ?? '群聊任务',
        summary: summary,
        stages: [],
      );
    }

    final isSequential = mode == 'sequential' && steps.length > 1;
    final stages = <FlowStage>[];

    if (isSequential) {
      for (int i = 0; i < steps.length; i++) {
        final ds = steps[i];
        final flowSteps = _flowStepsFromDispatchStep(ds, agents, i);
        if (flowSteps.isEmpty) continue;
        stages.add(FlowStage(
          stageId: 's$i',
          label: '步骤 ${ds.step}',
          steps: flowSteps,
        ));
      }
    } else {
      final allFlowSteps = <FlowStep>[];
      for (int i = 0; i < steps.length; i++) {
        allFlowSteps.addAll(_flowStepsFromDispatchStep(steps[i], agents, i));
      }
      if (allFlowSteps.isNotEmpty) {
        stages.add(FlowStage(
          stageId: 's0',
          label: '任务分派',
          steps: allFlowSteps,
        ));
      }
    }

    final planTitle = title?.trim();
    return FlowPlan(
      title: (planTitle != null && planTitle.isNotEmpty)
          ? planTitle
          : (summary.length > 48 ? '${summary.substring(0, 48)}…' : summary),
      summary: summary,
      stages: stages,
    );
  }

  List<FlowStep> _flowStepsFromDispatchStep(
    DispatchStep ds,
    List<RemoteAgent> agents,
    int stageIndex,
  ) {
    final flowSteps = <FlowStep>[];
    var stepIndex = 0;
    for (final agentId in ds.agentIds) {
      final agent = agents.where((a) => a.id == agentId).firstOrNull;
      if (agent == null) continue;
      final instruction =
          ds.task.trim().isNotEmpty ? ds.task.trim() : '请处理用户请求';
      flowSteps.add(FlowStep(
        stepId: 's${stageIndex}_t$stepIndex',
        taskId: 'task_${stageIndex}_$stepIndex',
        agent: agent.name,
        instruction: instruction,
      ));
      stepIndex++;
    }
    return flowSteps;
  }

  /// Strip the ```json … ``` dispatch block from the last Admin message in
  /// [channelId] so that the raw JSON is never shown to the user.
  Future<void> stripDispatchJsonFromLastMessage(
    String channelId,
    String agentId,
  ) async {
    try {
      final messages = await _db.getChannelMessages(channelId, limit: 10);
      final jsonBlockPattern =
          RegExp(r'\s*```json\s*[\s\S]*?```\s*', multiLine: true);
      for (final m in messages) {
        if (m['sender_id'] == agentId &&
            m['content'] != null &&
            jsonBlockPattern.hasMatch(m['content'] as String)) {
          final cleaned =
              (m['content'] as String).replaceAll(jsonBlockPattern, '').trimRight();
          await _db.updateMessage(messageId: m['id'] as String, content: cleaned);
          break;
        }
      }
    } catch (e) {
      LoggerService().warning('Failed to strip dispatch JSON block',
          tag: 'GroupDispatchParser', error: e);
    }
  }

  /// Try to match admin response text against options by index, ID, or label.
  ///
  /// Returns the index into [options] or -1 if no match.
  int matchOption(String response, List<dynamic> options) {
    final trimmed = response.trim();

    // 1. Numeric index (1-based)
    final index = int.tryParse(trimmed);
    if (index != null && index >= 1 && index <= options.length) {
      return index - 1;
    }

    // 2. Exact option ID match
    for (var i = 0; i < options.length; i++) {
      final option = options[i] as Map<String, dynamic>;
      final id = option['id'] as String? ?? '';
      if (id.isNotEmpty && trimmed.toLowerCase() == id.toLowerCase()) {
        return i;
      }
    }

    // 3. Label substring match
    for (var i = 0; i < options.length; i++) {
      final option = options[i] as Map<String, dynamic>;
      final label = option['label'] as String? ?? '';
      if (label.isNotEmpty && trimmed.contains(label)) {
        return i;
      }
    }

    return -1;
  }
}
