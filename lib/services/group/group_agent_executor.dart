import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/mention_entry.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../../models/llm_token_usage.dart';
import '../../models/inference_log_entry.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../../clis/shepaw/workflow/workflow_namespace.dart';
import '../../clis/shepaw/workflow/workflow_dispatch_command.dart';
import '../local_database_service.dart';
import '../local_llm_agent_service.dart';
import '../messaging/local_llm_handler.dart';
import '../acp_agent_connection.dart';
import '../file_download_service.dart';
import '../inference_log_service.dart';
import '../trace_service.dart';
import '../foreground_task_service.dart';
import '../logger_service.dart';
import '../task/task_models.dart';
import '../mailbox/channel_mailbox_service.dart';
import '../messaging/connection_retry_policy.dart';
import 'group_dispatch_parser.dart';
import 'group_mailbox_save_plan.dart';
import 'group_orchestration_tools.dart';
import 'group_prompt_builder.dart';
import 'group_turn_result.dart';
import 'group_task_status.dart';
import 'group_interaction_handler.dart';
import '../../peer/services/peer_agent_client_service.dart';
import '../../peer/peer_approval_selection.dart';
import 'peer_approval_policy.dart';
import '../workflow/workflow_service.dart';
import '../../models/workflow_pending_approval.dart';
import '../messaging/stream_content_splitter.dart';
import 'group_member_session_service.dart';
import '../session/history_compactor.dart';
import '../session/history_compaction_cache_service.dart';
import '../../storage/group_workspace_service.dart';
import '../../storage/runtime_paths.dart';

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
    required String historyText,
    required List<({AttachmentData attachment, String senderName})>
        imageEntries,
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
        LoggerService().warning(
            'Group file_message missing url from $agentName',
            tag: 'GroupAgentExecutor');
        return;
      }

      // If the url is a local file path, try to copy the file immediately so the
      // user doesn't need to manually "download" it (local LLM agents produce files
      // that live on the same device and are accessible directly).
      String? copiedRelativePath;
      final isLocalPath =
          !url.startsWith('http://') && !url.startsWith('https://');
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
    bool isPendingStatusNudge = false,
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    List<AttachmentData>? attachments,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
    bool isFlowMode = false,
    bool isClosingSummary = false,
    bool isWorkflowStep = false,
    String? workflowId,
    String? workflowStepId,
    String? orchestrationTraceId,
  }) async {
    LoggerService().debug(
      '_processGroupAgent START: ${agent.name} (isAdmin=$isAdmin, isLocal=${agent.isLocal}, isPeer=${agent.isPeerAgent})',
      tag: 'GroupAgentExecutor',
    );

    // Bound member DM session (1:1 with this group session) — used as peer/ACP
    // session_id so group context never shares the agent's personal DM session.
    final memberSessionId = await _memberSessions.resolveMemberSessionId(
      groupChannelId: channelId,
      agentId: agent.id,
      userId: userId,
    );

    // M6：群清空时该成员断线，`/reset` 未送达。消费待补发标记；若本次走 ACP
    // 路径则在任务前补发，清掉远端会话的陈旧上下文。本地成员（无远端 session）
    // 也会消费标记，避免集合残留。
    final pendingResetFlush =
        GroupMemberSessionService.consumePendingRemoteReset(memberSessionId);

    final systemPrompt = await _promptBuilder.buildGroupSystemPrompt(
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
      isDispatchNudge: isDispatchNudge,
      isPendingStatusNudge: isPendingStatusNudge,
      loopRound: loopRound,
      mentionMode: mentionMode,
      failedAgentNames: failedAgentNames,
      isFlowMode: isFlowMode,
      isClosingSummary: isClosingSummary,
      groupId: channelId,
      channelId: channelId,
    );

    // Build chat history: pack the entire group conversation into a single
    // 'user' message so the LLM's identity comes solely from the system prompt.
    // Each line is tagged with the sender name so the agent can see who said
    // what, while "(我)" marks its own prior messages.
    const maxHistoryChars = 60000;
    var effectiveHistory = List<Message>.from(historyMessages);
    String? earlierSummary;
    // M6: 无 LLM 摘要时的截断提示（远端成员 / 摘要失败兜底），区别于 LLM 摘要，
    // 直接用原文插入，避免再套一层 summaryMessage 包装。
    String? truncationNote;

    // FIFO 截断到字符预算，并对被丢弃的旧消息生成回滚提示（谁参与了、省略了多少）。
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
        keepRecentCount: 24,
        keepRecentChars: 24000,
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
            var budgetLeft = maxHistoryChars - summaryCost;
            while (effectiveHistory.isNotEmpty &&
                effectiveHistory.fold<int>(0, (s, m) => s + m.content.length) >
                    budgetLeft &&
                effectiveHistory.length > 4) {
              effectiveHistory = effectiveHistory.sublist(1);
            }
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
      // Remote ACP members have no local LLM summarizer (they lack llm_* model
      // config on this device), so a plain FIFO drop would silently erase early
      // decisions. Keep the same 60k-char recent tail but surface the omission
      // with a rollup note (M6) so the agent knows what was dropped and who
      // participated earlier.
      effectiveHistory = truncateWithNote(historyMessages);
    }

    final historyLines = [
      if (truncationNote?.isNotEmpty == true) truncationNote!,
      if (earlierSummary != null && earlierSummary.isNotEmpty)
        HistoryCompactor.summaryMessage(earlierSummary)['content'] as String,
      ...effectiveHistory.map((m) {
        final content = LocalLLMHelpers.enrichHistoryContent(m, m.content);
        if (m.from.isAgent && m.from.id == agent.id) {
          return '[${m.from.name}(我)]: $content';
        }
        final tag = m.from.isAgent ? 'Agent' : 'User';
        return '[${m.from.name}($tag)]: $content';
      }),
    ].join('\n\n');

    final responseBuffer = StringBuffer();
    bool streamingStarted = false;

    /// H2: 流式已开始后中途失败（本地/peer/ACP 三路 catch 记录），
    /// 在成功落库前统一按「输出被中断」失败处理，阻止半截内容按成功入库。
    Object? midStreamError;

    /// 信箱轮次收到的回复消息：保存时复用其确定性 id 与来源元数据，
    /// 与推送拉取路径（fetchMailboxReplies）的去重对齐。
    Message? mailboxReply;
    // Capture UI tool call data for interactive components
    Map<String, dynamic>? actionConfirmationData;

    /// L7: 同一回合多个 peer 审批时逐张累积（[actionConfirmationData] 只保留
    /// 最后一张用于 active 交互判定）。全部卡片数据落盘 `action_confirmations`，
    /// 避免前序卡片的状态在元数据里被覆盖丢失。
    List<Map<String, dynamic>>? actionConfirmations;
    Map<String, dynamic>? singleSelectData;
    Map<String, dynamic>? multiSelectData;
    Map<String, dynamic>? fileUploadData;
    Map<String, dynamic>? formDataCapture;
    Map<String, dynamic>? messageMetadataExtra;

    /// Raw `group_mention` tool args (local members), accumulated across tool
    /// rounds; resolved into structured mentions in the unified capture block.
    List<Map<String, dynamic>>? mentionToolDeclarations;
    // Token usage for the final message bubble: summed across local tool
    // rounds, or self-reported by a remote agent in `task.completed`.
    var turnTokenUsage = const LlmTokenUsage();

    // Tool-first orchestration capture (admin only).
    var orchHasSignal = false;
    var orchSteps = <DispatchStep>[];
    var orchUnresolved = <String>[];
    String? orchParseError;
    var orchWantsContinue = false;
    var orchIsDone = false;
    var orchIsPause = false;

    final delegateableNames =
        allAgents.where((a) => a.id != agent.id).map((a) => a.name).toList();
    final adminExtraTools = isAdmin
        ? (LocalLLMAgentService.instance.resolveProviderType(agent) == 'claude'
            ? GroupOrchestrationTools.claudeTools(agentNames: delegateableNames)
            : GroupOrchestrationTools.openAITools(
                agentNames: delegateableNames))
        : null;
    // Members get the structured mention tool only when the group allows
    // member-to-member activation; in adminOnly mode the tool would only
    // produce no-op "ok" feedback.
    final memberExtraTools = (!isAdmin && mentionMode == 'allMembers')
        ? (LocalLLMAgentService.instance.resolveProviderType(agent) == 'claude'
            ? GroupOrchestrationTools.claudeMentionTools(
                agentNames: delegateableNames)
            : GroupOrchestrationTools.openAIMentionTools(
                agentNames: delegateableNames))
        : null;

    Future<void>? peerApprovalInFlight;

    // M5: 同一 (channel, agent) 已有进行中的回合时，并发重复派发（如同一阶段
    // 两条 step 指向同一 agent，或 cascade 与 @提及重叠）会覆盖 map 项，且先
    // 完成者会把后者的任务一并 remove 掉，破坏 typing/reattach；本地 agent
    // 还会并发跑两次 LLM 回合。这里直接跳过本次调用，让第一个回合独占该 agent。
    final existingTask = _activeGroupTasks[channelId]?[agent.id];
    if (existingTask != null && !existingTask.isComplete) {
      LoggerService().debug(
        'Agent ${agent.name} already active in channel $channelId; '
        'skipping duplicate turn',
        tag: 'GroupAgentExecutor',
      );
      onAgentDone?.call(agent.id, agent.name, true);
      return const GroupTurnResult();
    }

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
      executionMode: agent.isLocal
          ? 'group_local'
          : agent.isPeerAgent
              ? 'group_peer'
              : 'group_remote_acp',
      userMessage: content,
      systemPrompt: systemPrompt,
      parentTraceId: orchestrationTraceId,
      traceRole: isAdmin ? 'group_admin' : 'group_member',
    );

    if (agent.isLocal) {
      // ── Local LLM agent path ──
      // Determine provider type so we can build the correct multimodal format.
      final isClaude =
          LocalLLMAgentService.instance.resolveProviderType(agent) == 'claude';

      // Do NOT load history image bytes for group chat. Embedding historical
      // images would force vision on every turn; text placeholders in
      // historyLines already provide context. Current-turn [attachments] are
      // passed separately for multimodal understanding.
      final chatHistory = buildGroupChatHistoryWithImages(
        historyText: historyLines,
        imageEntries: const [],
        isClaude: isClaude,
      );

      // Build the full message list for multi-turn tool calling
      final roundMessages = <Map<String, dynamic>>[
        ...chatHistory,
        LocalLLMHelpers.buildUserMessageContent(
          content,
          attachments,
          isClaude,
          historyMessages: effectiveHistory,
        ),
      ];
      final maxToolRounds =
          (agent.metadata['max_tool_rounds'] as num?)?.toInt() ?? 100;

      try {
        var allowOneFinalRound = false;
        for (int toolRound = 0;
            toolRound < maxToolRounds || allowOneFinalRound;
            toolRound++) {
          final isForcedFinalRound = allowOneFinalRound;
          if (allowOneFinalRound) allowOneFinalRound = false;

          infLogGroup.beginRound(
            groupTraceId,
            requestSummary: isForcedFinalRound
                ? 'Group round ${toolRound + 1} (final)'
                : 'Group round ${toolRound + 1}',
            messages: toolRound == 0
                ? [
                    if (systemPrompt.isNotEmpty)
                      {'role': 'system', 'content': systemPrompt},
                    ...roundMessages,
                  ]
                : null,
          );

          final pawToolCalls = <LLMToolCallEvent>[];
          final pawToolResults = <Map<String, dynamic>>[];
          LLMDoneEvent? doneEvent;

          await for (final event in LocalLLMAgentService.instance.chat(
            agent: agent,
            message: toolRound == 0
                ? content
                : '', // Only first round has original message
            history: toolRound == 0
                ? (chatHistory.isNotEmpty ? chatHistory : null)
                : roundMessages,
            // Members must not surface interactive UI widgets inside the group
            // flow (their prompt forbids form/action_confirmation etc. — P1-2);
            // only the admin gets the full UI surface.
            enableUITools: isAdmin,
            includeShepawCli: agent.isLocal,
            systemPromptOverride: systemPrompt,
            attachments: toolRound == 0 ? attachments : null,
            extraTools: isAdmin ? adminExtraTools : memberExtraTools,
            excludeUIToolNames: GroupOrchestrationTools.excludedUiToolNames,
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
                infLogGroup.onToolCall(groupTraceId,
                    id: event.id, name: event.name, arguments: event.arguments);
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
                    actionConfirmationData =
                        Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'single_select':
                    singleSelectData =
                        Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'multi_select':
                    multiSelectData =
                        Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'file_upload':
                    fileUploadData = Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'form':
                    formDataCapture =
                        Map<String, dynamic>.from(event.arguments);
                    break;
                  case 'message_metadata':
                    messageMetadataExtra =
                        Map<String, dynamic>.from(event.arguments);
                    break;
                  case GroupOrchestrationTools.mentionName:
                    mentionToolDeclarations = [
                      ...?mentionToolDeclarations,
                      Map<String, dynamic>.from(event.arguments),
                    ];
                    final mentionParsed =
                        GroupOrchestrationTools.parseMentionArgs(
                      event.arguments,
                      allAgents,
                    );
                    final mentionFeedback = jsonEncode({
                      'ok': mentionParsed.mentions.isNotEmpty,
                      'mention_count': mentionParsed.mentions.length,
                      if (mentionParsed.unresolvedNames.isNotEmpty)
                        'unresolved_names': mentionParsed.unresolvedNames,
                      if (mentionParsed.mentions.isEmpty &&
                          mentionParsed.unresolvedNames.isEmpty)
                        'error': 'no members matched',
                    });
                    pawToolCalls.add(event);
                    pawToolResults.add({
                      'tool_call_id': event.id,
                      'name': event.name,
                      'result': mentionFeedback,
                    });
                    infLogGroup.onToolResult(
                      groupTraceId,
                      toolCallId: event.id,
                      name: event.name,
                      result: mentionFeedback,
                    );
                    break;
                  case GroupOrchestrationTools.dispatchName:
                    orchHasSignal = true;
                    final parsed = GroupOrchestrationTools.parseDispatchArgs(
                      event.arguments,
                      allAgents.where((a) => a.id != agent.id).toList(),
                    );
                    if (parsed.steps.isNotEmpty) {
                      orchSteps = parsed.steps;
                      orchUnresolved = parsed.unresolvedNames;
                      orchParseError = null;
                    } else {
                      orchParseError = parsed.parseError;
                      orchUnresolved = parsed.unresolvedNames;
                    }
                    final dispatchResult = parsed.steps.isNotEmpty
                        ? jsonEncode({
                            'ok': true,
                            'step_count': parsed.steps.length,
                            if (parsed.unresolvedNames.isNotEmpty)
                              'unresolved_names': parsed.unresolvedNames,
                          })
                        : jsonEncode({
                            'ok': false,
                            'error':
                                parsed.parseError ?? 'invalid group_dispatch',
                            if (parsed.unresolvedNames.isNotEmpty)
                              'unresolved_names': parsed.unresolvedNames,
                          });
                    pawToolCalls.add(event);
                    pawToolResults.add({
                      'tool_call_id': event.id,
                      'name': event.name,
                      'result': dispatchResult,
                    });
                    infLogGroup.onToolResult(
                      groupTraceId,
                      toolCallId: event.id,
                      name: event.name,
                      result: dispatchResult,
                    );
                    break;
                  case GroupOrchestrationTools.finishName:
                    orchHasSignal = true;
                    final action = GroupOrchestrationTools.parseFinishAction(
                        event.arguments);
                    if (action == null) {
                      orchParseError =
                          'group_finish.action must be done|continue|pause';
                      final err = jsonEncode({
                        'ok': false,
                        'error': orchParseError,
                      });
                      pawToolCalls.add(event);
                      pawToolResults.add({
                        'tool_call_id': event.id,
                        'name': event.name,
                        'result': err,
                      });
                      infLogGroup.onToolResult(
                        groupTraceId,
                        toolCallId: event.id,
                        name: event.name,
                        result: err,
                      );
                    } else {
                      orchIsDone = action == 'done';
                      orchWantsContinue = action == 'continue';
                      orchIsPause = action == 'pause';
                      final ok = jsonEncode({'ok': true, 'action': action});
                      pawToolCalls.add(event);
                      pawToolResults.add({
                        'tool_call_id': event.id,
                        'name': event.name,
                        'result': ok,
                      });
                      infLogGroup.onToolResult(
                        groupTraceId,
                        toolCallId: event.id,
                        name: event.name,
                        result: ok,
                      );
                    }
                    break;
                  case 'request_history':
                    // Group turns already inject truncated history; refuse the tool.
                    final refused = jsonEncode({
                      'ok': false,
                      'error':
                          'request_history is unavailable in group chat; history is already injected. Call group_dispatch or group_finish instead.',
                    });
                    pawToolCalls.add(event);
                    pawToolResults.add({
                      'tool_call_id': event.id,
                      'name': event.name,
                      'result': refused,
                    });
                    infLogGroup.onToolResult(
                      groupTraceId,
                      toolCallId: event.id,
                      name: event.name,
                      result: refused,
                    );
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
                      WorkflowNamespace.instance
                          .setContext(channelId, agent.id);

                      // Wire up dispatch command's step execution callback (per-channel)
                      WorkflowDispatchCommand.setExecuteStepFn(channelId,
                          (agentName, instruction, chId) async {
                        final targetAgent =
                            GroupDispatchParser.findAgentByDispatchName(
                          allAgents,
                          agentName,
                        );
                        if (targetAgent == null) {
                          return '[Error] Agent "$agentName" not found in group members.';
                        }
                        final stepBuffer = StringBuffer();
                        try {
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
                            // M9: 递归 step 执行补齐上下文——目标为 admin 时启用
                            // 管理工具；失败进入 failedAgentNames；peer 审批注册
                            // workflow；trace 树挂在当前回合（groupTraceId）下。
                            isAdmin: adminAgent != null && targetAgent.id == adminAgent.id,
                            messageVersion: messageVersion,
                            channelMembers: channelMembers,
                            customSystemPrompt: customSystemPrompt,
                            mentionMode: mentionMode,
                            failedAgentNames: failedAgentNames,
                            isWorkflowStep: isWorkflowStep,
                            workflowId: workflowId,
                            workflowStepId: workflowStepId,
                            acpCancellationToken: acpCancellationToken,
                            onStreamChunk: (aid, anm, chunk) {
                              stepBuffer.write(chunk);
                              onStreamChunk?.call(aid, anm, chunk);
                            },
                            onAgentDone: onAgentDone,
                            onInteractionRequest: onInteractionRequest,
                            orchestrationTraceId: groupTraceId,
                          );
                        } catch (e) {
                          // processGroupAgent rethrows member failures so the
                          // orchestration layer can track them; inside this
                          // tool callback the failure must come back as a tool
                          // result string instead of killing the tool loop.
                          return '[Error] Agent "$agentName" execution failed: $e';
                        }
                        return stepBuffer.toString();
                      });

                      // Execute CLI command (members: store + help only)
                      final String cliResult;
                      try {
                        cliResult = await _executeShepawCliForGroup(
                          args: args,
                          agent: agent,
                          isAdmin: isAdmin,
                          channelId: channelId,
                        );
                      } finally {
                        // M9: per-channel step 执行回调注册后必须清理，
                        // 避免闭包捕获跨轮残留（下次使用前会重新注册）。
                        WorkflowDispatchCommand.clearExecuteStepFn(channelId);
                      }
                      LoggerService().info(
                        'CLI result (${args['namespace']} ${args['subcommand'] ?? ''}): ${cliResult.length > 200 ? '${cliResult.substring(0, 200)}...' : cliResult}',
                        tag: 'GroupAgentExecutor',
                      );
                      infLogGroup.onToolResult(groupTraceId,
                          toolCallId: event.id,
                          name: event.name,
                          result: cliResult);

                      // Collect for multi-turn
                      pawToolCalls.add(event);
                      pawToolResults.add({
                        'tool_call_id': event.id,
                        'name': event.name,
                        'result': cliResult,
                      });

                      // Handle workflow create approval flow
                      try {
                        final cliJson =
                            json.decode(cliResult) as Map<String, dynamic>?;
                        if (cliJson != null &&
                            cliJson['status'] == 'pending_approval') {
                          final workflowId = cliJson['workflow_id'] as String?;
                          final planDataRaw =
                              cliJson['_plan_data'] as Map<String, dynamic>?;
                          if (workflowId != null &&
                              planDataRaw != null &&
                              onInteractionRequest != null) {
                            await onInteractionRequest.call(
                              agent.id,
                              agent.name,
                              'plan_approval',
                              {
                                ...planDataRaw,
                                '_workflowId': workflowId,
                                '_non_blocking': true
                              },
                            );
                          }
                        }
                      } catch (e) {
                        LoggerService().warning(
                            'Workflow approval flow error: $e',
                            tag: 'GroupAgentExecutor');
                      }
                    }
                    break;
                }
                break;
              case LLMDoneEvent():
                doneEvent = event;
                turnTokenUsage = turnTokenUsage.plus(LlmTokenUsage(
                  inputTokens: event.inputTokens,
                  outputTokens: event.outputTokens,
                ));
                infLogGroup.endRound(
                  groupTraceId,
                  stopReason: event.stopReason,
                  inputTokens: event.inputTokens,
                  outputTokens: event.outputTokens,
                );
                break;
            }
          }

          // If there were CLI tool calls AND we have a rawAssistantMessage,
          // feed results back to LLM for continuation (multi-turn).
          if (pawToolCalls.isNotEmpty &&
              doneEvent?.rawAssistantMessage != null &&
              !isForcedFinalRound) {
            LoggerService().info(
              'Multi-turn: ${pawToolCalls.length} tool calls in round ${toolRound + 1}, continuing...',
              tag: 'GroupAgentExecutor',
            );
            if (isClaude) {
              LocalLLMHelpers.appendToolRoundClaude(
                  roundMessages,
                  doneEvent!.rawAssistantMessage!,
                  pawToolCalls,
                  pawToolResults);
            } else {
              LocalLLMHelpers.appendToolRoundOpenAI(
                  roundMessages,
                  doneEvent!.rawAssistantMessage!,
                  pawToolCalls,
                  pawToolResults);
            }
            if (toolRound + 1 < maxToolRounds) {
              continue; // Next round
            }
            // Hit max tool rounds — run one final text-only synthesis round.
            LoggerService().warning(
              'Group agent ${agent.name} hit max tool rounds ($maxToolRounds); '
              'running final synthesis round',
              tag: 'GroupAgentExecutor',
            );
            roundMessages.add({
              'role': 'user',
              'content': '[SYSTEM] 工具调用轮次已达上限。请根据已有工具结果和群聊历史，'
                  '直接向用户输出完整总结，不要再调用任何工具。',
            });
            allowOneFinalRound = true;
            continue;
          }

          // No tool calls or stream done — exit loop
          break;
        }
      } catch (e) {
        LoggerService().error('Group agent ${agent.name} stream error',
            tag: 'GroupAgentExecutor', error: e);
        infLogGroup.endRound(groupTraceId, stopReason: 'error');
        infLogGroup.endSession(groupTraceId, InferenceStatus.error,
            error: '$e');
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
          // M1: 不在执行器错误路径上报 onAgentDone——调用方（编排 .catchError /
          // 工作流 catch）持有该 turn 的上报权，rethrow 后由调用方统一回调一次。
          // Propagate so the orchestration layer records this member in
          // failedAgentNames (and workflow steps hit failStep) — the admin's
          // review/summarize round must know the member failed.
          rethrow;
        }
        // H2: streaming already started with buffered content — remember the
        // failure and fail the turn below instead of silently persisting a
        // truncated reply as a successful message.
        midStreamError = e;
      }
    } else if (agent.isPeerAgent) {
      // ── Peer agent path (P2P relay to paired device's local agent) ──
      final peerId = agent.sourcePeerId;
      final remoteAgentId = agent.remoteAgentId;
      if (peerId == null || remoteAgentId == null) {
        LoggerService().error(
          'Peer agent ${agent.name} missing source_peer_id/remote_agent_id',
          tag: 'GroupAgentExecutor',
        );
        await _saveGroupAgentErrorMessage(
          channelId: channelId,
          agentName: agent.name,
          error: 'Peer agent 配置不完整（缺少 source_peer_id 或 remote_agent_id）',
        );
        groupTask.isComplete = true;
        groupTask.onTaskFinished?.call();
        _activeGroupTasks[channelId]?.remove(agent.id);
        if (_activeGroupTasks[channelId]?.isEmpty == true) {
          _activeGroupTasks.remove(channelId);
        }
        updateTypingAgentIds();
        ForegroundTaskService().releaseTask(agent.name);
        infLogGroup.endSession(groupTraceId, InferenceStatus.error,
            error: 'missing peer metadata');
        onAgentDone?.call(agent.id, agent.name, true);
        return const GroupTurnResult();
      }

      final peerMessage = _buildPeerGroupMessage(
        systemPrompt: systemPrompt,
        historyLines: historyLines,
        content: content,
      );

      infLogGroup.beginRound(groupTraceId,
          requestSummary: 'Group peer request');

      final peerSessionId = PeerApprovalPolicy.workflowSessionId(
            channelId: memberSessionId,
            workflowId: workflowId,
            workflowStepId: workflowStepId,
          ) ??
          memberSessionId;

      try {
        if (attachments != null) {
          for (final a in attachments) {
            if (a.exceedsSizeLimit) {
              throw Exception(
                '附件过大（上限 ${AttachmentData.maxSizeBytes ~/ (1024 * 1024)}MB）: '
                '${a.fileName}',
              );
            }
          }
        }

        final splitter = StreamContentSplitter();
        final result = await PeerAgentClientService.instance.sendChat(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          message: peerMessage,
          sessionId: peerSessionId,
          attachments: attachments,
          extraTools: isAdmin ? adminExtraTools : null,
          cancelToken: acpCancellationToken,
          localAgentId: agent.id,
          channelId: channelId,
          agentName: agent.name,
          onRequestStarted: (requestId) {
            final spanId = TraceService.instance.addSpan(
              traceId: groupTraceId,
              spanType: 'peer_request',
              name: 'agent_chat',
              metadata: {
                'request_id': requestId,
                'peer_id': peerId,
                'remote_agent_id': remoteAgentId,
                'peer_session_id': peerSessionId,
                'parent_trace_id': orchestrationTraceId,
              },
            );
            TraceService.instance.endSpan(
              spanId,
              outputData: {'status': 'sent'},
            );
            messageMetadataExtra = Map<String, dynamic>.from(
              messageMetadataExtra ?? {},
            )..addAll({
                'request_id': requestId,
                'peer_id': peerId,
                'remote_agent_id': remoteAgentId,
                'peer_session_id': peerSessionId,
              });
          },
          onChunk: (chunk) {
            final answerDelta = splitter.onChunk(chunk);
            if (answerDelta.isNotEmpty) {
              streamingStarted = true;
              responseBuffer.write(answerDelta);
              groupTask.accumulatedContent += answerDelta;
              groupTask.onStreamChunk?.call(answerDelta);
              onStreamChunk?.call(agent.id, agent.name, answerDelta);
              infLogGroup.onTextChunk(groupTraceId, answerDelta);
            } else {
              final progressMeta = splitter.progressMetadataDelta();
              if (progressMeta != null) {
                messageMetadataExtra = Map<String, dynamic>.from(
                  messageMetadataExtra ?? {},
                )..addAll(progressMeta);
              }
              infLogGroup.onTextChunk(groupTraceId, chunk);
            }
          },
          onMetadata: (data) {
            final merged = splitter.onMetadata(data);
            messageMetadataExtra = Map<String, dynamic>.from(
              messageMetadataExtra ?? {},
            )..addAll(merged);
          },
          onActionConfirmation: (data) {
            // Keep a single mutable map: resolution (admin auto or user tap)
            // must write selected_action_id here so the final DB message
            // metadata matches the post-approval UI state.
            //
            // Multiple sequential approvals in one turn must be chained —
            // overwriting peerApprovalInFlight orphans the previous wait and
            // leaves the step hung with openApprovals > 0.
            actionConfirmationData = Map<String, dynamic>.from(data);
            // L7: 逐张累积，全部卡片进元数据，active 交互判定仍取最后一张。
            (actionConfirmations ??= []).add(actionConfirmationData!);
            final next = _handlePeerGroupActionConfirmation(
              agent: agent,
              peerId: peerId,
              remoteAgentId: remoteAgentId,
              peerSessionId: peerSessionId,
              data: actionConfirmationData!,
              adminAgent: adminAgent,
              channelId: channelId,
              isWorkflowStep: isWorkflowStep,
              workflowId: workflowId,
              workflowStepId: workflowStepId,
              onInteractionRequest: onInteractionRequest,
            );
            final prev = peerApprovalInFlight;
            peerApprovalInFlight = () async {
              if (prev != null) {
                try {
                  await prev;
                } catch (e) {
                  LoggerService().warning(
                    'Prior peer approval chain error for ${agent.name}: $e',
                    tag: 'GroupAgentExecutor',
                  );
                }
              }
              await next;
            }();
          },
        );

        if (peerApprovalInFlight != null) {
          await peerApprovalInFlight;
          peerApprovalInFlight = null;
        }

        infLogGroup.endRound(groupTraceId, stopReason: 'stop');
        final wasCancelled = acpCancellationToken?.isCancelled == true;
        infLogGroup.endSession(
          groupTraceId,
          wasCancelled ? InferenceStatus.cancelled : InferenceStatus.completed,
        );

        if (responseBuffer.isEmpty && splitter.answerContent.isNotEmpty) {
          responseBuffer.write(splitter.answerContent);
          streamingStarted = true;
        } else if (result.content.isNotEmpty &&
            responseBuffer.isEmpty &&
            splitter.progressContent.isEmpty) {
          responseBuffer.write(result.content);
          streamingStarted = true;
        }
        messageMetadataExtra = Map<String, dynamic>.from(
          messageMetadataExtra ?? {},
        )..addAll(splitter.finalProgressMetadata());
        if (result.requestId != null) {
          messageMetadataExtra!['request_id'] = result.requestId;
        }
        if (result.metadata != null && result.metadata!.isNotEmpty) {
          messageMetadataExtra!.addAll(result.metadata!);
        }
        if (actionConfirmationData == null) {
          final relayedAc =
              result.metadata?['action_confirmation'] as Map<String, dynamic>?;
          if (relayedAc != null) {
            actionConfirmationData = Map<String, dynamic>.from(relayedAc);
            actionConfirmationData!['confirmation_context'] ??= 'peer';
          }
        }
      } catch (e) {
        LoggerService().error(
          'Group agent ${agent.name} peer error',
          tag: 'GroupAgentExecutor',
          error: e,
        );
        infLogGroup.endRound(groupTraceId, stopReason: 'error');
        infLogGroup.endSession(groupTraceId, InferenceStatus.error,
            error: '$e');
        if (!streamingStarted || responseBuffer.isEmpty) {
          await _saveGroupAgentErrorMessage(
            channelId: channelId,
            agentName: agent.name,
            error: e,
          );
          groupTask.isComplete = true;
          groupTask.onTaskFinished?.call();
          _activeGroupTasks[channelId]?.remove(agent.id);
          if (_activeGroupTasks[channelId]?.isEmpty == true) {
            _activeGroupTasks.remove(channelId);
          }
          updateTypingAgentIds();
          ForegroundTaskService().releaseTask(agent.name);
          // M1: 调用方 catch 统一上报 onAgentDone，执行器仅负责清理 + rethrow。
          // Propagate so orchestration records failedAgentNames / workflow
          // steps hit failStep (same contract as the local path).
          rethrow;
        }
        // H2: same as the local path — a mid-stream peer failure must not
        // persist a truncated reply as a successful message.
        midStreamError = e;
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
        for (final m in effectiveHistory) {
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
      var usedMailbox = false;
      // 群工作空间共享面 URI（mailbox 兜底时可能尚未赋值 → 传 null 即可）。
      String? groupWorkspaceUri;

      Future<void> fillFromMailbox(Object reason) async {
        LoggerService().info(
          'Group ACP mailbox fallback for ${agent.name}: $reason',
          tag: 'GroupAgentExecutor',
        );
        // Mailbox 兜底也带完整群上下文（离线恢复后群工具/共享空间仍可用）。
        final mailboxGroupContext = <String, dynamic>{
          'group_id': channelId,
          'group_name': groupName,
          'group_description': groupDescription,
          'member_count': allAgents.length,
          'members': allAgents
              .map((a) => <String, dynamic>{
                    'id': a.id,
                    'name': a.name,
                    'type': 'agent',
                    'bio': a.bio ?? '',
                    'capabilities': a.capabilities,
                    'status': a.isOnline ? 'online' : 'offline',
                  })
              .toList(),
          if (groupWorkspaceUri != null) 'workspace_uri': groupWorkspaceUri,
        };
        final left = await _collectGroupMailboxReply(
          agent: agent,
          content: content,
          userId: userId,
          userName: userName,
          sessionId: memberSessionId,
          requestId: taskId ?? _uuid.v4(),
          channelId: channelId,
          chatHistory: acpHistoryEntries.isNotEmpty ? acpHistoryEntries : null,
          groupContext: mailboxGroupContext,
          onChunk: (chunk) {
            streamingStarted = true;
            responseBuffer.write(chunk);
            groupTask.accumulatedContent += chunk;
            groupTask.onStreamChunk?.call(chunk);
            onStreamChunk?.call(agent.id, agent.name, chunk);
            infLogGroup.onTextChunk(groupTraceId, chunk);
          },
        );
        if (left.type == MessageType.system) {
          throw Exception(left.content);
        }
        mailboxReply = left;
        if (left.content.isNotEmpty && responseBuffer.isEmpty) {
          streamingStarted = true;
          responseBuffer.write(left.content);
          onStreamChunk?.call(agent.id, agent.name, left.content);
          infLogGroup.onTextChunk(groupTraceId, left.content);
        }
        usedMailbox = true;
      }

      try {
        try {
          connection = await getOrCreateACPConnection(agent);
        } catch (e) {
          if (ChannelMailboxService.agentHasChannelInbox(agent) &&
              isRetriableConnectionError(e) &&
              leaveMailboxAndCollect != null) {
            await fillFromMailbox(e);
          } else {
            rethrow;
          }
        }
        if (usedMailbox) {
          infLogGroup.beginRound(groupTraceId,
              requestSummary: 'Group mailbox fallback');
          infLogGroup.endRound(groupTraceId, stopReason: 'stop');
          infLogGroup.endSession(groupTraceId, InferenceStatus.completed);
        } else {
          taskId = _uuid.v4();

          infLogGroup.beginRound(groupTraceId,
              requestSummary: 'Group ACP request');

          // Bind cancellation token so the UI can stop this agent. The token is
          // multi-binding: concurrent group members each register their own
          // binding/callback instead of overwriting each other.
          if (acpCancellationToken != null) {
            acpCancellationToken.bind(connection!, taskId);
            acpCancellationToken.addOnCancelled(() {
              if (!taskCompleter.isCompleted) {
                taskCompleter.complete();
              }
            });
          }

          final effectiveTaskId = taskId;
          final effectiveConnection = connection!;

          // M6：群清空时断线未送达的远端 `/reset` 在此回合任务前补发
          // （best-effort；失败吞掉不阻塞主任务）。
          if (pendingResetFlush && effectiveConnection.isConnected) {
            try {
              await effectiveConnection.sendChatMessage(
                taskId: _uuid.v4(),
                sessionId: memberSessionId,
                message: '/reset',
                userId: 'user',
                messageId: _uuid.v4(),
              );
            } catch (_) {}
          }

          effectiveConnection.registerTaskCallbacks(
              effectiveTaskId,
              TaskCallbacks(
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
                  turnTokenUsage = turnTokenUsage
                      .plus(LlmTokenUsage.fromJson(data['usage']));
                  infLogGroup.endRound(groupTraceId, stopReason: 'stop');
                  infLogGroup.endSession(
                      groupTraceId, InferenceStatus.completed);
                  if (!taskCompleter.isCompleted) {
                    taskCompleter.complete();
                  }
                },
                onTaskError: (data) {
                  final errorMsg = data['message'] as String? ?? 'Task error';
                  infLogGroup.endRound(groupTraceId, stopReason: 'error');
                  infLogGroup.endSession(groupTraceId, InferenceStatus.error,
                      error: errorMsg);
                  if (!taskCompleter.isCompleted) {
                    taskCompleter.completeError(
                      Exception(data['message'] ?? 'Task error'),
                    );
                  }
                },
                onActionConfirmation: (data) async {
                  // Capture into the outer mutable map so admin/user resolution can
                  // stamp selected_action_id before the final message is saved.
                  actionConfirmationData = Map<String, dynamic>.from(data);
                  if (adminAgent != null) {
                    try {
                      var responseData =
                          await _interactionHandler.resolveInteractionViaAdmin(
                        interactionType: 'action_confirmation',
                        data: actionConfirmationData!,
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
                        _applyActionConfirmationSelection(
                          actionConfirmationData!,
                          responseData,
                        );
                        _interactionHandler.saveAdminDecisionMessage(
                          channelId: channelId,
                          subAgentName: agent.name,
                          interactionType: 'action_confirmation',
                          chosenLabel: responseData['selected_action_label']
                                  as String? ??
                              '',
                        );
                        return;
                      }
                    } catch (e) {
                      LoggerService().error(
                          'Admin decision error (action_confirmation)',
                          tag: 'GroupAgentExecutor',
                          error: e);
                    }
                  }
                  // No admin or admin returned null (ASK_USER) — escalate to user
                  if (onInteractionRequest != null) {
                    final userResponse = await onInteractionRequest(
                        agent.id,
                        agent.name,
                        'action_confirmation',
                        actionConfirmationData!);
                    if (userResponse != null &&
                        userResponse['_non_blocking'] != true) {
                      try {
                        await effectiveConnection.submitResponse(
                          taskId: effectiveTaskId,
                          responseType: 'action_confirmation',
                          responseData: userResponse,
                        );
                      } catch (_) {}
                      _applyActionConfirmationSelection(
                        actionConfirmationData!,
                        userResponse,
                      );
                      return;
                    }
                  }
                  // Fallback to default option
                  final fallback = _interactionHandler.pickDefaultOption(
                      'action_confirmation', actionConfirmationData!);
                  if (fallback != null) {
                    try {
                      await effectiveConnection.submitResponse(
                        taskId: effectiveTaskId,
                        responseType: 'action_confirmation',
                        responseData: fallback,
                      );
                    } catch (_) {}
                    _applyActionConfirmationSelection(
                      actionConfirmationData!,
                      fallback,
                    );
                  }
                },
                onSingleSelect: (data) async {
                  if (adminAgent != null) {
                    try {
                      var responseData =
                          await _interactionHandler.resolveInteractionViaAdmin(
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
                          chosenLabel: responseData['selected_option_label']
                                  as String? ??
                              '',
                        );
                        return;
                      }
                    } catch (e) {
                      LoggerService().error(
                          'Admin decision error (single_select)',
                          tag: 'GroupAgentExecutor',
                          error: e);
                    }
                  }
                  // No admin or admin returned null (ASK_USER) — escalate to user
                  if (onInteractionRequest != null) {
                    final userResponse = await onInteractionRequest(
                        agent.id, agent.name, 'single_select', data);
                    if (userResponse != null &&
                        userResponse['_non_blocking'] != true) {
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
                  final fallback = _interactionHandler.pickDefaultOption(
                      'single_select', data);
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
                      var responseData =
                          await _interactionHandler.resolveInteractionViaAdmin(
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
                        final ids = responseData['selected_option_ids']
                                as List<dynamic>? ??
                            [];
                        _interactionHandler.saveAdminDecisionMessage(
                          channelId: channelId,
                          subAgentName: agent.name,
                          interactionType: 'multi_select',
                          chosenLabel: ids.join(', '),
                        );
                        return;
                      }
                    } catch (e) {
                      LoggerService().error(
                          'Admin decision error (multi_select)',
                          tag: 'GroupAgentExecutor',
                          error: e);
                    }
                  }
                  // No admin or admin returned null (ASK_USER) — escalate to user
                  if (onInteractionRequest != null) {
                    final userResponse = await onInteractionRequest(
                        agent.id, agent.name, 'multi_select', data);
                    if (userResponse != null &&
                        userResponse['_non_blocking'] != true) {
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
                  final fallback = _interactionHandler.pickDefaultOption(
                      'multi_select', data);
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
                    final userResponse = await onInteractionRequest(
                        agent.id, agent.name, 'form', data);
                    if (userResponse != null &&
                        userResponse['_non_blocking'] != true) {
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
                  LoggerService().debug(
                      'Form interaction from ${agent.name} — non-blocking, user will submit next turn',
                      tag: 'GroupAgentExecutor');
                  final fallback =
                      _interactionHandler.pickDefaultOption('form', data);
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
                    final userResponse = await onInteractionRequest(
                        agent.id, agent.name, 'file_upload', data);
                    if (userResponse != null &&
                        userResponse['_non_blocking'] != true) {
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
                  LoggerService().debug(
                      'File upload interaction from ${agent.name} — non-blocking, user will submit next turn',
                      tag: 'GroupAgentExecutor');
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
                onMessageMetadata: (data) {
                  // Remote ACP members declare structured mentions via
                  // `ui.messageMetadata` notifications; params arrive as
                  // {'task_id': ..., ...metadata}. Merge into messageMetadataExtra
                  // so the unified capture block resolves them.
                  final meta = Map<String, dynamic>.from(data)
                    ..remove('task_id');
                  messageMetadataExtra = Map<String, dynamic>.from(
                    messageMetadataExtra ?? {},
                  )..addAll(meta);
                },
              ));

          // 群工作空间共享面 URI（外接 agent 感知群记忆/共享产物；
          // 群空间未初始化或读取失败时省略）。
          try {
            final groupChannel = await _db.getChannelById(channelId);
            if (groupChannel != null) {
              final meta = await GroupWorkspaceService.instance
                  .loadMeta(groupChannel.groupFamilyId);
              if (meta != null) {
                groupWorkspaceUri = 'store://workspaces/${meta.homeDevice}/'
                    '${GroupWorkspaceService.instance.workspaceRoot(groupChannel.groupFamilyId)}'
                    '/shared';
              }
            }
          } catch (_) {}

          // Build group_context for remote agents
          final groupContext = <String, dynamic>{
            'group_id': channelId,
            'group_name': groupName,
            'group_description': groupDescription,
            'member_count': allAgents.length,
            'members': allAgents
                .map((a) => <String, dynamic>{
                      'id': a.id,
                      'name': a.name,
                      'type': 'agent',
                      'bio': a.bio ?? '',
                      'capabilities': a.capabilities,
                      'status': a.isOnline ? 'online' : 'offline',
                    })
                .toList(),
            'is_first_message': isFirstMessage,
            if (messageVersion != null) 'message_version': messageVersion,
            if (isAdmin && adminExtraTools != null)
              'orchestration_tools': adminExtraTools,
            // 群工作空间共享面 URI（外接 agent 经 acp-proxy 可见群记忆/
            // 编排状态/共享产物；读取失败则省略）。
            if (groupWorkspaceUri != null) 'workspace_uri': groupWorkspaceUri,
          };

          final chatResp = await effectiveConnection.sendChatMessage(
            taskId: effectiveTaskId,
            sessionId: memberSessionId,
            message: content,
            userId: userId,
            messageId: _uuid.v4(),
            history: acpHistoryEntries.isNotEmpty ? acpHistoryEntries : null,
            systemPrompt: systemPrompt,
            groupContext: groupContext,
            attachments: attachments
                ?.where((a) => !a.exceedsSizeLimit)
                .map((a) => a.toJson())
                .toList(),
            tools: isAdmin ? adminExtraTools : null,
          );

          final busyStatus = chatResp.result is Map
              ? (chatResp.result as Map)['status']?.toString()
              : null;
          if (busyStatus == 'busy') {
            effectiveConnection.unregisterTaskCallbacks(effectiveTaskId);
            acpCancellationToken?.unbind(effectiveConnection, effectiveTaskId);
            if (!taskCompleter.isCompleted) taskCompleter.complete();
            if (leaveMailboxAndCollect != null &&
                ChannelMailboxService.agentHasChannelInbox(agent)) {
              await fillFromMailbox('status=busy');
            } else {
              throw Exception('Agent busy');
            }
          } else {
            await taskCompleter.future.timeout(
              acpTaskTimeout,
              onTimeout: () {
                throw TimeoutException(
                    'ACP group task timed out for ${agent.name}');
              },
            );
          }

          if (!usedMailbox) {
            effectiveConnection.unregisterTaskCallbacks(effectiveTaskId);
            acpCancellationToken?.unbind(effectiveConnection, effectiveTaskId);
          }
        }
      } catch (e) {
        LoggerService().error('Group agent ${agent.name} ACP error',
            tag: 'GroupAgentExecutor', error: e);
        // M11: ACP 错误路径泄漏推理会话——非重试连接异常、sendChatMessage 抛错、
        // Agent busy、3h 超时、mailbox 兜底异常都不走 onTaskError（远程任务未
        // 启动或仍在挂起），groupTraceId 会话会停在 running。这里统一收尾；
        // 若 onTaskError 已先收尾，endRound/endSession 对已移除的会话是 no-op。
        infLogGroup.endRound(groupTraceId, stopReason: 'error');
        infLogGroup.endSession(groupTraceId, InferenceStatus.error,
            error: '$e');
        if (connection != null && taskId != null) {
          connection.unregisterTaskCallbacks(taskId);
          acpCancellationToken?.unbind(connection, taskId);
        }
        if (!streamingStarted || responseBuffer.isEmpty) {
          // Keep behavior consistent with the local/peer paths: surface a
          // visible error message so the user knows which agent failed
          // instead of the placeholder bubble silently disappearing.
          await _saveGroupAgentErrorMessage(
            channelId: channelId,
            agentName: agent.name,
            error: e,
          );
          groupTask.isComplete = true;
          groupTask.onTaskFinished?.call();
          _activeGroupTasks[channelId]?.remove(agent.id);
          if (_activeGroupTasks[channelId]?.isEmpty == true) {
            _activeGroupTasks.remove(channelId);
          }
          updateTypingAgentIds();
          ForegroundTaskService().releaseTask(agent.name);
          // M1: 调用方 catch 统一上报 onAgentDone，执行器仅负责清理 + rethrow。
          // Propagate so orchestration records failedAgentNames / workflow
          // steps hit failStep (same contract as the local/peer paths).
          rethrow;
        }
        // H2: same as the local/peer paths — a mid-stream ACP failure must
        // not persist a truncated reply as a successful message.
        midStreamError = e;
      }
    }

    // End session for local LLM path (remote ACP ends in onTaskCompleted/onTaskError callbacks)
    if (agent.isLocal) {
      final wasCancelled = acpCancellationToken?.isCancelled == true;
      infLogGroup.endSession(groupTraceId,
          wasCancelled ? InferenceStatus.cancelled : InferenceStatus.completed);
    }

    var responseContent = responseBuffer.toString().trim();

    // Strip redundant agent name prefix that LLMs sometimes echo from chat history
    // e.g. "[local1]: 你好" or "[local1(Agent)]: 你好" → "你好"
    final prefixPattern = RegExp(
        r'^\[' + RegExp.escape(agent.name) + r'(?:\(Agent\))?\]\s*[:：]\s*');
    responseContent = responseContent.replaceFirst(prefixPattern, '');

    // H2: streaming started then failed mid-way (three catch paths recorded
    // midStreamError). Persist an interruption notice instead of the truncated
    // buffer, clean up the task, report failure, and re-raise so the
    // orchestration layer records this member in failedAgentNames / workflow
    // steps hit failStep — exactly like a pre-stream failure.
    if (midStreamError != null) {
      final interruptMsg = Message(
        id: _uuid.v4(),
        content: '⚠️ Agent「${agent.name}」输出被中断：$midStreamError',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
      );
      await _db.createMessage(
        id: interruptMsg.id,
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: interruptMsg.content,
        messageType: 'system',
      );
      await _db.markMessageAsRead(interruptMsg.id);
      notifyChannelUpdate(channelId);

      groupTask.isComplete = true;
      groupTask.onTaskFinished?.call();
      _activeGroupTasks[channelId]?.remove(agent.id);
      if (_activeGroupTasks[channelId]?.isEmpty == true) {
        _activeGroupTasks.remove(channelId);
      }
      updateTypingAgentIds();
      ForegroundTaskService().releaseTask(agent.name);
      // M1: 调用方 catch 统一上报 onAgentDone，执行器仅负责清理 + throw。
      // Not inside a catch context here — throw the original error so the
      // orchestration layer records failedAgentNames / workflow failStep.
      throw midStreamError;
    }

    final hasPeerApprovalCard = actionConfirmationData != null &&
        actionConfirmationData!['confirmation_context'] == 'peer';
    final hasProgressContent =
        (messageMetadataExtra?['progress_content'] as String?)
                ?.trim()
                .isNotEmpty ==
            true;

    if (responseContent.isEmpty && hasPeerApprovalCard) {
      // Keep a visible bubble for peer approvals even when the agent emitted
      // no prose — pending cards need a host, and admin-auto / panel-resolved
      // cards should still show the selected-button state in history.
      responseContent =
          actionConfirmationData!['prompt'] as String? ?? '需要您的确认';
    }

    // ── Unified structured mention capture ────────────────────────────────
    // Agent-to-agent activation is declared structurally, never parsed from
    // text (a `@` inside an email, code snippet or quote can never mis-activate
    // a member): (1) `group_mention` tool args (local members), (2) a
    // `mentions` key in reply metadata (remote/peer members + universal
    // fallback), and (3) legacy ```json``` dispatch blocks (members only,
    // unchanged). Text `@name` in a reply is display-only.
    var agentMentions = <MentionEntry>[];
    var unresolvedMentionNames = <String>[];
    final legacySteps = <DispatchStep>[];
    final rawDeclarations = <dynamic>[
      ...?mentionToolDeclarations,
      ...(messageMetadataExtra?['mentions'] as List<dynamic>? ?? const []),
    ];
    if (!isAdmin) {
      final resolved = GroupDispatchParser.resolveMentionDeclarations(
        rawDeclarations,
        allAgents,
      );
      agentMentions = resolved.mentions;
      unresolvedMentionNames = resolved.unresolved;
      final legacy =
          _dispatchParser.parseStructuredDispatch(responseContent, allAgents);
      legacySteps.addAll(legacy.steps);
      for (final s in legacy.steps) {
        for (final id in s.agentIds) {
          final agent = allAgents.where((a) => a.id == id).firstOrNull;
          if (agent == null) continue;
          if (!agentMentions.any((m) => m.id == id)) {
            agentMentions
                .add(MentionEntry(id: id, name: agent.name, notify: true));
          }
        }
      }
      // adminOnly mode: a member's dispatch intent must not vanish silently —
      // the block is stripped but the user is told nothing was activated.
      if (mentionMode == 'adminOnly' &&
          (legacy.steps.isNotEmpty || legacy.parseError != null)) {
        await _saveMemberDispatchDeniedHint(
          channelId: channelId,
          agentName: agent.name,
        );
      }
    } else {
      // Admin: structured mentions are display-only — activation stays
      // tool-first (group_dispatch). Resolve tool/metadata declarations so
      // the bubble highlight stays consistent; text @ is plain text now.
      final resolved = GroupDispatchParser.resolveMentionDeclarations(
        rawDeclarations,
        allAgents,
      );
      agentMentions = resolved.mentions;
      unresolvedMentionNames = resolved.unresolved;
    }
    if (GroupDispatchParser.dispatchJsonBlockPattern
        .hasMatch(responseContent)) {
      responseContent =
          GroupDispatchParser.stripDispatchJsonBlocks(responseContent);
    }

    // Member task-status contract: parse before skip early-return so a
    // pending annotation on an otherwise empty-looking reply still survives
    // into GroupTurnResult (M12-style: capture before bail).
    final memberStatus =
        isAdmin ? null : GroupTaskStatusParser.parse(responseContent);

    // M12: 空响应/[SKIP] 早退必须发生在统一提及捕获（上方）之后——成员可能在
    // 这轮只声明了 group_mention 而未输出正文，提前 return 会丢激活意图，
    // runMentionCascade 就无法唤醒被提及者。这里返回已解析的 mentions。
    if ((responseContent.isEmpty || responseContent.contains('[SKIP]')) &&
        !hasPeerApprovalCard &&
        !hasProgressContent) {
      LoggerService()
          .debug('Agent ${agent.name} skipped', tag: 'GroupAgentExecutor');
      groupTask.isComplete = true;
      groupTask.onTaskFinished?.call();
      _activeGroupTasks[channelId]?.remove(agent.id);
      if (_activeGroupTasks[channelId]?.isEmpty == true) {
        _activeGroupTasks.remove(channelId);
      }
      updateTypingAgentIds();
      ForegroundTaskService().releaseTask(agent.name);
      onAgentDone?.call(agent.id, agent.name, true);
      return GroupTurnResult(
        content: responseContent,
        mentions: agentMentions,
        unresolvedMentionNames: unresolvedMentionNames,
        taskStatusInfo: memberStatus,
      );
    }

    // Build metadata from captured UI tool calls
    final meta = <String, dynamic>{};
    meta['trace_id'] = groupTraceId;
    if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra!);
    if (agentMentions.isNotEmpty) {
      meta['mentions'] = [for (final m in agentMentions) m.toJson()];
    } else {
      // Drop raw metadata mentions that failed resolution so stale or
      // unresolved declarations never drive bubble highlight.
      meta.remove('mentions');
    }
    if (turnTokenUsage.hasAny) {
      meta[LlmTokenUsage.metadataKey] = turnTokenUsage.toJson();
    }
    if (memberStatus != null && memberStatus.applicable) {
      meta['task_status'] = memberStatus.status.name;
      if (memberStatus.reason != null) {
        meta['task_status_reason'] = memberStatus.reason;
      }
    }
    if (actionConfirmationData != null)
      meta['action_confirmation'] = actionConfirmationData;
    if (actionConfirmations != null && actionConfirmations!.isNotEmpty) {
      meta['action_confirmations'] = actionConfirmations;
    }
    if (singleSelectData != null) meta['single_select'] = singleSelectData;
    if (multiSelectData != null) meta['multi_select'] = multiSelectData;
    if (fileUploadData != null) meta['file_upload'] = fileUploadData;
    if (formDataCapture != null) meta['form'] = formDataCapture;
    // Mailbox 轮次的回复必须携带信箱来源元数据（from_mailbox /
    // mailbox_entry_id 等），fetchMailboxReplies 的去重才认得出它——
    // 否则推送拉取与轮询保存双通道会把同一回复插入两次。
    GroupMailboxSavePlan.mergeMetadata(meta, mailboxReply);
    final messageMetadata = meta;

    // Detect active interaction type for blocking (priority: form > action_confirmation > ...)
    String? _activeInteractionType;
    Map<String, dynamic>? _activeInteractionData;
    if (formDataCapture != null) {
      _activeInteractionType = 'form';
      _activeInteractionData = Map<String, dynamic>.from(formDataCapture);
    } else if (actionConfirmationData != null) {
      _activeInteractionType = 'action_confirmation';
      _activeInteractionData =
          Map<String, dynamic>.from(actionConfirmationData!);
    } else if (singleSelectData != null) {
      _activeInteractionType = 'single_select';
      _activeInteractionData = Map<String, dynamic>.from(singleSelectData);
    } else if (multiSelectData != null) {
      _activeInteractionType = 'multi_select';
      _activeInteractionData = Map<String, dynamic>.from(multiSelectData);
    } else if (fileUploadData != null) {
      _activeInteractionType = 'file_upload';
      _activeInteractionData = Map<String, dynamic>.from(fileUploadData);
    }

    // Save to DB — failure here should NOT remove the already-displayed message
    String? savedMessageId;
    try {
      final agentResponse = Message(
        id: GroupMailboxSavePlan.messageIdFor(mailboxReply, _uuid.v4()),
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
        // 信箱回复的确定性 id 可能与推送拉取路径已插入的行冲突——ignore
        // 保留先到者（内容相同），且不能中断后续的已读标记/通知/镜像。
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      // Mark as read immediately — the user is actively viewing this chat
      await _db.markMessageAsRead(agentResponse.id);
      notifyChannelUpdate(channelId);

      // Mirror request + reply into the bound member session so local history
      // matches the remote peer/ACP session shape (inbound + agent response).
      await _memberSessions.mirrorTurn(
        memberSessionId: memberSessionId,
        groupChannelId: channelId,
        userId: userId,
        userName: userName,
        inboundContent: content,
        agentId: agent.id,
        agentName: agent.name,
        replyContent: responseContent,
        replyMetadata: messageMetadata,
        sourceMessageId: agentResponse.id,
      );
    } catch (e) {
      LoggerService().error('Group agent ${agent.name} DB save error',
          tag: 'GroupAgentExecutor', error: e);
      // DB save failed, but the message is already in the UI — keep it
    }

    // If local agent emitted an interactive component, block until user submits
    // (mirrors the remote ACP path's onForm/onActionConfirmation blocking behavior).
    // Peer in-band approvals are resolved during sendChat — skip post-save wait.
    // Already-selected cards (admin auto / panel) also skip — nothing left to ask.
    final skipPostSavePeerApproval = _activeInteractionType ==
            'action_confirmation' &&
        (_activeInteractionData?['confirmation_context'] as String?) == 'peer';
    final alreadyResolved =
        _activeInteractionData?['selected_action_id'] != null ||
            _activeInteractionData?['selected_option_id'] != null ||
            _activeInteractionData?['selected_option_ids'] != null;
    if (!skipPostSavePeerApproval &&
        !alreadyResolved &&
        _activeInteractionType != null &&
        _activeInteractionData != null &&
        savedMessageId != null &&
        onInteractionRequest != null) {
      // Inject _savedMessageId so controller can key pendingGroupInteractions
      // on the correct DB message ID (see chat_controller.dart line 1542)
      final dataForController =
          Map<String, dynamic>.from(_activeInteractionData);
      dataForController['_savedMessageId'] = savedMessageId;

      // Block here: controller creates a GroupInteractionRequestEvent,
      // user fills in the form, handleFormSubmitted completes the Completer
      final userResponse = await onInteractionRequest(
        agent.id,
        agent.name,
        _activeInteractionType,
        dataForController,
      );

      // Sentinel detection: form/file_upload are non-blocking — the controller
      // returned immediately with {'_non_blocking': true}. Skip injecting an
      // "un-submitted" history entry; the user will submit in a new turn.
      final isNonBlocking = userResponse?['_non_blocking'] == true;
      if (!isNonBlocking) {
        // Fallback for non-form types: pick default option on timeout (null response)
        final resolvedResponse = userResponse ??
            (_activeInteractionType != 'form' &&
                    _activeInteractionType != 'file_upload'
                ? _interactionHandler.pickDefaultOption(
                    _activeInteractionType, _activeInteractionData)
                : null);

        // Persist responded state to DB for consistency (survives navigation)
        if (resolvedResponse != null) {
          try {
            final respondedKey = '${_activeInteractionType}_responded';
            final mergedMeta = Map<String, dynamic>.from(messageMetadata);
            mergedMeta[respondedKey] = resolvedResponse;
            // Also stamp the selection onto the interactive section itself so
            // message bubbles render the post-approval (selected) visual state.
            final section = Map<String, dynamic>.from(
              mergedMeta[_activeInteractionType] as Map<String, dynamic>? ??
                  _activeInteractionData,
            );
            section.addAll(resolvedResponse);
            section['selected_at'] = DateTime.now().millisecondsSinceEpoch;
            mergedMeta[_activeInteractionType] = section;
            await _db.updateMessageMetadata(savedMessageId, mergedMeta);
          } catch (e) {
            LoggerService().error(
                'Failed to persist responded state for ${agent.name}',
                tag: 'GroupAgentExecutor',
                error: e);
          }
        }

        // Inject a system message so admin sees the submitted values in loopHistory
        _interactionHandler.saveUserInteractionResultMessage(
          channelId: channelId,
          subAgentName: agent.name,
          interactionType: _activeInteractionType,
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

    LoggerService().debug(
        '_processGroupAgent DONE: ${agent.name}, contentLen=${responseContent.length}',
        tag: 'GroupAgentExecutor');
    onAgentDone?.call(agent.id, agent.name, false);
    return GroupTurnResult(
      content: responseContent,
      steps: [...orchSteps, ...legacySteps],
      wantsContinue: orchWantsContinue,
      isDone: orchIsDone,
      isPause: orchIsPause,
      parseError: orchParseError,
      unresolvedNames: orchUnresolved,
      mentions: agentMentions,
      unresolvedMentionNames: unresolvedMentionNames,
      hasOrchestrationSignal: orchHasSignal,
      taskStatusInfo: memberStatus,
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
  }) {
    final buf = StringBuffer();
    if (systemPrompt.isNotEmpty) {
      buf.writeln(systemPrompt);
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

  Future<void> _saveGroupAgentErrorMessage({
    required String channelId,
    required String agentName,
    required Object error,
  }) async {
    final errorMsg = Message(
      id: _uuid.v4(),
      content: '⚠️ Agent「$agentName」调用失败：$error',
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
  }

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

  /// Group-local agents: admin gets full shepaw CLI; members may only use
  /// [store] (write/read artifacts) and [help] (discovery).
  Future<String> _executeShepawCliForGroup({
    required Map<String, dynamic> args,
    required RemoteAgent agent,
    required bool isAdmin,
    required String channelId,
  }) async {
    if (!isAdmin) {
      final namespace = (args['namespace'] as String?)?.trim() ?? '';
      if (namespace != 'store' && namespace != 'help') {
        return jsonEncode({
          'ok': false,
          'error': '群成员仅可使用 store 与 help 命名空间。产出请用 shepaw store write，'
              '读取请用 shepaw store read --uri <store://...>。'
              '产物写入本群储物袋，不是你个人的 runtime。',
          'allowed_namespaces': ['store', 'help'],
        });
      }
    }
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
    return ShepawCLI.instance.execute(
      args,
      agentId: agent.id,
      channelId: channelId,
      runtimeOwnerId: runtimeOwnerId,
    );
  }

  /// One-shot LLM summary of older group turns for in-context compaction.
  Future<String> _summarizeHistoryForCompaction({
    required RemoteAgent agent,
    required String transcript,
    required Object cancelKey,
  }) async {
    if (transcript.trim().isEmpty) return '';

    final buf = StringBuffer();
    await for (final event in LocalLLMAgentService.instance.runWithCancelKey(
      cancelKey,
      () => LocalLLMAgentService.instance.chat(
        agent: agent,
        message: transcript,
        enableUITools: false,
        includeShepawCli: false,
        skipSheMemoryStack: true,
        systemPromptOverride: HistoryCompactor.summarizerSystemPrompt,
      ),
    )) {
      switch (event) {
        case LLMTextEvent():
          buf.write(event.text);
        case LLMToolCallEvent():
          break;
        case LLMDoneEvent():
          break;
      }
    }
    return buf.toString().trim();
  }
}
