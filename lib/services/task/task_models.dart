import 'dart:async';
import '../../clis/shepaw/os/os_executor.dart' as os_exec;

/// Tracks an in-flight ACP task so it can continue in the background
/// when the user navigates away from the chat screen.
class ActiveTask {
  final String taskId;
  final String agentId;
  final String agentName;
  final String channelId;
  final String userMessageId;
  final String userId;
  final String userName;

  String accumulatedContent = '';
  Map<String, dynamic>? metadata;
  bool isComplete = false;
  String? errorMessage;

  /// Timestamp when this task was created.
  final int startedAtMs = DateTime.now().millisecondsSinceEpoch;

  /// Set to true when the task was interrupted because the app was
  /// backgrounded and the underlying connection died.
  bool wasInterruptedByBackground = false;

  // ==================== Streaming Flush Fields ====================
  
  /// Database ID of the partial message being flushed to DB.
  /// Set when first streaming chunk arrives and flushing begins.
  /// Used to update (upsert) the same message record on subsequent flushes.
  String? partialMessageId;

  /// Timestamp (milliseconds) of the last flush to the database.
  /// Used to calculate elapsed time for periodic flushing.
  int? lastFlushTimestampMs;

  /// Content length (in characters) at the time of last flush.
  /// Used to track how much new content has accumulated since last flush.
  int lastFlushedContentLength = 0;

  /// Whether this task was interrupted before completion.
  /// Set to true when connection drops, user cancels, or timeout occurs.
  bool isInterrupted = false;

  /// Reason why the task was interrupted (if interrupted).
  /// Values: 'connection_lost', 'user_cancelled', 'task_error', 'timeout', etc.
  String? interruptionReason;

  /// Timestamp (milliseconds) when interruption occurred.
  /// Useful for UI to show "interrupted 2 minutes ago".
  int? interruptedAtMs;

  // ===================================================================

  /// Completes after the agent response has been persisted to the database.
  /// UI should await this before reloading messages.
  final Completer<void> dbSaveCompleter = Completer<void>();

  // Detachable UI callbacks — set to null when user leaves the screen
  void Function(String chunk)? onStreamChunk;
  void Function(Map<String, dynamic>)? onActionConfirmation;
  void Function(Map<String, dynamic>)? onSingleSelect;
  void Function(Map<String, dynamic>)? onMultiSelect;
  void Function(Map<String, dynamic>)? onFileUpload;
  void Function(Map<String, dynamic>)? onForm;
  Future<void> Function(Map<String, dynamic>)? onFileMessage;
  void Function(Map<String, dynamic>)? onMessageMetadata;
  void Function(Map<String, dynamic>)? onRequestHistory;

  /// OS tool confirmation callback — returns true if user approves.
  Future<bool> Function(String toolName, Map<String, dynamic> args, os_exec.RiskLevel risk)? onOsToolConfirmation;

  /// Called when the task finishes (complete or error) so the UI can refresh.
  void Function()? onTaskFinished;

  ActiveTask({
    required this.taskId,
    required this.agentId,
    required this.agentName,
    required this.channelId,
    required this.userMessageId,
    required this.userId,
    required this.userName,
  });

  /// Determine if streaming content should be flushed based on time/content accumulation.
  ///
  /// Returns true if:
  /// - Time since last flush (or task start) exceeds [flushIntervalMs], OR
  /// - Content accumulated since last flush exceeds [contentThreshold]
  bool shouldFlush({
    int flushIntervalMs = 2000,
    int contentThreshold = 500,
  }) {
    if (accumulatedContent.isEmpty) return false;

    // Never flushed before → use task start time as baseline
    if (lastFlushTimestampMs == null) {
      final timeSinceStart =
          DateTime.now().millisecondsSinceEpoch - startedAtMs;
      return timeSinceStart >= flushIntervalMs ||
          accumulatedContent.length >= contentThreshold;
    }

    // Already flushed → use last flush as baseline
    final timeSinceFlush =
        DateTime.now().millisecondsSinceEpoch - lastFlushTimestampMs!;
    final contentSinceFlush = accumulatedContent.length - lastFlushedContentLength;

    return timeSinceFlush >= flushIntervalMs ||
        contentSinceFlush >= contentThreshold;
  }

  /// Record a successful flush to the database.
  /// Should be called after [upsertPartialStreamingMessage] succeeds.
  void recordFlush(String messageId) {
    partialMessageId = messageId;
    lastFlushTimestampMs = DateTime.now().millisecondsSinceEpoch;
    lastFlushedContentLength = accumulatedContent.length;
  }

  /// Record an interruption event.
  /// Should be called when connection drops, user cancels, or timeout occurs.
  void recordInterruption(String reason) {
    isInterrupted = true;
    interruptionReason = reason;
    interruptedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  void detachUI() {
    onStreamChunk = null;
    onActionConfirmation = null;
    onSingleSelect = null;
    onMultiSelect = null;
    onFileUpload = null;
    onForm = null;
    onFileMessage = null;
    onMessageMetadata = null;
    onRequestHistory = null;
    onOsToolConfirmation = null;
    onTaskFinished = null;
  }
}

/// Tracks an in-flight group agent task so it can continue in the background
/// when the user navigates away from the chat screen.
/// Unlike [ActiveTask] (keyed by channelId, one per channel), group chats may
/// have multiple concurrent agents per channel, so these are keyed by
/// channelId -> agentId.
class GroupActiveTask {
  final String agentId;
  final String agentName;
  final String channelId;
  String accumulatedContent = '';
  bool isComplete = false;

  // Detachable UI callbacks — set to null when user leaves the screen
  void Function(String chunk)? onStreamChunk;
  void Function()? onTaskFinished;

  GroupActiveTask({
    required this.agentId,
    required this.agentName,
    required this.channelId,
  });

  void detachUI() {
    onStreamChunk = null;
    onTaskFinished = null;
  }
}
