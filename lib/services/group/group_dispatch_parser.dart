import 'dart:convert';
import '../../models/mention_entry.dart';
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

  /// Normalize a mention/dispatch label for comparison: trim, collapse inner
  /// whitespace, map full-width punctuation to half-width and strip common
  /// decorative brackets/quotes the model may wrap names in.
  static String normalizeMentionName(String raw) {
    var s = raw.trim();
    s = s.replaceAll('＠', '@');
    s = s.replaceAll('：', ':').replaceAll('，', ',').replaceAll('；', ';')
        .replaceAll('。', '.').replaceAll('？', '?').replaceAll('！', '!');
    s = s.replaceAll('（', '(').replaceAll('）', ')').replaceAll('【', '[')
        .replaceAll('】', ']').replaceAll('「', '"').replaceAll('」', '"')
        .replaceAll('『', '"').replaceAll('』', '"');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s;
  }

  /// Strip leading/trailing quote-ish decorations a model may add around a
  /// name inside JSON (e.g. `"张三"` → `张三`, `'Tom'` → `Tom`).
  static String stripQuoteDecorations(String raw) {
    var s = raw.trim();
    s = s.replaceAll(_leadingNameDecorations, '');
    s = s.replaceAll(_trailingNameDecorations, '');
    return s.trim();
  }

  static final RegExp _leadingNameDecorations =
      RegExp('^["\\\'“”‘’「」『』【】\\[\\]]+');
  static final RegExp _trailingNameDecorations =
      RegExp('["\\\'“”‘’「」『』【】\\[\\]]+\$');

  /// Whether [requestedName] matches [agent]'s registered group display name.
  ///
  /// Match tiers, in order:
  /// 1. exact (after normalization),
  /// 2. case-insensitive,
  /// 3. agent id,
  /// 4. unique substring (>= 2 chars) — resolved by the caller against the
  ///    full member list so a common prefix like "app" never matches alone.
  static bool matchesAgentName(RemoteAgent agent, String requestedName) {
    final requested = stripQuoteDecorations(normalizeMentionName(requestedName));
    if (requested.isEmpty) return false;
    final name = normalizeMentionName(agent.name);
    if (name == requested) return true;
    if (name.toLowerCase() == requested.toLowerCase()) return true;
    if (requested == agent.id) return true;
    // Substring tier is intentionally NOT applied here — it needs the whole
    // member list for uniqueness; see [findAgentByDispatchName].
    return false;
  }

  /// Resolve a dispatch/workflow agent label to a group member.
  ///
  /// Tier order: exact/case-insensitive/id match first; then a unique
  /// substring match (>= 2 chars, case-insensitive) so "张" still resolves
  /// to "张三" when no other member shares that fragment.
  static RemoteAgent? findAgentByDispatchName(
    List<RemoteAgent> agents,
    String requestedName,
  ) {
    final requested = stripQuoteDecorations(normalizeMentionName(requestedName));
    if (requested.isEmpty) return null;

    // Tier 1: exact / case-insensitive / id.
    for (final agent in agents) {
      if (matchesAgentName(agent, requested)) return agent;
    }

    // Tier 2: unique substring across the member list.
    // Guard: >= 2 chars, or a single CJK Han char (信息量远大于单个拉丁字母，
    // 如「@张」应能解析到「张三」，但「@R」不该匹配「Reviewer」）。
    final isSingleHan = requested.length == 1 && _hanChar.hasMatch(requested);
    if (requested.length >= 2 || isSingleHan) {
      final lower = requested.toLowerCase();
      final candidates = agents
          .where((a) => normalizeMentionName(a.name).toLowerCase().contains(lower))
          .toList();
      if (candidates.length == 1) return candidates.first;
    }
    return null;
  }

  static final RegExp _hanChar = RegExp(r'\p{Script=Han}', unicode: true);

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

  /// Build the member-facing turn content for a delegated task: a first-class
  /// 【全局需求】 block (the user's full message) followed by the member's
  /// 【你的任务】 local brief.
  ///
  /// When [memberBrief] is empty or equals [globalRequirement] (the step had no
  /// task and fell back to the global message), only the global requirement is
  /// returned — no duplication. [memoryNote] (a short group-history summary) is
  /// always appended. [loopEventNote] (上一轮编排事件的被动感知行，M5) 追加为
  /// 【上轮事件】块，非空时拼接。
  static String buildMemberTurnContent({
    required String memberBrief,
    required String globalRequirement,
    required String memoryNote,
    String loopEventNote = '',
  }) {
    final global = globalRequirement.trim();
    final brief = memberBrief.trim();
    final base = (brief.isEmpty || brief == global)
        ? '$global$memoryNote'
        : '【全局需求】\n$global\n\n【你的任务】\n$brief$memoryNote';
    final note = loopEventNote.trim();
    if (note.isEmpty) return base;
    return '$base\n\n【上轮事件】\n$note';
  }

  /// Resolve structured mention declarations into [MentionEntry]s.
  ///
  /// Mentions are declared structurally — never parsed from chat text, so a
  /// `@` inside an email, code snippet or quote can never mis-activate a
  /// member. [rawDeclarations] accepts either shape:
  /// - tool-args shape (`group_mention` call): `{'mentions': [{'name',
  ///   'notify', 'reason'}]}`,
  /// - metadata shape (reply metadata / persisted `meta['mentions']`):
  ///   a single `{'name', 'notify', 'reason'}` entry.
  ///
  /// `name` is resolved via [findAgentByDispatchName] (exact → case-insensitive
  /// → id → unique substring), or `"all"` (case-insensitive, expanded to every
  /// member). `notify` defaults to true; `reason` is trimmed and carried.
  /// Entries are deduped by agent id — first occurrence wins (including its
  /// notify/reason). Names matching no member are reported in [unresolved].
  /// Non-map items and empty names are skipped.
  static ({List<MentionEntry> mentions, List<String> unresolved})
      resolveMentionDeclarations(
    List<dynamic>? rawDeclarations,
    List<RemoteAgent> agents,
  ) {
    if (rawDeclarations == null || rawDeclarations.isEmpty || agents.isEmpty) {
      return (mentions: const [], unresolved: const []);
    }
    final mentions = <MentionEntry>[];
    final unresolved = <String>[];
    final seen = <String>{};

    void addEntry({
      required String requestedName,
      required bool notify,
      String? reason,
    }) {
      final agent = findAgentByDispatchName(agents, requestedName);
      if (agent == null) {
        if (!unresolved.contains(requestedName)) unresolved.add(requestedName);
        return;
      }
      if (seen.contains(agent.id)) return;
      seen.add(agent.id);
      mentions.add(MentionEntry(
        id: agent.id,
        name: agent.name,
        notify: notify,
        reason: (reason == null || reason.isEmpty) ? null : reason,
      ));
    }

    void handleName({
      required String name,
      required bool notify,
      String? reason,
    }) {
      if (normalizeMentionName(name).toLowerCase() == 'all') {
        for (final a in agents) {
          addEntry(requestedName: a.name, notify: notify, reason: reason);
        }
      } else {
        addEntry(requestedName: name, notify: notify, reason: reason);
      }
    }

    for (final raw in rawDeclarations) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final inner = map['mentions'];
      if (inner is List) {
        // group_mention tool-args shape.
        for (final item in inner) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          final name = (m['name'] as String?)?.trim() ?? '';
          if (name.isEmpty) continue;
          handleName(
            name: name,
            notify: m['notify'] as bool? ?? true,
            reason: (m['reason'] as String?)?.trim(),
          );
        }
      } else {
        // Metadata entry shape.
        final name = (map['name'] as String?)?.trim() ?? '';
        if (name.isEmpty) continue;
        handleName(
          name: name,
          notify: map['notify'] as bool? ?? true,
          reason: (map['reason'] as String?)?.trim(),
        );
      }
    }
    return (mentions: mentions, unresolved: unresolved);
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

  /// Matches ```json … ``` dispatch blocks (case-insensitive, multi-line).
  /// Leading whitespace is `[ \t]*` (not `\s*`) so a newline right before the
  /// fence survives stripping — text keeps its line breaks.
  static final RegExp dispatchJsonBlockPattern = RegExp(
    r'[ \t]*```json\s*[\s\S]*?```\s*',
    multiLine: true,
    caseSensitive: false,
  );

  /// Remove every ```json … ``` dispatch block from [content] so raw machine
  /// syntax never reaches the persisted chat text.
  static String stripDispatchJsonBlocks(String content) =>
      content.replaceAll(dispatchJsonBlockPattern, '').trimRight();

  /// Strip the ```json … ``` dispatch block from the last Admin message in
  /// [channelId] so that the raw JSON is never shown to the user.
  Future<void> stripDispatchJsonFromLastMessage(
    String channelId,
    String agentId,
  ) async {
    try {
      final messages = await _db.getChannelMessages(channelId, limit: 10);
      for (final m in messages) {
        if (m['sender_id'] == agentId &&
            m['content'] != null &&
            dispatchJsonBlockPattern.hasMatch(m['content'] as String)) {
          final cleaned =
              (m['content'] as String).replaceAll(dispatchJsonBlockPattern, '').trimRight();
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
