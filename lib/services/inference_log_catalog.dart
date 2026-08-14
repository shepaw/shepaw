import '../models/inference_log_entry.dart';
import '../models/trace_models.dart';

/// Unified row for the inference-log list (live session and/or persisted trace).
class InferenceLogRow {
  final String id;
  final DateTime startTime;
  final InferenceStatus status;
  final String agentName;
  final String? model;
  final String? provider;
  final String? executionMode;
  final String? traceRole;
  final String userMessage;
  final String? errorMessage;
  final String durationLabel;
  final int rounds;
  final int toolCalls;
  final int inputTokens;
  final int outputTokens;
  final InferenceLogEntry? live;
  final TraceEntry? persisted;

  const InferenceLogRow({
    required this.id,
    required this.startTime,
    required this.status,
    required this.agentName,
    this.model,
    this.provider,
    this.executionMode,
    this.traceRole,
    required this.userMessage,
    this.errorMessage,
    required this.durationLabel,
    required this.rounds,
    required this.toolCalls,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.live,
    this.persisted,
  });

  factory InferenceLogRow.fromLive(InferenceLogEntry entry) {
    return InferenceLogRow(
      id: entry.id,
      startTime: entry.startTime,
      status: entry.status,
      agentName: entry.agentName,
      model: entry.model,
      provider: entry.provider,
      executionMode: entry.executionMode,
      traceRole: entry.traceRole,
      userMessage: entry.userMessage,
      errorMessage: entry.errorMessage,
      durationLabel: entry.durationLabel,
      rounds: entry.rounds.length,
      toolCalls: entry.totalToolCalls,
      inputTokens: entry.totalInputTokens,
      outputTokens: entry.totalOutputTokens,
      live: entry,
    );
  }

  factory InferenceLogRow.fromTrace(TraceEntry trace) {
    return InferenceLogRow(
      id: trace.id,
      startTime: trace.startTime,
      status: trace.status,
      agentName: trace.agentName,
      model: trace.model,
      provider: trace.provider,
      executionMode: trace.executionMode,
      traceRole: trace.traceRole,
      userMessage: trace.userMessage,
      errorMessage: trace.errorMessage,
      durationLabel: trace.durationLabel,
      rounds: trace.totalRounds,
      toolCalls: trace.totalToolCalls,
      inputTokens: trace.totalInputTokens ?? 0,
      outputTokens: trace.totalOutputTokens ?? 0,
      persisted: trace,
    );
  }

  bool get isProblem =>
      status == InferenceStatus.error ||
      (errorMessage != null && errorMessage!.isNotEmpty);

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return agentName.toLowerCase().contains(q) ||
        (model?.toLowerCase().contains(q) ?? false) ||
        (provider?.toLowerCase().contains(q) ?? false) ||
        (executionMode?.toLowerCase().contains(q) ?? false) ||
        (traceRole?.toLowerCase().contains(q) ?? false) ||
        userMessage.toLowerCase().contains(q) ||
        (errorMessage?.toLowerCase().contains(q) ?? false);
  }
}

class InferenceLogCatalog {
  InferenceLogCatalog._();

  /// Live sessions overlay persisted traces (same id keeps the live copy).
  static List<InferenceLogRow> merge({
    required List<InferenceLogEntry> live,
    required List<TraceEntry> persisted,
  }) {
    final byId = <String, InferenceLogRow>{};
    for (final trace in persisted) {
      byId[trace.id] = InferenceLogRow.fromTrace(trace);
    }
    for (final entry in live) {
      byId[entry.id] = InferenceLogRow.fromLive(entry);
    }
    final rows = byId.values.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return rows;
  }

  static List<InferenceLogRow> filter(
    Iterable<InferenceLogRow> rows, {
    InferenceStatus? status,
    String? query,
    bool problemsOnly = false,
  }) {
    return rows.where((row) {
      if (problemsOnly && !row.isProblem) return false;
      if (status != null && row.status != status) return false;
      if (query == null || query.trim().isEmpty) return true;
      return row.matchesQuery(query);
    }).toList();
  }
}
