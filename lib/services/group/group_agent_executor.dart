import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/inference_log_entry.dart';
import '../../models/planning_models.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../../clis/shepaw/workflow/workflow_namespace.dart';
import '../../clis/shepaw/workflow/workflow_dispatch_command.dart';
import '../local_database_service.dart';
import '../local_llm_agent_service.dart';
import '../messaging/local_llm_handler.dart';
import '../acp_agent_connection.dart';
import '../file_download_service.dart';
import '../inference_log_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../task/task_models.dart';
import 'group_prompt_builder.dart';
import 'group_interaction_handler.dart';
import '../messaging/local_llm_handler.dart';

/// Executes a single agent's response turn within a group chat.
///
/// Handles both local LLM and remote ACP execution paths, including
/// streaming, interaction escalation, file messages, and task lifecycle.
class GroupAgentExecutor {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final Map<String, ACPAgentConnection> _acpConnections;
  final Map<String, Map<String, GroupActiveTask>> _activeGroupTasks;
  final GroupPromptBuilder _promptBuilder;
  final GroupInteractionHandler _interactionHandler;
  final void Function(String channelId) notifyChannelUpdate;
  final void Function() updateTypingAgentIds;
  final Future<ACPAgentConnection> Function(RemoteAgent agent) getOrCreateACPConnection;

  GroupAgentExecutor({
    required LocalDatabaseService db,
    required Uuid uuid,
    required Map<String, ACPAgentConnection> acpConnections,
    required Map<String, Map<String, GroupActiveTask>> activeGroupTasks,
    required GroupPromptBuilder promptBuilder,
    required GroupInteractionHandler interactionHandler,
    required this.notifyChannelUpdate,
    required this.updateTypingAgentIds,
    required this.getOrCreateACPConnection,
  })  : _db = db,
        _uuid = uuid,
        _acpConnections = acpConnections,
        _activeGroupTasks = activeGroupTasks,
        _promptBuilder = promptBuilder,
        _interactionHandler = interactionHandler;

  List<Map<String, dynamic>> buildGroupChatHistoryWithImages({
    required String historyText,
    required List<({AttachmentData attachment, String senderName})> imageEntries,
    required bool isClaude,
  }) {
    if (historyText.isEmpty && imageEntries.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    if (imageEntries.isEmpty) {
      // Plain text fallback — same as before.
      return [
        {'role': 'user', 'content': '以下是群聊的历史记录：\n\n$historyText'},
      ];
    }

    // Build multimodal content array.
    final contentParts = <Map<String, dynamic>>[];

    // Leading text.
    contentParts.add({'type': 'text', 'text': '以下是群聊的历史记录：\n\n$historyText'});

    // Append each image with sender annotation.
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

    return [
      {'role': 'user', 'content': contentParts},
    ];
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
        LoggerService().warning('Group file_message missing url from $agentName', tag: 'GroupAgentExecutor');
        return;
      }

      // If the url is a local file path, try to copy the file immediately so the
      // user doesn't need to manually "download" it (local LLM agents produce files
      // that live on the same device and are accessible directly).
      String? copiedRelativePath;
      final isLocalPath = !url.startsWith('http://') && !url.startsWith('https://');
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
          LoggerService().warning('Could not pre-copy local file from $url: $e', tag: 'GroupAgentExecutor');
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
        'download_status': copiedRelativePath != null ? 'completed' : 'pending',
        'name': filename ?? 'file',
        'type': fileMimeType ?? 'application/octet-stream',
        'size': size ?? 0,
      };

