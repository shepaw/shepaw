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
