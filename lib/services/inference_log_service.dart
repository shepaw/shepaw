import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/inference_log_entry.dart';
import 'trace_service.dart';

/// Singleton service that collects inference log entries.
///
/// Extends [ChangeNotifier] so the UI can rebuild when new entries arrive or
/// an in-progress entry updates. In-memory only, capped at [maxEntries].
///
/// Supports concurrent sessions — each active session is keyed by its sessionId.
/// Also delegates to [TraceService] for persistent SQLite-backed trace storage.
class InferenceLogService extends ChangeNotifier {
  InferenceLogService._();
  static final InferenceLogService instance = InferenceLogService._();

  static const int maxEntries = 100;
  static const int _maxToolResultChars = 2000;

  /// Master toggle — when false, all instrumentation calls are no-ops.
  bool enabled = true;

  final List<InferenceLogEntry> _entries = [];
  List<InferenceLogEntry> get entries => List.unmodifiable(_entries);

  // Active sessions keyed by sessionId — supports concurrent group agent calls
  final Map<String, InferenceLogEntry> _activeSessions = {};

  // Active llm_call span id per session
  final Map<String, String?> _activeRoundSpanIds = {};

  // Trace service reference for persistent storage
  final _trace = TraceService.instance;

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  /// Begin a new inference session.
  void beginSession({
    required String sessionId,
    required String agentId,
    required String agentName,
    String? channelId,
    String? provider,
    String? model,
    String? executionMode,
    required String userMessage,
    String? systemPrompt,
    String? parentTraceId,
    String? traceRole,
  }) {
    if (!enabled) return;

    final entry = InferenceLogEntry(
      id: sessionId,
      startTime: DateTime.now(),
      agentId: agentId,
      agentName: agentName,
      channelId: channelId,
      provider: provider,
      model: model,
      userMessage: userMessage,
      systemPrompt: systemPrompt,
    );

    entry.timeline.add(InferenceTimelineEvent(
      timestamp: DateTime.now(),
      type: 'request',
      data: {'userMessage': userMessage},
    ));

    _activeSessions[sessionId] = entry;
    _activeRoundSpanIds[sessionId] = null;
    _entries.insert(0, entry);

    // Cap the list
    while (_entries.length > maxEntries) {
      _entries.removeLast();
    }

    // Persist to trace database
    _trace.beginTrace(
      sessionId: sessionId,
      agentId: agentId,
      agentName: agentName,
      channelId: channelId,
      provider: provider,
      model: model,
      executionMode: executionMode,
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      parentTraceId: parentTraceId,
      traceRole: traceRole,
    );

    notifyListeners();
  }

