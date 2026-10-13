/// ACP 回合的共用契约：回调束与取消令牌。
///
/// 这些以前住在 `acp_agent_connection.dart` 里，但 peer 路径也在用（群编排、
/// 本地 LLM、主机侧回合）。直连 ACP 退役后挪到这里，免得为了一个取消令牌去
/// 依赖整个连接实现。
library;

class ACPCancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _cancelCallbacks = [];

  bool get isCancelled => _isCancelled;

  /// Register a callback invoked synchronously when [cancel] is called.
  /// Used by the chat service to complete task completers locally.
  void addOnCancelled(void Function() callback) {
    if (_isCancelled) {
      callback();
      return;
    }
    _cancelCallbacks.add(callback);
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    // Notify local listeners first so the UI unblocks immediately.
    for (final cb in List.of(_cancelCallbacks)) {
      try {
        cb();
      } catch (_) {}
    }
  }
}

/// Per-task callback bundle, keyed by task_id on the transport.
class TaskCallbacks {
  final void Function(Map<String, dynamic> data)? onTextContent;
  final void Function(Map<String, dynamic> data)? onActionConfirmation;
  final void Function(Map<String, dynamic> data)? onSingleSelect;
  final void Function(Map<String, dynamic> data)? onMultiSelect;
  final void Function(Map<String, dynamic> data)? onFileUpload;
  final void Function(Map<String, dynamic> data)? onForm;
  final Future<void> Function(Map<String, dynamic> data)? onFileMessage;
  final void Function(Map<String, dynamic> data)? onMessageMetadata;
  final void Function(Map<String, dynamic> data)? onRequestHistory;
  final void Function(Map<String, dynamic> data)? onTaskStarted;
  final void Function(Map<String, dynamic> data)? onTaskCompleted;
  final void Function(Map<String, dynamic> data)? onTaskError;

  /// 任一该任务的通知帧到达时触发（无参数）。供停滞看门狗刷新活动时间戳，
  /// 单点覆盖 task.started / ui.* / task.completed / task.error 全部入站活动。
  final void Function()? onTaskActivity;

  const TaskCallbacks({
    this.onTextContent,
    this.onActionConfirmation,
    this.onSingleSelect,
    this.onMultiSelect,
    this.onFileUpload,
    this.onForm,
    this.onFileMessage,
    this.onMessageMetadata,
    this.onRequestHistory,
    this.onTaskStarted,
    this.onTaskCompleted,
    this.onTaskError,
    this.onTaskActivity,
  });
}

/// 兜底超时：远端 ACP agent 单回合任务的等待上限。
///
/// 半开/失活连接由 30s 心跳在秒级
/// 发现并断开，断开时会 `_failInFlightTasks` 立即解阻塞等待方；此常量只是
/// 「连接存活但某任务永不完成」的后备保险。原先 3h 会让用户在编排循环 /
/// 门闸 / 收尾总结里干等半天。正常远端回合（含流式）远小于此值；超时抛
/// [TimeoutException] 由调用方按失败处理。
const Duration acpTaskTimeout = Duration(minutes: 10);
