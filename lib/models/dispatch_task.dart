/// She 单聊任务派发记录。
///
/// 生命周期：pending → running → done | error | timeout。
/// She 在 1:1 会话里通过 `shepaw context agents.dispatch` 创建；
/// [DispatchService] 跟踪执行、超时与结果回传。
class DispatchTask {
  static const String statusPending = 'pending';
  static const String statusRunning = 'running';
  static const String statusDone = 'done';
  static const String statusError = 'error';
  static const String statusTimeout = 'timeout';

  /// 派发记录 id（uuid）
  final String id;

  /// She↔用户 的会话频道（结果回传目标）
  final String sourceChannelId;

  /// 被执行 agent
  final String targetAgentId;
  final String targetAgentName;

  /// 被执行 agent 的 DM 频道（任务实际执行处）
  final String targetChannelId;

  /// She 在目标频道里发出的任务消息 id（用 replyTo 精确匹配完成事件）
  final String? userMessageId;

  /// 源频道里的派发状态消息 id（完成后更新其内容）
  final String? statusMessageId;

  /// 任务简报（发给被执行 agent 的完整指令）
  final String prompt;

  final String status;

  /// 执行结果摘要（截断存储）
  final String? resultSummary;
  final String? errorMessage;

  final int createdAtMs;
  final int? completedAtMs;

  const DispatchTask({
    required this.id,
    required this.sourceChannelId,
    required this.targetAgentId,
    required this.targetAgentName,
    required this.targetChannelId,
    this.userMessageId,
    this.statusMessageId,
    required this.prompt,
    required this.status,
    this.resultSummary,
    this.errorMessage,
    required this.createdAtMs,
    this.completedAtMs,
  });

  bool get isTerminal =>
      status == statusDone ||
      status == statusError ||
      status == statusTimeout;

  DispatchTask copyWith({
    String? userMessageId,
    String? statusMessageId,
    String? status,
    String? resultSummary,
    String? errorMessage,
    int? completedAtMs,
  }) =>
      DispatchTask(
        id: id,
        sourceChannelId: sourceChannelId,
        targetAgentId: targetAgentId,
        targetAgentName: targetAgentName,
        targetChannelId: targetChannelId,
        userMessageId: userMessageId ?? this.userMessageId,
        statusMessageId: statusMessageId ?? this.statusMessageId,
        prompt: prompt,
        status: status ?? this.status,
        resultSummary: resultSummary ?? this.resultSummary,
        errorMessage: errorMessage ?? this.errorMessage,
        createdAtMs: createdAtMs,
        completedAtMs: completedAtMs ?? this.completedAtMs,
      );

  factory DispatchTask.fromJson(Map<String, dynamic> json) => DispatchTask(
        id: json['id'] as String,
        sourceChannelId: json['source_channel_id'] as String,
        targetAgentId: json['target_agent_id'] as String,
        targetAgentName: json['target_agent_name'] as String? ?? '',
        targetChannelId: json['target_channel_id'] as String,
        userMessageId: json['user_message_id'] as String?,
        statusMessageId: json['status_message_id'] as String?,
        prompt: json['prompt'] as String? ?? '',
        status: json['status'] as String? ?? statusPending,
        resultSummary: json['result_summary'] as String?,
        errorMessage: json['error_message'] as String?,
        createdAtMs: (json['created_at'] as num?)?.toInt() ?? 0,
        completedAtMs: (json['completed_at'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source_channel_id': sourceChannelId,
        'target_agent_id': targetAgentId,
        'target_agent_name': targetAgentName,
        'target_channel_id': targetChannelId,
        'user_message_id': userMessageId,
        'status_message_id': statusMessageId,
        'prompt': prompt,
        'status': status,
        'result_summary': resultSummary,
        'error_message': errorMessage,
        'created_at': createdAtMs,
        'completed_at': completedAtMs,
      };
}