  /// End the session identified by [sessionId].
  void endSession(String sessionId, InferenceStatus status, {String? error}) {
    if (!enabled) return;

    final active = _activeSessions.remove(sessionId);
    if (active == null) return;
    _activeRoundSpanIds.remove(sessionId);

    active.endTime = DateTime.now();
    active.status = status;
    if (error != null) {
      active.errorMessage = error;
      active.timeline.add(InferenceTimelineEvent(
        timestamp: DateTime.now(),
        type: 'error',
        data: {'error': error},
      ));
    } else {
      active.timeline.add(InferenceTimelineEvent(
        timestamp: DateTime.now(),
        type: 'done',
        data: {'status': status.name},
      ));
    }

    // Finalize totals
    int textChars = 0;
    int toolCalls = 0;
    for (final round in active.rounds) {
      textChars += round.textBuffer.length;
      toolCalls += round.toolCalls.length;
    }
    active.totalTextChars = textChars;
    active.totalToolCalls = toolCalls;

    // Persist final state
    _trace.endTrace(
      sessionId,
      status,
      error: error,
      totalTextChars: textChars,
    ).ignore();

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Round lifecycle
  // ---------------------------------------------------------------------------

  void beginRound(
    String sessionId, {
    String? requestSummary,
    List<Map<String, dynamic>>? messages,
  }) {
    if (!enabled) return;
    final active = _activeSessions[sessionId];
    if (active == null) return;

    final round = InferenceRound(
      roundNumber: active.rounds.length + 1,
      startTime: DateTime.now(),
      messages: messages,
    );
    round.requestSummary = requestSummary;
    active.rounds.add(round);

    // Record llm_call span
    final spanId = _trace.addSpan(
      traceId: sessionId,
      spanType: 'llm_call',
      name: requestSummary ?? 'Round ${round.roundNumber}',
      model: active.model,
      inputData: messages != null ? {'messages': messages} : null,
    );
    _activeRoundSpanIds[sessionId] = spanId;
    // No notifyListeners — too frequent
  }

  void endRound(String sessionId, {String? stopReason}) {
    if (!enabled) return;
    final active = _activeSessions[sessionId];
    if (active == null || active.rounds.isEmpty) return;

    final round = active.rounds.last;
    round.endTime = DateTime.now();
    round.stopReason = stopReason;

    active.timeline.add(InferenceTimelineEvent(
      timestamp: DateTime.now(),
      type: 'done',
      data: {
        'round': round.roundNumber,
        'stopReason': stopReason ?? 'unknown',
      },
    ));

    // Complete llm_call span
    final roundSpanId = _activeRoundSpanIds[sessionId];
    if (roundSpanId != null && roundSpanId.isNotEmpty) {
      _trace.endSpan(
        roundSpanId,
        outputData: {
          'text': round.textBuffer.toString(),
          'stopReason': stopReason ?? 'unknown',
        },
        status: 'completed',
      );
      _activeRoundSpanIds[sessionId] = null;
    }

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Streaming events
  // ---------------------------------------------------------------------------

  /// Accumulate text — no per-chunk notifyListeners to avoid flooding.
  void onTextChunk(String sessionId, String text) {
    if (!enabled) return;
    final active = _activeSessions[sessionId];
    if (active == null || active.rounds.isEmpty) return;
    active.rounds.last.textBuffer.write(text);
  }

  void onToolCall(
    String sessionId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
  }) {
    if (!enabled) return;
    final active = _activeSessions[sessionId];
    if (active == null || active.rounds.isEmpty) return;

    final sanitized = _redactKeys(arguments);
    active.rounds.last.toolCalls.add({
      'id': id,
      'name': name,
      'arguments': sanitized,
    });

    active.timeline.add(InferenceTimelineEvent(
      timestamp: DateTime.now(),
      type: 'tool_call',
      data: {'id': id, 'name': name},
    ));

    // Record tool_call span (child of current llm_call)
    final roundSpanId = _activeRoundSpanIds[sessionId];
    final toolSpanId = _trace.addSpan(
      traceId: sessionId,
      parentSpanId: roundSpanId,
      spanType: 'tool_call',
      name: name,
      inputData: {'id': id, 'arguments': sanitized},
    );
    // Store tool span id by tool call id for result matching
    active.rounds.last.toolCalls.last['_spanId'] = toolSpanId;
    // No notifyListeners during streaming
  }

  void onToolResult(
    String sessionId, {
    required String toolCallId,
    required String name,
    required String result,
  }) {
    if (!enabled) return;
    final active = _activeSessions[sessionId];
    if (active == null || active.rounds.isEmpty) return;

    final truncated = result.length > _maxToolResultChars
        ? '${result.substring(0, _maxToolResultChars)}... [truncated]'
        : result;

    active.rounds.last.toolResults.add({
      'tool_call_id': toolCallId,
      'name': name,
      'result': truncated,
    });

    active.timeline.add(InferenceTimelineEvent(
      timestamp: DateTime.now(),
      type: 'tool_result',
      data: {'tool_call_id': toolCallId, 'name': name},
    ));

    // Find the corresponding tool_call span and complete it
    final round = active.rounds.last;
    String? spanId;
    for (final tc in round.toolCalls) {
      if (tc['id'] == toolCallId) {
        spanId = tc['_spanId'] as String?;
        break;
      }
    }
    if (spanId != null && spanId.isNotEmpty) {
      _trace.endSpan(
        spanId,
        outputData: {'result': truncated},
        status: 'completed',
      );
    }
    // No notifyListeners during streaming
  }

  // ---------------------------------------------------------------------------
  // Management
  // ---------------------------------------------------------------------------

  /// Remove all entries associated with a given channel.
  void removeByChannel(String channelId) {
    _entries.removeWhere((e) => e.channelId == channelId);
    notifyListeners();
  }

  void clearAll() {
    _entries.clear();
    _activeSessions.clear();
    _activeRoundSpanIds.clear();
    notifyListeners();
  }

  String exportAsJson() {
    final data = _entries.map((e) => e.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Redact any key that looks like an API key.
  static final _keyPattern = RegExp(r'(api[_-]?key|secret|token|auth|password|credential)', caseSensitive: false);

  Map<String, dynamic> _redactKeys(Map<String, dynamic> input) {
    return input.map((key, value) {
      if (_keyPattern.hasMatch(key) && value is String) {
        return MapEntry(key, '[REDACTED]');
      }
      if (value is Map<String, dynamic>) {
        return MapEntry(key, _redactKeys(value));
      }
      return MapEntry(key, value);
    });
  }
}
