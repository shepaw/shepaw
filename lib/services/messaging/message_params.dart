import 'dart:async';
import '../../models/message.dart';
import '../../models/attachment_data.dart';
import '../acp_agent_connection.dart';
import '../../clis/shepaw/os/os_executor.dart' as os_exec;

/// Parameter object replacing the 18-argument [sendMessageToAgent] signature.
class AgentMessageParams {
  final String content;
  final String userId;
  final String userName;
  final String? channelId;
  final String? replyToId;
  final void Function(String chunk)? onStreamChunk;
  final void Function(Map<String, dynamic> actionData)? onActionConfirmation;
  final void Function(Map<String, dynamic> selectData)? onSingleSelect;
  final void Function(Map<String, dynamic> selectData)? onMultiSelect;
  final void Function(Map<String, dynamic> uploadData)? onFileUpload;
  final void Function(Map<String, dynamic> formData)? onForm;
  final Future<void> Function(Map<String, dynamic> fileData)? onFileMessage;
  final void Function(Map<String, dynamic> metadata)? onMessageMetadata;
  final void Function(Map<String, dynamic> historyRequestData)? onRequestHistory;
  final Future<bool> Function(String toolName, Map<String, dynamic> args, os_exec.RiskLevel risk)? onOsToolConfirmation;
  final ACPCancellationToken? acpCancellationToken;
  final List<AttachmentData>? attachments;
  final Message? existingUserMessage;

  const AgentMessageParams({
    required this.content,
    required this.userId,
    required this.userName,
    this.channelId,
    this.replyToId,
    this.onStreamChunk,
    this.onActionConfirmation,
    this.onSingleSelect,
    this.onMultiSelect,
    this.onFileUpload,
    this.onForm,
    this.onFileMessage,
    this.onMessageMetadata,
    this.onRequestHistory,
    this.onOsToolConfirmation,
    this.acpCancellationToken,
    this.attachments,
    this.existingUserMessage,
  });
}

/// Parameter object for group message sending.
class GroupMessageParams {
  final String channelId;
  final String content;
  final String userId;
  final String userName;
  final List<String> agentIds;
  final List<String> mentionedAgentIds;
  final bool mentionOnlyMode;
  final String? adminAgentId;
  final String? replyToId;
  final bool flowMode;
  final Map<String, dynamic>? userMessageMetadata;
  final ACPCancellationToken? acpCancellationToken;
  final void Function(String agentId, String agentName, String chunk)? onStreamChunk;
  final void Function(String agentId, String agentName)? onAgentStart;
  final void Function(String agentId, String agentName, bool skipped)? onAgentDone;
  final void Function()? onAllDone;
  final Future<Map<String, dynamic>?> Function(
    String agentId, String agentName, String interactionType, Map<String, dynamic> data,
  )? onInteractionRequest;

  const GroupMessageParams({
    required this.channelId,
    required this.content,
    required this.userId,
    required this.userName,
    required this.agentIds,
    this.mentionedAgentIds = const [],
    this.mentionOnlyMode = false,
    this.adminAgentId,
    this.replyToId,
    this.flowMode = false,
    this.userMessageMetadata,
    this.acpCancellationToken,
    this.onStreamChunk,
    this.onAgentStart,
    this.onAgentDone,
    this.onAllDone,
    this.onInteractionRequest,
  });
}
