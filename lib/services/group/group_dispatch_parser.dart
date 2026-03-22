import 'dart:convert';
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
}

/// Pure parsing/utility functions for group chat dispatch.
class GroupDispatchParser {
  final LocalDatabaseService _db;

  GroupDispatchParser(this._db);

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
  ({List<DispatchStep> steps, bool wantsContinue, bool isDone})
      parseStructuredDispatch(String content, List<RemoteAgent> agents) {
    final match = RegExp(r'```json\s*([\s\S]*?)\s*```').firstMatch(content);
    if (match == null) {
      return (steps: [], wantsContinue: false, isDone: true);
    }

    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } catch (_) {
      return (steps: [], wantsContinue: false, isDone: true);
    }

    final isDone = parsed['done'] == true;
    final wantsContinue = parsed['continue'] == true;
    final dispatchData = parsed['dispatch'] as Map?;

    if (dispatchData == null || isDone) {
      return (steps: [], wantsContinue: wantsContinue, isDone: isDone);
    }

    final mode = (dispatchData['mode'] as String? ?? 'concurrent');
    final rawSteps = dispatchData['steps'] as List? ?? [];

    final steps = <DispatchStep>[];
    for (final s in rawSteps) {
      final agentNames = List<String>.from(s['agents'] as List? ?? []);
      final agentIds = agents
          .where((a) => agentNames.any((n) => n == a.name))
          .map((a) => a.id)
          .toList();
      if (agentIds.isEmpty) continue;
      steps.add(DispatchStep(
        step: (s['step'] as num).toInt(),
        agentIds: agentIds,
        task: s['task'] as String? ?? '',
        mode: mode,
      ));
    }

    steps.sort((a, b) => a.step.compareTo(b.step));

    return (steps: steps, wantsContinue: wantsContinue, isDone: false);
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