      if (copiedRelativePath != null) {
        metadata['path'] = copiedRelativePath;
      }
      if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
        metadata['thumbnail_base64'] = thumbnailBase64;
      }
      if (fileId != null) {
        metadata['file_id'] = fileId;
      }

      final messageId = 'file_${DateTime.now().millisecondsSinceEpoch}';
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

      LoggerService().info('Group file_message saved: ${filename ?? "file"} from $agentName', tag: 'GroupAgentExecutor');
    } catch (e) {
      LoggerService().error('Group file_message save error from $agentName', tag: 'GroupAgentExecutor', error: e);
    }
  }

  Future<void> processGroupAgent({
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
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    Future<Map<String, dynamic>?> Function(
      String agentId, String agentName, String interactionType, Map<String, dynamic> data,
    )? onInteractionRequest,
    bool isFlowMode = false,
    String? orchestrationTraceId,
  }) async {
    LoggerService().debug('_processGroupAgent START: ${agent.name} (isAdmin=$isAdmin, isLocal=${agent.isLocal})', tag: 'GroupAgentExecutor');
    final systemPrompt = _promptBuilder.buildGroupSystemPrompt(
      groupName: groupName,
      groupDescription: groupDescription,
      allAgents: allAgents,
      currentAgent: agent,
      channelMembers: channelMembers,
      isMentioned: mentionedAgentIds.contains(agent.id),
      isAdmin: isAdmin,
      customSystemPrompt: customSystemPrompt,
      isLoopSummarize: isLoopSummarize,
      isAbortSummarize: isAbortSummarize,
      loopRound: loopRound,
      mentionMode: mentionMode,
      failedAgentNames: failedAgentNames,
      isFlowMode: isFlowMode,
    );

    // Build chat history: pack the entire group conversation into a single
    // 'user' message so the LLM's identity comes solely from the system prompt.
    // Each line is tagged with the sender name so the agent can see who said
    // what, while "(我)" marks its own prior messages.
    final historyLines = historyMessages.map((m) {
      final content = (m.type != MessageType.text && m.type != MessageType.system)
          ? '${m.content} [id:${m.id}]'
          : m.content;
      if (m.from.isAgent && m.from.id == agent.id) {
        return '[${m.from.name}(我)]: $content';
      }
      final tag = m.from.isAgent ? 'Agent' : 'User';
      return '[${m.from.name}($tag)]: $content';
    }).join('\n\n');

    final responseBuffer = StringBuffer();
    bool streamingStarted = false;
    // Capture UI tool call data for interactive components
    Map<String, dynamic>? actionConfirmationData;
    Map<String, dynamic>? singleSelectData;
    Map<String, dynamic>? multiSelectData;
    Map<String, dynamic>? fileUploadData;
    Map<String, dynamic>? formDataCapture;
    Map<String, dynamic>? messageMetadataExtra;

    // Register a GroupActiveTask so the UI can reattach after navigating away
    final groupTask = GroupActiveTask(
      agentId: agent.id,
      agentName: agent.name,
      channelId: channelId,
    );
    _activeGroupTasks.putIfAbsent(channelId, () => {});
    _activeGroupTasks[channelId]![agent.id] = groupTask;
    updateTypingAgentIds();
    ForegroundTaskService().acquireTask(agent.name);

    // Trace instrumentation for group agent
    final infLogGroup = InferenceLogService.instance;
    final groupTraceId = _uuid.v4();
    infLogGroup.beginSession(
      sessionId: groupTraceId,
      agentId: agent.id,
      agentName: agent.name,
      channelId: channelId,
      provider: agent.metadata['llm_provider'] as String?,
      model: agent.metadata['llm_model'] as String?,
      executionMode: agent.isLocal ? 'group_local' : 'group_remote_acp',
      userMessage: content,
      systemPrompt: systemPrompt,
      parentTraceId: orchestrationTraceId,
      traceRole: isAdmin ? 'group_admin' : 'group_member',
    );

    if (agent.isLocal) {
      // ── Local LLM agent path ──
      // Determine provider type so we can build the correct multimodal format.
      final isClaude = LocalLLMAgentService.instance
              .resolveProviderType(agent) ==
          'claude';

      // Do NOT load history image bytes for group chat. The group chat()
      // call does not pass `attachments`, so _classifyAndResolve always
      // picks the text model — embedding images in history would cause the
      // text model to fail with a 400 error and trigger the "model does not
      // support images" warning on every single message. The text
      // placeholder (e.g. "[Image: photo.jpg]") in historyLines already
      // provides sufficient context.
      final chatHistory = buildGroupChatHistoryWithImages(
        historyText: historyLines,
        imageEntries: const [],
        isClaude: isClaude,
      );

      // Build the full message list for multi-turn tool calling
      final roundMessages = <Map<String, dynamic>>[
        ...chatHistory,
        {'role': 'user', 'content': content},
      ];
      const maxToolRounds = 5;

      infLogGroup.beginRound(
        groupTraceId,
        requestSummary: 'Group round 1',
        messages: [
          if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
          ...roundMessages,
        ],
      );

      try {
        for (int toolRound = 0; toolRound < maxToolRounds; toolRound++) {
          final pawToolCalls = <LLMToolCallEvent>[];
          final pawToolResults = <Map<String, dynamic>>[];
          LLMDoneEvent? doneEvent;

          await for (final event in LocalLLMAgentService.instance.chat(
            agent: agent,
            message: toolRound == 0 ? content : '', // Only first round has original message
            history: toolRound == 0
                ? (chatHistory.isNotEmpty ? chatHistory : null)
                : roundMessages,
            enableUITools: true,
            includeShepawCli: isAdmin,
            systemPromptOverride: systemPrompt,
          )) {
            if (acpCancellationToken?.isCancelled == true) break;
            switch (event) {
              case LLMTextEvent():
                streamingStarted = true;
                responseBuffer.write(event.text);
                groupTask.accumulatedContent += event.text;
                groupTask.onStreamChunk?.call(event.text);
                onStreamChunk?.call(agent.id, agent.name, event.text);
                infLogGroup.onTextChunk(groupTraceId, event.text);
                break;
              case LLMToolCallEvent():
                infLogGroup.onToolCall(groupTraceId, id: event.id, name: event.name, arguments: event.arguments);
                switch (event.name) {
                  case 'file_message':
                    await saveGroupFileMessage(
                      fileData: event.arguments,
                      agentId: agent.id,
                      agentName: agent.name,
                      channelId: channelId,
                      userId: userId,
                      userName: userName,
                    );
                    break;
                  case 'action_confirmation':
                    actionConfirmationData = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'single_select':
                    singleSelectData = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'multi_select':
                    multiSelectData = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'file_upload':
                    fileUploadData = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'form':
                    formDataCapture = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'message_metadata':
                    messageMetadataExtra = Map<String, dynamic>.from(event.arguments);
                    break;
                  default:
                    // Handle shepaw CLI tool calls
                    if (ShepawCLI.instance.isPawTool(event.name)) {
                      // Inject channel_id into the args
                      final args = Map<String, dynamic>.from(event.arguments);
                      final flags = args['flags'] is Map
                          ? Map<String, dynamic>.from(args['flags'] as Map)
                          : <String, dynamic>{};
                      flags['channel_id'] = channelId;
                      args['flags'] = flags;

                      // Set workflow namespace context (per-channel for C1 safety)
                      WorkflowNamespace.instance.setContext(channelId, agent.id);

                      // Wire up dispatch command's step execution callback (per-channel)
                      WorkflowDispatchCommand.setExecuteStepFn(channelId, (agentName, instruction, chId) async {
                        final targetAgent = allAgents.cast<RemoteAgent?>().firstWhere(
                          (a) => a!.name == agentName,
                          orElse: () => null,
                        );
                        if (targetAgent == null) {
                          return '[Error] Agent "$agentName" not found in group members.';
                        }
                        final stepBuffer = StringBuffer();
                        await processGroupAgent(
                          agent: targetAgent,
                          channelId: chId,
                          content: instruction,
                          userId: userId,
                          userName: userName,
                          groupName: groupName,
                          groupDescription: groupDescription,
                          allAgents: allAgents,
                          historyMessages: historyMessages,
                          mentionedAgentIds: [targetAgent.id],
                          isFirstMessage: false,
                          messageVersion: messageVersion,
                          channelMembers: channelMembers,
                          customSystemPrompt: customSystemPrompt,
                          mentionMode: mentionMode,
                          acpCancellationToken: acpCancellationToken,
                          onStreamChunk: (aid, anm, chunk) {
                            stepBuffer.write(chunk);
                            onStreamChunk?.call(aid, anm, chunk);
                          },
                          onAgentDone: onAgentDone,
                          onInteractionRequest: onInteractionRequest,
                        );
                        return stepBuffer.toString();
                      });

                      // Execute CLI command
                      final cliResult = await ShepawCLI.instance.execute(args, agentId: agent.id);
                      LoggerService().info(
                        'CLI result (${args['namespace']} ${args['subcommand'] ?? ''}): ${cliResult.length > 200 ? '${cliResult.substring(0, 200)}...' : cliResult}',
                        tag: 'GroupAgentExecutor',
                      );
                      infLogGroup.onToolResult(groupTraceId, toolCallId: event.id, name: event.name, result: cliResult);

                      // Collect for multi-turn
                      pawToolCalls.add(event);
                      pawToolResults.add({
                        'tool_call_id': event.id,
                        'name': event.name,
                        'result': cliResult,
                      });

                      // Handle workflow create approval flow
                      try {
                        final cliJson = json.decode(cliResult) as Map<String, dynamic>?;
                        if (cliJson != null && cliJson['status'] == 'pending_approval') {
                          final workflowId = cliJson['workflow_id'] as String?;
                          final planDataRaw = cliJson['_plan_data'] as Map<String, dynamic>?;
                          if (workflowId != null && planDataRaw != null && onInteractionRequest != null) {
                            await onInteractionRequest?.call(
                              agent.id, agent.name, 'plan_approval',
                              {...planDataRaw, '_workflowId': workflowId, '_non_blocking': true},
                            );
                          }
                        }
                      } catch (e) {
                        LoggerService().warning('Workflow approval flow error: $e', tag: 'GroupAgentExecutor');
                      }
                    }
                    break;
                }
                break;
              case LLMDoneEvent():
                doneEvent = event;
                infLogGroup.endRound(groupTraceId, stopReason: event.stopReason);
                break;
            }
          }

          // If there were CLI tool calls AND we have a rawAssistantMessage,
          // feed results back to LLM for continuation (multi-turn).
          if (pawToolCalls.isNotEmpty && doneEvent?.rawAssistantMessage != null) {
            LoggerService().info(
              'Multi-turn: ${pawToolCalls.length} tool calls in round ${toolRound + 1}, continuing...',
              tag: 'GroupAgentExecutor',
            );
            if (isClaude) {
              LocalLLMHelpers.appendToolRoundClaude(
                  roundMessages, doneEvent!.rawAssistantMessage!, pawToolCalls, pawToolResults);
            } else {
              LocalLLMHelpers.appendToolRoundOpenAI(
                  roundMessages, doneEvent!.rawAssistantMessage!, pawToolCalls, pawToolResults);
            }
            infLogGroup.beginRound(groupTraceId, requestSummary: 'Group round ${toolRound + 2}');
            continue; // Next round
          }

          // No tool calls or stream done — exit loop
          break;
        }
      } catch (e) {
        LoggerService().error('Group agent ${agent.name} stream error', tag: 'GroupAgentExecutor', error: e);
        infLogGroup.endRound(groupTraceId, stopReason: 'error');
        infLogGroup.endSession(groupTraceId, InferenceStatus.error, error: '$e');
        if (!streamingStarted || responseBuffer.isEmpty) {
          // Insert a visible error message so the user knows which agent failed.
          final errorMsg = Message(
            id: _uuid.v4(),
            content: '⚠️ Agent「${agent.name}」调用失败：$e',
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            from: MessageFrom(id: 'system', type: 'system', name: 'System'),
            type: MessageType.system,
          );
          await _db.createMessage(
            id: errorMsg.id,
            channelId: channelId,
            senderId: 'system',
            senderType: 'system',
            senderName: 'System',
            content: errorMsg.content,
            messageType: 'system',
          );
          await _db.markMessageAsRead(errorMsg.id);
          notifyChannelUpdate(channelId);

          groupTask.isComplete = true;
          groupTask.onTaskFinished?.call();
          _activeGroupTasks[channelId]?.remove(agent.id);
          if (_activeGroupTasks[channelId]?.isEmpty == true) {
            _activeGroupTasks.remove(channelId);
          }
          updateTypingAgentIds();
          ForegroundTaskService().releaseTask(agent.name);
          onAgentDone?.call(agent.id, agent.name, true);
          return;
        }
      }
    } else {
      // ── Remote ACP agent path ──
      // Build plain-text history with attachment_info for media messages
      // so remote agents can use hub.getAttachmentContent to fetch content.
      final acpHistoryEntries = <Map<String, dynamic>>[];
      if (historyLines.isNotEmpty) {
        final entry = <String, dynamic>{
          'role': 'user',
          'content': '以下是群聊的历史记录：\n\n$historyLines',
        };

        // Collect attachment info for image/file/audio messages.
        final attachments = <Map<String, dynamic>>[];
        for (final m in historyMessages) {
          if (m.type == MessageType.image ||
              m.type == MessageType.file ||
              m.type == MessageType.audio) {
            attachments.add(LocalLLMHelpers.buildAttachmentInfo(m));
          }
        }
        if (attachments.isNotEmpty) {
          entry['attachment_info'] = attachments;
        }

        acpHistoryEntries.add(entry);
      }

      ACPAgentConnection? connection;
      String? taskId;
      final taskCompleter = Completer<void>();

      try {
        connection = await getOrCreateACPConnection(agent);
        taskId = _uuid.v4();

        infLogGroup.beginRound(groupTraceId, requestSummary: 'Group ACP request');

        // Bind cancellation token so the UI can stop this agent
        if (acpCancellationToken != null) {
          acpCancellationToken.bind(connection!, taskId!);
          acpCancellationToken.onCancelled = () {
            if (!taskCompleter.isCompleted) {
              taskCompleter.complete();
            }
          };
        }

        final effectiveTaskId = taskId!;
        final effectiveConnection = connection!;
        effectiveConnection.registerTaskCallbacks(effectiveTaskId, TaskCallbacks(
          onTextContent: (data) {
            final chunk = data['content'] as String? ?? '';
            streamingStarted = true;
            responseBuffer.write(chunk);
            groupTask.accumulatedContent += chunk;
            groupTask.onStreamChunk?.call(chunk);
            onStreamChunk?.call(agent.id, agent.name, chunk);
            infLogGroup.onTextChunk(groupTraceId, chunk);
          },
          onTaskCompleted: (data) {
            infLogGroup.endRound(groupTraceId, stopReason: 'stop');
            infLogGroup.endSession(groupTraceId, InferenceStatus.completed);
            if (!taskCompleter.isCompleted) {
              taskCompleter.complete();
            }
          },
          onTaskError: (data) {
            final errorMsg = data['message'] as String? ?? 'Task error';
            infLogGroup.endRound(groupTraceId, stopReason: 'error');
            infLogGroup.endSession(groupTraceId, InferenceStatus.error, error: errorMsg);
            if (!taskCompleter.isCompleted) {
              taskCompleter.completeError(
                Exception(data['message'] ?? 'Task error'),
              );
            }
          },
          onActionConfirmation: (data) async {
            if (adminAgent != null) {
              try {
                var responseData = await _interactionHandler.resolveInteractionViaAdmin(
                  interactionType: 'action_confirmation',
                  data: data,
                  adminAgent: adminAgent,
                  channelId: channelId,
                  subAgentName: agent.name,
                );
                if (responseData != null) {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'action_confirmation',
                    responseData: responseData,
                  );
                  _interactionHandler.saveAdminDecisionMessage(
                    channelId: channelId,
                    subAgentName: agent.name,
                    interactionType: 'action_confirmation',
                    chosenLabel: responseData['selected_action_label'] as String? ?? '',
                  );
                  return;
                }
              } catch (e) {
                LoggerService().error('Admin decision error (action_confirmation)', tag: 'GroupAgentExecutor', error: e);
              }
            }
            // No admin or admin returned null (ASK_USER) — escalate to user
            if (onInteractionRequest != null) {
              final userResponse = await onInteractionRequest(agent.id, agent.name, 'action_confirmation', data);
              if (userResponse != null && userResponse['_non_blocking'] != true) {
                try {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'action_confirmation',
                    responseData: userResponse,
                  );
                } catch (_) {}
                return;
              }
            }
            // Fallback to default option
            final fallback = _interactionHandler.pickDefaultOption('action_confirmation', data);
            if (fallback != null) {
              try {
                await effectiveConnection.submitResponse(
                  taskId: effectiveTaskId,
                  responseType: 'action_confirmation',
                  responseData: fallback,
                );
              } catch (_) {}
            }
          },
          onSingleSelect: (data) async {
            if (adminAgent != null) {
              try {
                var responseData = await _interactionHandler.resolveInteractionViaAdmin(
                  interactionType: 'single_select',
                  data: data,
                  adminAgent: adminAgent,
                  channelId: channelId,
                  subAgentName: agent.name,
                );
                if (responseData != null) {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'single_select',
                    responseData: responseData,
                  );
                  _interactionHandler.saveAdminDecisionMessage(
                    channelId: channelId,
                    subAgentName: agent.name,
                    interactionType: 'single_select',
                    chosenLabel: responseData['selected_option_label'] as String? ?? '',
                  );
                  return;
                }
              } catch (e) {
                LoggerService().error('Admin decision error (single_select)', tag: 'GroupAgentExecutor', error: e);
              }
            }
            // No admin or admin returned null (ASK_USER) — escalate to user
            if (onInteractionRequest != null) {
              final userResponse = await onInteractionRequest(agent.id, agent.name, 'single_select', data);
              if (userResponse != null && userResponse['_non_blocking'] != true) {
                try {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'single_select',
                    responseData: userResponse,
                  );
                } catch (_) {}
                return;
              }
            }
            // Fallback to default option
            final fallback = _interactionHandler.pickDefaultOption('single_select', data);
            if (fallback != null) {
              try {
                await effectiveConnection.submitResponse(
                  taskId: effectiveTaskId,
                  responseType: 'single_select',
                  responseData: fallback,
                );
              } catch (_) {}
            }
          },
          onMultiSelect: (data) async {
            if (adminAgent != null) {
              try {
                var responseData = await _interactionHandler.resolveInteractionViaAdmin(
                  interactionType: 'multi_select',
                  data: data,
                  adminAgent: adminAgent,
                  channelId: channelId,
                  subAgentName: agent.name,
                );
                if (responseData != null) {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'multi_select',
                    responseData: responseData,
                  );
                  final ids = responseData['selected_option_ids'] as List<dynamic>? ?? [];
                  _interactionHandler.saveAdminDecisionMessage(
                    channelId: channelId,
                    subAgentName: agent.name,
                    interactionType: 'multi_select',
                    chosenLabel: ids.join(', '),
                  );
                  return;
                }
              } catch (e) {
                LoggerService().error('Admin decision error (multi_select)', tag: 'GroupAgentExecutor', error: e);
              }
            }
            // No admin or admin returned null (ASK_USER) — escalate to user
            if (onInteractionRequest != null) {
              final userResponse = await onInteractionRequest(agent.id, agent.name, 'multi_select', data);
              if (userResponse != null && userResponse['_non_blocking'] != true) {
                try {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'multi_select',
                    responseData: userResponse,
                  );
                } catch (_) {}
                return;
              }
            }
            // Fallback to default option
            final fallback = _interactionHandler.pickDefaultOption('multi_select', data);
            if (fallback != null) {
              try {
                await effectiveConnection.submitResponse(
                  taskId: effectiveTaskId,
                  responseType: 'multi_select',
                  responseData: fallback,
                );
              } catch (_) {}
            }
          },
          onForm: (data) async {
            // Forms are too complex for auto-decision; escalate to user
            if (onInteractionRequest != null) {
              final userResponse = await onInteractionRequest(agent.id, agent.name, 'form', data);
              if (userResponse != null && userResponse['_non_blocking'] != true) {
                try {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'form',
                    responseData: userResponse,
                  );
                } catch (_) {}
                return;
              }
            }
            LoggerService().debug('Form interaction from ${agent.name} — non-blocking, user will submit next turn', tag: 'GroupAgentExecutor');
            final fallback = _interactionHandler.pickDefaultOption('form', data);
            if (fallback != null) {
              try {
                await effectiveConnection.submitResponse(
                  taskId: effectiveTaskId,
                  responseType: 'form',
                  responseData: fallback,
                );
              } catch (_) {}
            }
          },
          onFileUpload: (data) async {
            // File uploads cannot be auto-decided; escalate to user
            if (onInteractionRequest != null) {
              final userResponse = await onInteractionRequest(agent.id, agent.name, 'file_upload', data);
              if (userResponse != null && userResponse['_non_blocking'] != true) {
                try {
                  await effectiveConnection.submitResponse(
                    taskId: effectiveTaskId,
                    responseType: 'file_upload',
                    responseData: userResponse,
                  );
                } catch (_) {}
                return;
              }
            }
            LoggerService().debug('File upload interaction from ${agent.name} — non-blocking, user will submit next turn', tag: 'GroupAgentExecutor');
          },
          onFileMessage: (data) async {
            await saveGroupFileMessage(
              fileData: data,
              agentId: agent.id,
              agentName: agent.name,
              channelId: channelId,
              userId: userId,
              userName: userName,
            );
          },
        ));

        // Build group_context for remote agents
        final groupContext = <String, dynamic>{
          'group_id': channelId,
          'group_name': groupName,
          'group_description': groupDescription,
          'member_count': allAgents.length,
          'members': allAgents.map((a) => <String, dynamic>{
            'id': a.id,
            'name': a.name,
            'type': 'agent',
            'bio': a.bio ?? '',
            'capabilities': a.capabilities,
            'status': a.isOnline ? 'online' : 'offline',
          }).toList(),
          'is_first_message': isFirstMessage,
          if (messageVersion != null)
            'message_version': messageVersion,
        };

        await effectiveConnection.sendChatMessage(
          taskId: effectiveTaskId,
          sessionId: channelId,
          message: content,
          userId: userId,
          messageId: _uuid.v4(),
          history: acpHistoryEntries.isNotEmpty ? acpHistoryEntries : null,
          systemPrompt: systemPrompt,
          groupContext: groupContext,
        );

        await taskCompleter.future.timeout(
          const Duration(seconds: 300),
          onTimeout: () {
            throw TimeoutException('ACP group task timed out for ${agent.name}');
          },
        );

        effectiveConnection.unregisterTaskCallbacks(effectiveTaskId);
      } catch (e) {
        LoggerService().error('Group agent ${agent.name} ACP error', tag: 'GroupAgentExecutor', error: e);
        if (connection != null && taskId != null) {
          connection!.unregisterTaskCallbacks(taskId!);
        }
        if (!streamingStarted || responseBuffer.isEmpty) {
          groupTask.isComplete = true;
          groupTask.onTaskFinished?.call();
          _activeGroupTasks[channelId]?.remove(agent.id);
          if (_activeGroupTasks[channelId]?.isEmpty == true) {
            _activeGroupTasks.remove(channelId);
          }
          updateTypingAgentIds();
          ForegroundTaskService().releaseTask(agent.name);
          onAgentDone?.call(agent.id, agent.name, true);
          return;
        }
      }
    }

    // End session for local LLM path (remote ACP ends in onTaskCompleted/onTaskError callbacks)
    if (agent.isLocal) {
      final wasCancelled = acpCancellationToken?.isCancelled == true;
      infLogGroup.endSession(groupTraceId, wasCancelled ? InferenceStatus.cancelled : InferenceStatus.completed);
    }

    var responseContent = responseBuffer.toString().trim();

    // Strip redundant agent name prefix that LLMs sometimes echo from chat history
    // e.g. "[local1]: 你好" or "[local1(Agent)]: 你好" → "你好"
    final prefixPattern = RegExp(r'^\[' + RegExp.escape(agent.name) + r'(?:\(Agent\))?\]\s*[:：]\s*');
    responseContent = responseContent.replaceFirst(prefixPattern, '');

    if (responseContent.isEmpty || responseContent.contains('[SKIP]')) {
      LoggerService().debug('Agent ${agent.name} skipped', tag: 'GroupAgentExecutor');
      groupTask.isComplete = true;
      groupTask.onTaskFinished?.call();
      _activeGroupTasks[channelId]?.remove(agent.id);
      if (_activeGroupTasks[channelId]?.isEmpty == true) {
        _activeGroupTasks.remove(channelId);
      }
      updateTypingAgentIds();
      ForegroundTaskService().releaseTask(agent.name);
      onAgentDone?.call(agent.id, agent.name, true);
      return;
    }

    // Build metadata from captured UI tool calls
    final meta = <String, dynamic>{};
    meta['trace_id'] = groupTraceId;
    if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra!);
    if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
    if (singleSelectData != null) meta['single_select'] = singleSelectData;
    if (multiSelectData != null) meta['multi_select'] = multiSelectData;
    if (fileUploadData != null) meta['file_upload'] = fileUploadData;
    if (formDataCapture != null) meta['form'] = formDataCapture;
    final messageMetadata = meta;

    // Detect active interaction type for blocking (priority: form > action_confirmation > ...)
    String? _activeInteractionType;
    Map<String, dynamic>? _activeInteractionData;
    if (formDataCapture != null) {
      _activeInteractionType = 'form';
      _activeInteractionData = Map<String, dynamic>.from(formDataCapture!);
    } else if (actionConfirmationData != null) {
      _activeInteractionType = 'action_confirmation';
      _activeInteractionData = Map<String, dynamic>.from(actionConfirmationData!);
    } else if (singleSelectData != null) {
      _activeInteractionType = 'single_select';
      _activeInteractionData = Map<String, dynamic>.from(singleSelectData!);
    } else if (multiSelectData != null) {
      _activeInteractionType = 'multi_select';
      _activeInteractionData = Map<String, dynamic>.from(multiSelectData!);
    } else if (fileUploadData != null) {
      _activeInteractionType = 'file_upload';
      _activeInteractionData = Map<String, dynamic>.from(fileUploadData!);
    }

    // Save to DB — failure here should NOT remove the already-displayed message
    String? savedMessageId;
    try {
      final agentResponse = Message(
        id: _uuid.v4(),
        content: responseContent,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
        to: MessageFrom(id: userId, type: 'user', name: userName),
        type: MessageType.text,
        metadata: messageMetadata,
      );
      savedMessageId = agentResponse.id;

      await _db.createMessage(
        id: agentResponse.id,
        channelId: channelId,
        senderId: agent.id,
        senderType: 'agent',
        senderName: agent.name,
        content: responseContent,
        messageType: 'text',
        metadata: messageMetadata,
      );
      // Mark as read immediately — the user is actively viewing this chat
      await _db.markMessageAsRead(agentResponse.id);
      notifyChannelUpdate(channelId);
    } catch (e) {
      LoggerService().error('Group agent ${agent.name} DB save error', tag: 'GroupAgentExecutor', error: e);
      // DB save failed, but the message is already in the UI — keep it
    }

    // If local agent emitted an interactive component, block until user submits
    // (mirrors the remote ACP path's onForm/onActionConfirmation blocking behavior)
    if (_activeInteractionType != null &&
        _activeInteractionData != null &&
        savedMessageId != null &&
        onInteractionRequest != null) {
      // Inject _savedMessageId so controller can key pendingGroupInteractions
      // on the correct DB message ID (see chat_controller.dart line 1542)
      final dataForController = Map<String, dynamic>.from(_activeInteractionData!);
      dataForController['_savedMessageId'] = savedMessageId;

      // Block here: controller creates a GroupInteractionRequestEvent,
      // user fills in the form, handleFormSubmitted completes the Completer
      final userResponse = await onInteractionRequest!(
        agent.id,
        agent.name,
        _activeInteractionType!,
        dataForController,
      );

      // Sentinel detection: form/file_upload are non-blocking — the controller
      // returned immediately with {'_non_blocking': true}. Skip injecting an
      // "un-submitted" history entry; the user will submit in a new turn.
      final isNonBlocking = userResponse?['_non_blocking'] == true;
      if (!isNonBlocking) {
        // Fallback for non-form types: pick default option on timeout (null response)
        final resolvedResponse = userResponse ??
            (_activeInteractionType != 'form' && _activeInteractionType != 'file_upload'
                ? _interactionHandler.pickDefaultOption(_activeInteractionType!, _activeInteractionData!)
                : null);

        // Persist responded state to DB for consistency (survives navigation)
        if (resolvedResponse != null) {
          try {
            final respondedKey = '${_activeInteractionType}_responded';
            final mergedMeta = Map<String, dynamic>.from(messageMetadata ?? {});
            mergedMeta[respondedKey] = resolvedResponse;
            await _db.updateMessageMetadata(savedMessageId!, mergedMeta);
          } catch (e) {
            LoggerService().error('Failed to persist responded state for ${agent.name}',
                tag: 'GroupAgentExecutor', error: e);
          }
        }

        // Inject a system message so admin sees the submitted values in loopHistory
        _interactionHandler.saveUserInteractionResultMessage(
          channelId: channelId,
          subAgentName: agent.name,
          interactionType: _activeInteractionType!,
          responseData: resolvedResponse,
        );
      }
    }

    // Mark group task complete and clean up
    groupTask.isComplete = true;
    groupTask.onTaskFinished?.call();
    _activeGroupTasks[channelId]?.remove(agent.id);
    if (_activeGroupTasks[channelId]?.isEmpty == true) {
      _activeGroupTasks.remove(channelId);
    }
    updateTypingAgentIds();
    ForegroundTaskService().releaseTask(agent.name);

    LoggerService().debug('_processGroupAgent DONE: ${agent.name}, contentLen=${responseContent.length}', tag: 'GroupAgentExecutor');
    onAgentDone?.call(agent.id, agent.name, false);
  }
}
