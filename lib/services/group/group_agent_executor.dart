import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:uuid/uuid.dart';
import '../../models/group_task.dart';
import '../../models/message.dart';
import '../../models/mention_entry.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/llm_token_usage.dart';
import '../../models/inference_log_entry.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../cli_execution_gate.dart';
import '../../clis/shepaw/workflow/workflow_namespace.dart';
import '../../clis/shepaw/workflow/workflow_dispatch_command.dart';
import '../local_database_service.dart';
import '../local_llm_agent_service.dart';
import '../messaging/local_llm_handler.dart';
import '../messaging/chat_history_content.dart';
import '../acp_agent_connection.dart';
import '../file_download_service.dart';
import '../../storage/store_uri_reader.dart';
import '../inference_log_service.dart';
import '../trace_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../task/task_models.dart';
import '../mailbox/channel_mailbox_service.dart';
import '../messaging/connection_retry_policy.dart';
import 'group_dispatch_parser.dart';
import 'group_mailbox_save_plan.dart';
import 'group_orchestration_metadata.dart';
import 'group_orchestration_tools.dart';
import 'group_orchestration_features.dart';
import 'group_recon_first_gate.dart';
import 'group_member_capability_probe.dart';
import 'group_member_stall.dart';
import 'group_artifact_registry.dart';
import 'group_task_bootstrap.dart';
import 'group_session_create_service.dart';
import 'group_session_handoff.dart';
import 'group_context_builder.dart';
import 'group_prompt_builder.dart';
import 'group_turn_result.dart';
import 'group_turn_outcome.dart';
import 'group_task_status.dart';
import 'group_interaction_handler.dart';
import '../../peer/pouch_roster.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/peer_approval_selection.dart';
import 'peer_approval_policy.dart';
import '../workflow/workflow_service.dart';
import '../../models/workflow_pending_approval.dart';
import '../messaging/stream_content_splitter.dart';
import 'group_member_session_service.dart';
import 'group_member_history.dart';
import '../session/history_compactor.dart';
import '../session/history_compaction_cache_service.dart';
import '../session/session_slash_commands.dart';
import '../../storage/group_workspace_service.dart';
import '../../storage/runtime_paths.dart';
import '../../storage/store_protocol.dart';

/// Executes a single agent's response turn within a group chat.
///
/// Handles local LLM, peer P2P, and remote ACP execution paths, including
/// streaming, interaction escalation, file messages, and task lifecycle.
class GroupAgentExecutor {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final Map<String, Map<String, GroupActiveTask>> _activeGroupTasks;
  final GroupPromptBuilder _promptBuilder;
  final GroupInteractionHandler _interactionHandler;
  final void Function(String channelId) notifyChannelUpdate;
  final void Function() updateTypingAgentIds;
  final Future<ACPAgentConnection> Function(RemoteAgent agent)
      getOrCreateACPConnection;
  final Future<Message> Function({
    required RemoteAgent agent,
    required Message userMessage,
    required String sessionId,
    required String requestId,
    List<Map<String, dynamic>>? chatHistory,
    void Function(String chunk)? onStreamChunk,
    String? groupId,
    Map<String, dynamic>? groupContext,
    bool persistLeaveMetadata,
  })? leaveMailboxAndCollect;
  late final GroupMemberSessionService _memberSessions =
      GroupMemberSessionService(_db);
  late final GroupDispatchParser _dispatchParser = GroupDispatchParser(_db);

  GroupAgentExecutor({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, Map<String, GroupActiveTask>> activeGroupTasks,
    required GroupPromptBuilder promptBuilder,
    required GroupInteractionHandler interactionHandler,
    required this.notifyChannelUpdate,
    required this.updateTypingAgentIds,
    required this.getOrCreateACPConnection,
    this.leaveMailboxAndCollect,
  })  : _db = db,
        _uuid = uuid,
        _activeGroupTasks = activeGroupTasks,
        _promptBuilder = promptBuilder,
        _interactionHandler = interactionHandler;

