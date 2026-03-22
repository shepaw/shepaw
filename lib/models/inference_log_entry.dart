/// Status of an inference session.
enum InferenceStatus {
  inProgress,
  completed,
  error,
  cancelled,
}

/// A single event in the inference timeline.
class InferenceTimelineEvent {
  final DateTime timestamp;

  /// One of: `request`, `tool_call`, `tool_result`, `done`, `error`.
  final String type;

  final Map<String, dynamic> data;

  InferenceTimelineEvent({
    required this.timestamp,
    required this.type,
    this.data = const {},
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'type': type,
    'data': data,
  };
}

/// A single LLM request/response round within an inference session.
class InferenceRound {
  final int roundNumber;
  final DateTime startTime;
  DateTime? endTime;
  String? requestSummary;
  final StringBuffer textBuffer = StringBuffer();
  final List<Map<String, dynamic>> toolCalls = [];
  final List<Map<String, dynamic>> toolResults = [];
  String? stopReason;

  /// Full messages array sent to the LLM in this round (for trace persistence).
  List<Map<String, dynamic>>? messages;

  InferenceRound({
    required this.roundNumber,
    required this.startTime,
    this.messages,
  });

  Duration? get duration => endTime?.difference(startTime);

  Map<String, dynamic> toJson() => {
    'roundNumber': roundNumber,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'durationMs': duration?.inMilliseconds,
    'text': textBuffer.toString(),
    'toolCalls': toolCalls,
    'toolResults': toolResults,
    'stopReason': stopReason,
    'messageCount': messages?.length,
  };
}

/// A complete log entry for one inference session (user message → agent response).
class InferenceLogEntry {
  final String id;
  final DateTime startTime;
  DateTime? endTime;
  InferenceStatus status;

  // Agent info
  final String agentId;
  final String agentName;
  final String? channelId;
  final String? provider;
  final String? model;

  // Content
  final String userMessage;
  String? systemPrompt;

  // Rounds
  final List<InferenceRound> rounds = [];

  // Timeline
  final List<InferenceTimelineEvent> timeline = [];

  // Totals (derived)
  int totalTextChars = 0;
  int totalToolCalls = 0;

  // Error
  String? errorMessage;

  InferenceLogEntry({
    required this.id,
    required this.startTime,
    this.status = InferenceStatus.inProgress,
    required this.agentId,
    required this.agentName,
    this.channelId,
    this.provider,
    this.model,
    required this.userMessage,
    this.systemPrompt,
  });

  Duration? get duration => endTime?.difference(startTime);

  String get durationLabel {
    final d = duration;
    if (d == null) return '...';
    if (d.inSeconds < 1) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'durationMs': duration?.inMilliseconds,
    'status': status.name,
    'agentId': agentId,
    'agentName': agentName,
    'channelId': channelId,
    'provider': provider,
    'model': model,
    'userMessage': userMessage,
    'systemPrompt': systemPrompt,
    'rounds': rounds.map((r) => r.toJson()).toList(),
    'timeline': timeline.map((e) => e.toJson()).toList(),
    'totalTextChars': totalTextChars,
    'totalToolCalls': totalToolCalls,
    'errorMessage': errorMessage,
  };
}
