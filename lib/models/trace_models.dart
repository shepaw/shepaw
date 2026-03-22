import 'dart:convert';
import '../models/inference_log_entry.dart';

/// A complete trace for one inference session (user message → agent response).
class TraceEntry {
  final String id;
  final String? channelId;
  final String? agentId;
  final String agentName;
  final String? provider;
  final String? model;
  final String? executionMode;
  final String? systemPrompt;
  final String userMessage;
  final String? parentTraceId;
  final String? traceRole;
  InferenceStatus status;
  String? errorMessage;
  final DateTime startTime;
  DateTime? endTime;
  int? durationMs;
  int totalRounds;
  int totalToolCalls;
  int? totalInputTokens;
  int? totalOutputTokens;
  int totalTextChars;
  final DateTime createdAt;

  /// Loaded on demand — not stored in the main trace row.
  List<TraceSpan>? spans;

  TraceEntry({
    required this.id,
    this.channelId,
    this.agentId,
    required this.agentName,
    this.provider,
    this.model,
    this.executionMode,
    this.systemPrompt,
    required this.userMessage,
    this.parentTraceId,
    this.traceRole,
    this.status = InferenceStatus.inProgress,
    this.errorMessage,
    required this.startTime,
    this.endTime,
    this.durationMs,
    this.totalRounds = 0,
    this.totalToolCalls = 0,
    this.totalInputTokens,
    this.totalOutputTokens,
    this.totalTextChars = 0,
    required this.createdAt,
    this.spans,
  });

  Duration? get duration {
    if (durationMs != null) return Duration(milliseconds: durationMs!);
    if (endTime != null) return endTime!.difference(startTime);
    return null;
  }

  String get durationLabel {
    final d = duration;
    if (d == null) return '...';
    if (d.inSeconds < 1) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'channel_id': channelId,
    'agent_id': agentId,
    'agent_name': agentName,
    'provider': provider,
    'model': model,
    'execution_mode': executionMode,
    'system_prompt': systemPrompt,
    'user_message': userMessage,
    'parent_trace_id': parentTraceId,
    'trace_role': traceRole,
    'status': status.name,
    'error_message': errorMessage,
    'start_time': startTime.toIso8601String(),
    'end_time': endTime?.toIso8601String(),
    'duration_ms': durationMs,
    'total_rounds': totalRounds,
    'total_tool_calls': totalToolCalls,
    'total_input_tokens': totalInputTokens,
    'total_output_tokens': totalOutputTokens,
    'total_text_chars': totalTextChars,
    'created_at': createdAt.toIso8601String(),
  };

  factory TraceEntry.fromMap(Map<String, dynamic> map) => TraceEntry(
    id: map['id'] as String,
    channelId: map['channel_id'] as String?,
    agentId: map['agent_id'] as String?,
    agentName: map['agent_name'] as String,
    provider: map['provider'] as String?,
    model: map['model'] as String?,
    executionMode: map['execution_mode'] as String?,
    systemPrompt: map['system_prompt'] as String?,
    userMessage: map['user_message'] as String,
    parentTraceId: map['parent_trace_id'] as String?,
    traceRole: map['trace_role'] as String?,
    status: _parseStatus(map['status'] as String?),
    errorMessage: map['error_message'] as String?,
    startTime: DateTime.parse(map['start_time'] as String),
    endTime: map['end_time'] != null
        ? DateTime.parse(map['end_time'] as String)
        : null,
    durationMs: map['duration_ms'] as int?,
    totalRounds: map['total_rounds'] as int? ?? 0,
    totalToolCalls: map['total_tool_calls'] as int? ?? 0,
    totalInputTokens: map['total_input_tokens'] as int?,
    totalOutputTokens: map['total_output_tokens'] as int?,
    totalTextChars: map['total_text_chars'] as int? ?? 0,
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  Map<String, dynamic> toJson() => {
    ...toMap(),
    'spans': spans?.map((s) => s.toJson()).toList(),
  };

  static InferenceStatus _parseStatus(String? s) {
    switch (s) {
      case 'completed': return InferenceStatus.completed;
      case 'error': return InferenceStatus.error;
      case 'cancelled': return InferenceStatus.cancelled;
      default: return InferenceStatus.inProgress;
    }
  }
}

/// A single span within a trace: one LLM call round, or one tool call/result.
class TraceSpan {
  final String id;
  final String traceId;
  final String? parentSpanId;
  final String spanType; // 'llm_call' | 'tool_call' | 'tool_result'
  final String? name;
  final String? model; // model used for this span (populated for llm_call spans)
  final int sequenceNumber;
  final DateTime startTime;
  DateTime? endTime;
  int? durationMs;
  String status; // 'in_progress' | 'completed' | 'error'
  String? errorMessage;
  String? inputData;  // JSON string
  String? outputData; // JSON string
  String? metadata;  // JSON string

  TraceSpan({
    required this.id,
    required this.traceId,
    this.parentSpanId,
    required this.spanType,
    this.name,
    this.model,
    required this.sequenceNumber,
    required this.startTime,
    this.endTime,
    this.durationMs,
    this.status = 'in_progress',
    this.errorMessage,
    this.inputData,
    this.outputData,
    this.metadata,
  });

  Duration? get duration {
    if (durationMs != null) return Duration(milliseconds: durationMs!);
    if (endTime != null) return endTime!.difference(startTime);
    return null;
  }

  String get durationLabel {
    final d = duration;
    if (d == null) return '...';
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }

  Map<String, dynamic>? get inputDataJson {
    if (inputData == null) return null;
    try {
      return json.decode(inputData!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? get outputDataJson {
    if (outputData == null) return null;
    try {
      return json.decode(outputData!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? get metadataJson {
    if (metadata == null) return null;
    try {
      return json.decode(metadata!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'trace_id': traceId,
    'parent_span_id': parentSpanId,
    'span_type': spanType,
    'name': name,
    'model': model,
    'sequence_number': sequenceNumber,
    'start_time': startTime.toIso8601String(),
    'end_time': endTime?.toIso8601String(),
    'duration_ms': durationMs,
    'status': status,
    'error_message': errorMessage,
    'input_data': inputData,
    'output_data': outputData,
    'metadata': metadata,
  };

  factory TraceSpan.fromMap(Map<String, dynamic> map) => TraceSpan(
    id: map['id'] as String,
    traceId: map['trace_id'] as String,
    parentSpanId: map['parent_span_id'] as String?,
    spanType: map['span_type'] as String,
    name: map['name'] as String?,
    model: map['model'] as String?,
    sequenceNumber: map['sequence_number'] as int? ?? 0,
    startTime: DateTime.parse(map['start_time'] as String),
    endTime: map['end_time'] != null
        ? DateTime.parse(map['end_time'] as String)
        : null,
    durationMs: map['duration_ms'] as int?,
    status: map['status'] as String? ?? 'in_progress',
    errorMessage: map['error_message'] as String?,
    inputData: map['input_data'] as String?,
    outputData: map['output_data'] as String?,
    metadata: map['metadata'] as String?,
  );

  Map<String, dynamic> toJson() => toMap();
}