  List<Map<String, dynamic>> buildGroupChatHistoryWithImages({
    required List<Map<String, dynamic>> historyMessages,
    required List<({AttachmentData attachment, String senderName})>
        imageEntries,
    required bool isClaude,
  }) {
    if (historyMessages.isEmpty && imageEntries.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    if (imageEntries.isEmpty) {
      return List<Map<String, dynamic>>.from(historyMessages);
    }

    // Attach historical images to the last user row (or a new one).
    final messages = List<Map<String, dynamic>>.from(historyMessages);
    final contentParts = <Map<String, dynamic>>[];
    if (messages.isNotEmpty && messages.last['role'] == 'user') {
      final prev = messages.last['content'];
      if (prev is String && prev.isNotEmpty) {
        contentParts.add({'type': 'text', 'text': prev});
      } else if (prev is List) {
        for (final part in prev) {
          if (part is Map<String, dynamic>) {
            contentParts.add(Map<String, dynamic>.from(part));
          }
        }
      }
      messages.removeLast();
    } else if (messages.isNotEmpty) {
      // Last row is assistant — keep a text recap as the image caption.
      contentParts.add({
        'type': 'text',
        'text': '以下是群聊历史中的图片：',
      });
    }

    for (final entry in imageEntries) {
      contentParts.add({
        'type': 'text',
        'text': '\n[以上历史中 ${entry.senderName} 发送的图片内容如下]',
      });

      if (isClaude) {
        contentParts.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': entry.attachment.mimeType,
            'data': entry.attachment.base64Data,
          },
        });
      } else {
        contentParts.add({
          'type': 'image_url',
          'image_url': {
            'url':
                'data:${entry.attachment.mimeType};base64,${entry.attachment.base64Data}',
          },
        });
      }
    }

    messages.add({'role': 'user', 'content': contentParts});
    return messages;
  }

  Future<void> saveGroupFileMessage({
    required Map<String, dynamic> fileData,
    required String agentId,
    required String agentName,
    required String channelId,
    required String userId,
    required String userName,
  }) async {
    try {
      final url = fileData['url'] as String?;
      final filename = fileData['filename'] as String?;
      final fileMimeType = fileData['mime_type'] as String?;
      int? size = (fileData['size'] as num?)?.toInt();
      final thumbnailBase64 = fileData['thumbnail_base64'] as String?;

      if (url == null || url.isEmpty) {
        LoggerService().warning(
            'Group file_message missing url from $agentName',
            tag: 'GroupAgentExecutor');
        return;
      }

      // pouch:// 引用已在本机储物袋中，无需下载；本地路径才需要立即复制。
      final isStoreUri = isPouchUri(url);

      // If the url is a local file path, try to copy the file immediately so the
      // user doesn't need to manually "download" it (local LLM agents produce files
      // that live on the same device and are accessible directly).
      String? copiedRelativePath;
      final isLocalPath = !isStoreUri &&
          !url.startsWith('http://') &&
          !url.startsWith('https://');
      if (isLocalPath) {
        try {
          final result = await FileDownloadService().downloadAndSave(
            url,
            fileName: filename,
            mimeType: fileMimeType,
          );
          copiedRelativePath = result.relativePath;
          size ??= result.fileSize;
        } catch (e) {
          LoggerService().warning('Could not pre-copy local file from $url: $e',
              tag: 'GroupAgentExecutor');
        }
      }

      // Agent 产物只给 pouch:// 引用时，向储物袋取真实大小用于展示。
      if (isStoreUri && (size == null || size == 0)) {
        try {
          size = await StoreUriReader.instance.sizeOf(url);
        } catch (_) {
          // 大小拿不到就保持原值，气泡会再尝试懒解析。
        }
      }

      // If size is missing or zero and url is a local path, read from filesystem
      if ((size == null || size == 0) && isLocalPath) {
        try {
          final f = File(url);
          if (await f.exists()) size = await f.length();
        } catch (_) {}
      }

      // Extract file_id from URL (e.g. http://host/files/{file_id})
      String? fileId;
      if (!isLocalPath) {
        try {
          final uri = Uri.parse(url);
          if (uri.pathSegments.length >= 2 &&
              uri.pathSegments[uri.pathSegments.length - 2] == 'files') {
            fileId = uri.pathSegments.last;
          }
        } catch (_) {}
      }

      final isImage = fileMimeType != null && fileMimeType.startsWith('image/');
      final msgType = isImage ? MessageType.image : MessageType.file;

      final metadata = <String, dynamic>{
        'source_url': url,
        'download_status':
            copiedRelativePath != null || isStoreUri ? 'completed' : 'pending',
        'name': filename ?? 'file',
        'type': fileMimeType ?? 'application/octet-stream',
        'size': size ?? 0,
      };

      if (isStoreUri) {
        metadata['pouch_uri'] = url;
      }
      if (copiedRelativePath != null) {
        metadata['path'] = copiedRelativePath;
      }
      if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
        metadata['thumbnail_base64'] = thumbnailBase64;
      }
      if (fileId != null) {
        metadata['file_id'] = fileId;
      }

      // M10: 毫秒时间戳 id 在同毫秒两条文件消息时冲突（ConflictAlgorithm.abort
      // + try/catch 吞异常 → 第二条静默丢失）。改用 uuid 保证唯一。
      final messageId = 'file_${_uuid.v4()}';
      await _db.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: agentName,
        content: isImage
            ? '[Image: ${filename ?? "image"}]'
            : '[File: ${filename ?? "file"}]',
        messageType: msgType.toString().split('.').last,
        metadata: metadata,
      );
      await _db.markMessageAsRead(messageId);
      notifyChannelUpdate(channelId);

      LoggerService().info(
          'Group file_message saved: ${filename ?? "file"} from $agentName',
          tag: 'GroupAgentExecutor');
    } catch (e) {
      LoggerService().error('Group file_message save error from $agentName',
          tag: 'GroupAgentExecutor', error: e);
    }
  }

  Future<GroupTurnResult> processGroupAgent({
    required RemoteAgent agent,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    required List<Message> historyMessages,
    required List<String> mentionedAgentIds,
    required bool isFirstMessage,
    bool isAdmin = false,
    Map<String, dynamic>? messageVersion,
    List<ChannelMember> channelMembers = const [],
    RemoteAgent? adminAgent,
    String? customSystemPrompt,
    bool isLoopSummarize = false,
    bool isAbortSummarize = false,
    bool isDispatchNudge = false,
    bool isPlanMissingNudge = false,
    bool isPendingStatusNudge = false,
    bool isPendingResolution = false,
    bool isStalledFollowUp = false,
    int? loopRound,
    /// Whether this orchestration has already consulted a member (any member
    /// turn has run). Drives [GroupReconFirstGate]: while false, the admin's
    /// user-facing clarification cards are bounced once so it does fact-finding
    /// first. Defaults to true — callers that never dispatch members (member
    /// turns, workflow steps) must not be gated.
    bool membersConsultedThisOrchestration = true,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    List<AttachmentData>? attachments,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName, Map<String, dynamic>)?
        onMessageMetadata,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
    bool isClosingSummary = false,
    bool isWorkflowStep = false,
    String? workflowId,
    String? workflowStepId,
    String? orchestrationTraceId,
    String? orchestrationId,
    int? orchestrationRound,
    String? groupFamilyId,
    List<String> historyPinSenderIds = const [],
    MemberCapabilitySnapshot? memberProbe,
    Duration? taskTimeout,
  }) async {
    onStreamChunk?.call(
      agent.id,
      agent.name,
      '群编排已经搬到 Hub，这台设备不再编排。',
    );
    onAgentDone?.call(agent.id, agent.name, true);
    return const GroupTurnResult(
      content: '群编排已经搬到 Hub，这台设备不再编排。',
      isDone: true,
    );
  }

  /// Surface a member's dispatch attempt that adminOnly mode refused, so the
  /// stripped JSON block never reads as a silent no-op.
  Future<void> _saveMemberDispatchDeniedHint({
    required String channelId,
    required String agentName,
  }) async {
    try {
      final msgId = _uuid.v4();
      await _db.createMessage(
        id: msgId,
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: '⚠️ 成员「$agentName」尝试派发其他成员，但当前群为「仅管理员」提及模式，未激活任何成员。',
        messageType: 'system',
      );
      await _db.markMessageAsRead(msgId);
      notifyChannelUpdate(channelId);
    } catch (e) {
      LoggerService().warning('Failed to save member dispatch denied hint',
          tag: 'GroupAgentExecutor', error: e);
    }
  }

  /// Compose a single text payload for peer relay: system prompt + history + turn.
  String _buildPeerGroupMessage({
    required String systemPrompt,
    required String historyLines,
    required String content,
    Map<String, dynamic>? groupContext,
  }) {
    final buf = StringBuffer();
    if (systemPrompt.isNotEmpty) {
      buf.writeln(systemPrompt);
      if (groupContext != null && groupContext.isNotEmpty) {
        buf.write(GroupContextBuilder.embedPeerContextBlock(groupContext));
      }
      buf.writeln();
    }
    if (historyLines.isNotEmpty) {
      buf.writeln('以下是群聊的历史记录：');
      buf.writeln();
      buf.writeln(historyLines);
      buf.writeln();
    }
    buf.write(content);
    return buf.toString();
  }

  Future<Message> _collectGroupMailboxReply({
    required RemoteAgent agent,
    required String content,
    required String userId,
    required String userName,
    required String sessionId,
    required String requestId,
    required String channelId,
    List<Map<String, dynamic>>? chatHistory,
    Map<String, dynamic>? groupContext,
    void Function(String chunk)? onChunk,
  }) async {
    final leave = leaveMailboxAndCollect;
    if (leave == null) {
      return Message(
        id: _uuid.v4(),
        content: '对方正忙，请稍后再试。',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        type: MessageType.system,
      );
    }
    final userMessage = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      to: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
      type: MessageType.text,
    );
    return leave(
      agent: agent,
      userMessage: userMessage,
      sessionId: sessionId,
      requestId: requestId,
      chatHistory: chatHistory,
      onStreamChunk: onChunk,
      groupId: channelId,
      groupContext: groupContext,
      persistLeaveMetadata: false,
    );
  }

  /// Local / peer / ACP catch: classify, log, unbind ACP, then either persist
  /// a pre-stream failure and throw, or return so the caller records
  /// mid-stream [error] (H2).
  ///
  /// M1: 不在执行器错误路径上报 onAgentDone——调用方 catch 持有该 turn 的
  /// 上报权。M11: ACP 错误路径统一 endRound/endSession，避免会话停在 running。
  Future<void> _handleExecutionPathError(
    Object error,
    StackTrace stackTrace, {
    required RemoteAgent agent,
    required String channelId,
    required GroupActiveTask groupTask,
    required String groupTraceId,
    required bool streamingStarted,
    required StringBuffer responseBuffer,
    required String pathLabel,
    ACPAgentConnection? connection,
    String? taskId,
    ACPCancellationToken? acpCancellationToken,
  }) async {
    LoggerService().error(
      'Group agent ${agent.name} $pathLabel error',
      tag: 'GroupAgentExecutor',
      error: error,
    );
    final infLog = InferenceLogService.instance;
    infLog.endRound(groupTraceId, stopReason: 'error');
    infLog.endSession(groupTraceId, InferenceStatus.error, error: '$error');
    if (connection != null && taskId != null) {
      connection.unregisterTaskCallbacks(taskId);
      acpCancellationToken?.unbind(connection, taskId);
    }
    final phase = GroupTurnOutcome.classifyFailure(
      streamingStarted: streamingStarted,
      responseBuffer: responseBuffer,
    );
    if (phase != GroupTurnFailurePhase.beforeStream) return;
    await _saveGroupSystemNotice(
      channelId: channelId,
      content: GroupTurnOutcome.failureNotice(
        agentName: agent.name,
        error: error,
        phase: phase,
      ),
    );
    _releaseGroupTurn(channelId, agent, groupTask);
    Error.throwWithStackTrace(error, stackTrace);
  }

  void _releaseGroupTurn(
    String channelId,
    RemoteAgent agent,
    GroupActiveTask groupTask,
  ) {
    groupTask.isComplete = true;
    groupTask.onTaskFinished?.call();
    _activeGroupTasks[channelId]?.remove(agent.id);
    if (_activeGroupTasks[channelId]?.isEmpty == true) {
      _activeGroupTasks.remove(channelId);
    }
    updateTypingAgentIds();
    ForegroundTaskService().releaseTask(agent.name);
  }

  Future<void> _saveGroupSystemNotice({
    required String channelId,
    required String content,
  }) async {
    final msg = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
    );
    await _db.createMessage(
      id: msg.id,
      channelId: channelId,
      senderId: 'system',
      senderType: 'system',
      senderName: 'System',
      content: msg.content,
      messageType: 'system',
    );
    await _db.markMessageAsRead(msg.id);
    notifyChannelUpdate(channelId);
  }

  Future<void> _saveGroupAgentErrorMessage({
    required String channelId,
    required String agentName,
    required Object error,
  }) =>
      _saveGroupSystemNotice(
        channelId: channelId,
        content: GroupTurnOutcome.failureNotice(
          agentName: agentName,
          error: error,
          phase: GroupTurnFailurePhase.beforeStream,
        ),
      );

  /// Apply a resolved approval onto [data] so the final saved message
  /// metadata (and any UI bound to it) shows the selected state.
  void _applyActionConfirmationSelection(
    Map<String, dynamic> data,
    Map<String, dynamic> responseData,
  ) {
    PeerApprovalSelection.applySelection(data, responseData);
  }

  Future<void> _handlePeerGroupActionConfirmation({
    required RemoteAgent agent,
    required String peerId,
    required String remoteAgentId,
    required String peerSessionId,
    required Map<String, dynamic> data,
    required RemoteAgent? adminAgent,
    required String channelId,
    required bool isWorkflowStep,
    String? workflowId,
    String? workflowStepId,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    Future<void> submit(Map<String, dynamic> responseData) async {
      await PeerAgentClientService.instance.submitApproval(
        peerId: peerId,
        approvalId: data['confirmation_id'] as String? ?? '',
        selectedActionId: responseData['selected_action_id'] as String? ?? '',
        selectedActionLabel: responseData['selected_action_label'] as String?,
      );
    }

    try {
      final allowAdminAuto =
          adminAgent != null && PeerApprovalPolicy.allowAdminAutoResolve(data);
      if (allowAdminAuto) {
        final responseData =
            await _interactionHandler.resolveInteractionViaAdmin(
          interactionType: 'action_confirmation',
          data: data,
          adminAgent: adminAgent,
          channelId: channelId,
          subAgentName: agent.name,
        );
        if (responseData != null) {
          await submit(responseData);
          _applyActionConfirmationSelection(data, responseData);
          if (isWorkflowStep && workflowId != null) {
            final cid = data['confirmation_id'] as String?;
            if (cid != null && cid.isNotEmpty) {
              await WorkflowService.instance.markPendingApprovalSubmitted(
                cid,
                selectedActionId: responseData['selected_action_id'] as String?,
              );
            }
          }
          _interactionHandler.saveAdminDecisionMessage(
            channelId: channelId,
            subAgentName: agent.name,
            interactionType: 'action_confirmation',
            chosenLabel: responseData['selected_action_label'] as String? ?? '',
          );
          return;
        }
      }

      if (isWorkflowStep) {
        // Workflow: block the step until the user (or a late admin path above)
        // resolves the in-band peer approval.
        final confirmationId =
            data['confirmation_id'] as String? ?? const Uuid().v4();
        if (workflowId != null &&
            workflowStepId != null &&
            confirmationId.isNotEmpty) {
          final approvalData = Map<String, dynamic>.from(data);
          approvalData['_workflowPeerApproval'] = true;
          approvalData['_workflowId'] = workflowId;
          approvalData['_workflowStepId'] = workflowStepId;
          approvalData['_approvalRisk'] =
              PeerApprovalPolicy.classifyRisk(data).name;
          await WorkflowService.instance.savePendingApproval(
            WorkflowPendingApproval(
              id: confirmationId,
              workflowId: workflowId,
              stepId: workflowStepId,
              channelId: channelId,
              agentId: agent.id,
              agentName: agent.name,
              peerId: peerId,
              remoteAgentId: remoteAgentId,
              confirmationId: confirmationId,
              peerSessionId: peerSessionId,
              approvalData: approvalData,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        if (onInteractionRequest != null) {
          final workflowData = Map<String, dynamic>.from(data);
          workflowData['_workflowPeerApproval'] = true;
          if (workflowId != null) workflowData['_workflowId'] = workflowId;
          if (workflowStepId != null) {
            workflowData['_workflowStepId'] = workflowStepId;
          }
          workflowData['_approvalRisk'] =
              PeerApprovalPolicy.classifyRisk(data).name;
          final userResponse = await onInteractionRequest(
            agent.id,
            agent.name,
            'action_confirmation',
            workflowData,
          );
          if (userResponse != null && userResponse['_non_blocking'] != true) {
            if (userResponse['_approval_submitted'] != true) {
              // Includes superseded approvals: still submit deny so the peer
              // client's openApprovals counter can drop and agent_done unblocks.
              await submit(userResponse);
            }
            if (userResponse['_superseded'] != true) {
              _applyActionConfirmationSelection(data, userResponse);
            }
          } else if (userResponse == null) {
            // Timeout / cancelled: still reply so the peer hub can unblock
            // (openApprovals would otherwise hold agent_done forever).
            // Skip if the user already submitted via another controller
            // (e.g. switched channels after tapping Allow).
            final approvalId = data['confirmation_id'] as String? ?? '';
            if (PeerAgentClientService.instance
                .hasSubmittedApproval(approvalId)) {
              LoggerService().info(
                'Peer workflow approval timed out for ${agent.name} but '
                'verdict already submitted; skipping auto-deny '
                'confirmationId=$approvalId',
                tag: 'GroupAgentExecutor',
              );
            } else {
              final deny = <String, dynamic>{
                'selected_action_id': 'deny',
                'selected_action_label': '拒绝',
              };
              LoggerService().warning(
                'Peer workflow approval timed out for ${agent.name}; '
                'auto-denying confirmationId=${data['confirmation_id']}',
                tag: 'GroupAgentExecutor',
              );
              try {
                await submit(deny);
                _applyActionConfirmationSelection(data, deny);
              } catch (e) {
                LoggerService().error(
                  'Failed to auto-deny timed-out peer approval',
                  tag: 'GroupAgentExecutor',
                  error: e,
                );
              }
            }
          }
        }
        return;
      }

      // Non-workflow: surface the card; user tap submits via handleActionSelected.
      if (onInteractionRequest != null) {
        await onInteractionRequest(
          agent.id,
          agent.name,
          'action_confirmation',
          Map<String, dynamic>.from(data),
        );
      }

      // User will tap the card; handleActionSelected(peer) calls submitApproval.
      // Do not auto-pick a default — the peer hub blocks until explicit approval.
    } catch (e) {
      LoggerService().error(
        'Peer group action_confirmation error for ${agent.name}',
        tag: 'GroupAgentExecutor',
        error: e,
      );
      // Surface to the outer peer send path (saves an error bubble) and to any
      // ChatController snackbar that awaits the approval chain.
      rethrow;
    }
  }

  /// Group agents go through [CliExecutionGate]. Non-admin members are
  /// limited to the `store` and `help` namespaces.
  Future<String> _executeShepawCliForGroup({
    required Map<String, dynamic> args,
    required RemoteAgent agent,
    required bool isAdmin,
    required String channelId,
  }) async {
    String? runtimeOwnerId;
    try {
      final ch = await _db.getChannelById(channelId);
      if (ch != null) {
        runtimeOwnerId = RuntimePaths.resolveStoreTarget(
          agentId: agent.id,
          channelId: channelId,
          channelType: ch.type,
          parentGroupId: ch.parentGroupId,
          sourceGroupChannelId: ch.sourceGroupChannelId,
        ).ownerId;
      }
    } catch (_) {}
    return CliExecutionGate.instance.execute(
      args: args,
      agentId: agent.id,
      channelId: channelId,
      runtimeOwnerId: runtimeOwnerId,
      enabledCliCommands: agent.enabledCliCommands,
      extraAllowlist: isAdmin ? null : kGroupMemberCliAllowlist,
      requireApproval: agent.cliRequireApproval,
    );
  }

  /// Pack group transcript for this turn.
  ///
  /// Members get a slim slice (recent tail + own replies + omitted-URI
  /// index, plus a peeked compaction cache if one exists). Admin / summarize
  /// / abort / closing turns keep the admin window and may trigger LLM
  /// compaction for local agents.
  Future<
      ({
        List<Message> effectiveHistory,
        String? earlierSummary,
        String? truncationNote,
      })> _prepareGroupHistory({
    required RemoteAgent agent,
    required String channelId,
    required List<Message> historyMessages,
    required bool isAdmin,
    required bool isLoopSummarize,
    required bool isAbortSummarize,
    required bool isClosingSummary,
    ACPCancellationToken? acpCancellationToken,
    List<String> historyPinSenderIds = const [],
    RemoteAgent? adminAgent,
  }) async {
    historyMessages =
        historyMessages.where(ChatHistoryContent.shouldReplay).toList();
    final useFullHistory = GroupMemberHistory.needsFullHistory(
      isAdmin: isAdmin,
      isLoopSummarize: isLoopSummarize,
      isAbortSummarize: isAbortSummarize,
      isClosingSummary: isClosingSummary,
    );

    if (!useFullHistory) {
      final pack = GroupMemberHistory.pack(
        messages: historyMessages,
        memberId: agent.id,
        pinSenderIds: historyPinSenderIds,
      );
      String? earlierSummary;
      // P2: all members (including remote ACP/peer) share the channel
      // compaction cache when admin/local turns have warmed it.
      final peeked =
          await HistoryCompactionCacheService.peekSummary(channelId);
      if (peeked.isNotEmpty) {
        earlierSummary = peeked;
      } else if (pack.droppedAny &&
          adminAgent != null &&
          adminAgent.isLocal &&
          acpCancellationToken?.isCancelled != true) {
        // Cold cache: one-off summarize this member's omitted slice so remote
        // agents are not left with only rollup text on long threads.
        final transcript = HistoryCompactor.buildTranscript(pack.dropped);
        if (transcript.trim().length >=
            HistoryCompactor.minOlderCharsToSummarize) {
          try {
            final cancelKey =
                'group_member_compact_${agent.id}_${_uuid.v4()}';
            acpCancellationToken?.addOnCancelled(() {
              LocalLLMAgentService.instance.abort(cancelKey);
            });
            final summary = await _summarizeHistoryForCompaction(
              agent: adminAgent,
              transcript: transcript,
              cancelKey: cancelKey,
            );
            if (summary.isNotEmpty) earlierSummary = summary;
          } catch (e) {
            LoggerService().warning(
              'Group member dropped-history summarize failed for ${agent.name}: $e',
              tag: 'GroupAgentExecutor',
            );
          }
        }
      }
      if (pack.droppedAny) {
        LoggerService().info(
          'Group member history slimmed for ${agent.name}: '
          'kept ${pack.kept.length}/${historyMessages.length} msgs '
          '(${pack.kept.fold<int>(0, (s, m) => s + m.content.length)} chars)'
          '${earlierSummary != null ? '; summary=${earlierSummary.length} chars' : ''}',
          tag: 'GroupAgentExecutor',
        );
      }
      return (
        effectiveHistory: pack.kept,
        earlierSummary: earlierSummary,
        truncationNote: pack.truncationPrefix.isEmpty
            ? null
            : pack.truncationPrefix,
      );
    }

    const maxHistoryChars = GroupMemberHistory.adminMaxChars;
    var effectiveHistory = List<Message>.from(historyMessages);
    String? earlierSummary;
    // M6: 无 LLM 摘要时的截断提示（远端成员 / 摘要失败兜底），区别于 LLM 摘要，
    // 直接用原文插入，避免再套一层 summaryMessage 包装。
    String? truncationNote;

    List<Message> truncateWithNote(List<Message> msgs) {
      final kept = HistoryCompactor.fifoTruncate(msgs, maxHistoryChars);
      if (kept.length < msgs.length) {
        truncationNote = HistoryCompactor.rollupNote(
          msgs.sublist(0, msgs.length - kept.length),
        );
      }
      return kept;
    }

    if (agent.isLocal) {
      final plan = HistoryCompactor.plan(
        messages: effectiveHistory,
        maxChars: maxHistoryChars,
        keepRecentCount: GroupMemberHistory.adminKeepRecentCount,
        keepRecentChars: GroupMemberHistory.adminKeepRecentChars,
      );
      if (plan.needsCompaction && acpCancellationToken?.isCancelled != true) {
        try {
          final cancelKey = 'group_compact_${agent.id}_${_uuid.v4()}';
          acpCancellationToken?.addOnCancelled(() {
            LocalLLMAgentService.instance.abort(cancelKey);
          });
          earlierSummary = await HistoryCompactionCacheService.obtainSummary(
            channelId: channelId,
            older: plan.older,
            summarize: (transcript) => _summarizeHistoryForCompaction(
              agent: agent,
              transcript: transcript,
              cancelKey: cancelKey,
            ),
          );
          effectiveHistory = plan.recent;
          if (earlierSummary.isNotEmpty) {
            final summaryCost = earlierSummary.length + 80;
            effectiveHistory = HistoryCompactor.trimRecentToBudget(
              effectiveHistory,
              maxChars: HistoryCompactor.recentBudgetAfterSummary(
                summaryChars: summaryCost,
                maxChars: maxHistoryChars,
                keepRecentChars: GroupMemberHistory.adminKeepRecentChars,
              ),
            );
            LoggerService().info(
              'Group history compacted for ${agent.name}: '
              '${plan.older.length} older → ${earlierSummary.length} chars; '
              'keeping ${effectiveHistory.length} recent',
              tag: 'GroupAgentExecutor',
            );
          } else {
            earlierSummary = null;
            effectiveHistory = truncateWithNote(historyMessages);
          }
        } catch (e) {
          LoggerService().warning(
            'Group history compaction failed for ${agent.name}, '
            'falling back to truncate: $e',
            tag: 'GroupAgentExecutor',
          );
          earlierSummary = null;
          effectiveHistory = truncateWithNote(historyMessages);
        }
      }
    } else {
      // Remote ACP admin / summarize turns have no local LLM summarizer.
      // Keep the admin-char recent tail and surface the omission with a rollup.
      effectiveHistory = truncateWithNote(historyMessages);
    }

    return (
      effectiveHistory: effectiveHistory,
      earlierSummary: earlierSummary,
      truncationNote: truncationNote,
    );
  }

  /// One-shot LLM summary of older group turns for in-context compaction.
  Future<String> _summarizeHistoryForCompaction({
    required RemoteAgent agent,
    required String transcript,
    required Object cancelKey,
  }) async {
    return '';
  }
}
