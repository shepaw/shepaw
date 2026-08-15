import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/attachment_data.dart';
import '../../models/planning_models.dart';
import '../../models/inference_log_entry.dart';
import '../../models/model_routing_config.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../trace_service.dart';
import '../acp_agent_connection.dart';
import '../workflow/workflow_service.dart';
import 'group_dispatch_parser.dart';
import 'group_agent_executor.dart';
import 'group_prompt_builder.dart';
import 'group_member_session_service.dart';
import 'group_turn_result.dart';
import 'planning_helpers.dart';
import '../../storage/context_bundle.dart';

class GroupOrchestrationService {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final GroupAgentExecutor _executor;
  final GroupDispatchParser _dispatchParser;
  final PlanningHelpers _planningHelpers;
  final WorkflowService _workflowService;
  final void Function(String channelId) notifyChannelUpdate;
  final Future<List<Message>> Function(String channelId, {int limit, String? excludeMessageId}) loadAndTruncateHistory;
  final Future<Map<String, dynamic>?> Function({
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> planData,
    required String messageId,
  }) awaitPlanApproval;
  final Future<List<Message>> Function(String channelId, {int limit}) loadChannelMessages;
  final Future<Message?> Function(String messageId) getMessageById;

  GroupOrchestrationService({
    required LocalDatabaseService db,
    required Uuid uuid,
    required GroupAgentExecutor executor,
    required GroupDispatchParser dispatchParser,
    required PlanningHelpers planningHelpers,
    required WorkflowService workflowService,
    required this.notifyChannelUpdate,
    required this.loadAndTruncateHistory,
    required this.awaitPlanApproval,
    required this.loadChannelMessages,
    required this.getMessageById,
  })  : _db = db,
        _uuid = uuid,
        _executor = executor,
        _dispatchParser = dispatchParser,
        _planningHelpers = planningHelpers,
        _workflowService = workflowService;

  /// Persist a user-visible system message in the group channel so
  /// orchestration-level failures are never silent in the chat.
  Future<void> _saveOrchestrationSystemMessage(String channelId, String content) async {
    try {
      final msgId = _uuid.v4();
      await _db.createMessage(
        id: msgId,
        channelId: channelId,
        senderId: 'system',
        senderType: 'system',
        senderName: 'System',
        content: content,
        messageType: 'system',
      );
      await _db.markMessageAsRead(msgId);
      notifyChannelUpdate(channelId);
    } catch (e) {
      LoggerService().error('Failed to save orchestration system message', tag: 'GroupOrchestrationService', error: e);
    }
  }

  Future<void> sendMessageToGroup({
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required List<String> agentIds,
    List<String> mentionedAgentIds = const [],
    bool mentionOnlyMode = false,
    String? adminAgentId,
    String? replyToId,
    bool flowMode = false,
    Map<String, dynamic>? userMessageMetadata,
    List<AttachmentData>? attachments,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
    void Function(String? workflowId)? onActiveWorkflowChanged,
    Future<Map<String, dynamic>?> Function(
      String agentId, String agentName, String interactionType, Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    LoggerService().info('sendMessageToGroup: $channelId, agents: $agentIds, admin: $adminAgentId', tag: 'GroupOrchestrationService');

    // 1. Save user message to the group channel
    final userMessage = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: replyToId,
    );

    // Check if channel exists; create is handled by _saveMessageToChannel
    // but for group channels it should already exist from CreateGroupScreen
    await _db.createMessage(
      id: userMessage.id,
      channelId: channelId,
      senderId: userId,
      senderType: 'user',
      senderName: userName,
      content: content,
      messageType: 'text',
      replyToId: replyToId,
      metadata: userMessageMetadata,
    );
    await _db.markMessageAsRead(userMessage.id);
    notifyChannelUpdate(channelId);

    // 2. Load channel info for group prompt
    final channel = await _db.getChannelById(channelId);
    final groupName = channel?.name ?? 'Group';
    final groupDescription = channel?.description ?? '';
    final channelMembers = channel?.members ?? <ChannelMember>[];
    final customSystemPrompt = channel?.systemPrompt;
    final mentionMode = channel?.effectiveMentionMode ?? 'adminOnly';

    // Ensure each agent member has a DM session bound 1:1 to this group session
    // (covers legacy groups created before binding existed).
    if (channel != null) {
      await GroupMemberSessionService(_db).ensureMemberSessionsForGroup(
        groupChannel: channel,
        userId: userId,
      );
    }

    // 3. Load all agent RemoteAgent objects
    final List<RemoteAgent> agents = [];
    for (final agentId in agentIds) {
      final agent = await _db.getRemoteAgentById(agentId);
      if (agent != null) agents.add(agent);
    }

    if (agents.isEmpty) {
      LoggerService().warning('No valid agents found for group, agentIds=$agentIds', tag: 'GroupOrchestrationService');
      onAllDone?.call();
      return;
    }

    // 4. Load conversation history ONCE before all agents start (snapshot)
    // For first-time conversations (no prior agent messages), load more history.
    final allMessages = await loadChannelMessages(channelId, limit: 100);
    // Include all non-system messages (text + attachment summaries) so agents
    // have context about shared files/images without loading raw content.
    final eligibleMessages = allMessages
        .where((m) => m.type != MessageType.system && m.type != MessageType.permissionAudit)
        .toList();

    // Determine which agents have prior messages in the channel
    final agentIdsWithHistory = <String>{};
    for (final m in eligibleMessages) {
      if (m.from.isAgent) {
        agentIdsWithHistory.add(m.from.id);
      }
    }

    // Always use full history (up to 100) so agents can rebuild context
    // even after restart, rather than limiting to 40 when agents have history.
    var historyMessages = eligibleMessages.toList();

    // Remove the current user message from history — it will be sent
    // separately as the 'message' parameter to avoid duplication.
    if (historyMessages.isNotEmpty && historyMessages.last.id == userMessage.id) {
      historyMessages = historyMessages.sublist(0, historyMessages.length - 1);
    }

    // Per-agent context budget is applied in GroupAgentExecutor:
    // local agents use HistoryCompactor; peer/ACP use FIFO truncate.
    // Pass the full loaded snapshot so compaction still has material.

    // Build message version info for agent context sync
    final messageVersion = <String, dynamic>{
      'total_count': allMessages.length,
      'latest_message_id': allMessages.isNotEmpty ? allMessages.last.id : null,
      'latest_timestamp': allMessages.isNotEmpty ? allMessages.last.timestampMs : null,
    };

    // Resolve quoted message content so agents understand reply context
    String effectiveContent = content;
    if (replyToId != null) {
      final quotedMessage = await getMessageById(replyToId);
      if (quotedMessage != null) {
        effectiveContent = '[引用 ${quotedMessage.from.name} 的消息: "${quotedMessage.content}"]\n\n$content';
      }
    }
    // §6.3 + ContextBundle：群编排委派注入产物 URI + runtime 上下文清单
    final groupOwnerId = (channel?.parentGroupId?.isNotEmpty == true)
        ? channel!.parentGroupId!
        : channelId;
    effectiveContent = await ContextBundleService.instance.wrapWithContextBundle(
      effectiveContent,
      ownerId: groupOwnerId,
      channelId: channelId,
      isGroup: true,
    );

    // 5. Route to the appropriate flow based on admin setting and @mentions
    LoggerService().debug('Routing: mentions=${mentionedAgentIds.length}, admin=$adminAgentId, agents=${agents.map((a) => a.name).toList()}', tag: 'GroupOrchestrationService');

    // If the only @mentioned agent is the admin itself, treat this as an
    // admin-first flow (path 5b) so that:
    //  (a) the admin is invoked with its admin system prompt and can generate
    //      interactive UI widgets (e.g. action_confirmation after form submit)
    //  (b) the orchestration loop runs, so the admin's subsequent @mentions
    //      of member agents are properly activated.
    final effectiveMentionedAgentIds = (adminAgentId != null &&
            mentionedAgentIds.length == 1 &&
            mentionedAgentIds.first == adminAgentId)
        ? <String>[]
        : mentionedAgentIds;

    final routePath = effectiveMentionedAgentIds.isNotEmpty
        ? 'mention_direct'
        : adminAgentId != null
            ? (flowMode ? 'admin_flow' : 'admin_first')
            : 'broadcast';

    // Always create an orchestration root so @mention-direct / broadcast
    // turns also parent their member traces (and get persisted on exit).
    final adminForTrace = adminAgentId != null
        ? agents.where((a) => a.id == adminAgentId).firstOrNull
        : null;
    String? orchTraceId = TraceService.instance.beginGroupOrchestration(
      channelId: channelId,
      adminAgentId: adminForTrace?.id ?? 'system',
      adminAgentName: adminForTrace?.name ?? 'system',
      userMessage: content,
      memberAgentIds: agentIds,
      flowMode: flowMode,
      routePath: routePath,
      mentionedAgentIds: effectiveMentionedAgentIds,
      userMessageId: userMessage.id,
    );
    final routeSpanId = TraceService.instance.addSpan(
      traceId: orchTraceId,
      spanType: 'dispatch_decision',
      name: 'route',
      metadata: {
        'route_path': routePath,
        'mentioned_agent_ids': effectiveMentionedAgentIds,
        'admin_agent_id': adminAgentId,
        'user_message_id': userMessage.id,
        'mention_mode': mentionMode,
      },
    );
    TraceService.instance.endSpan(routeSpanId, status: 'completed');

    Future<void> endOrchTrace(InferenceStatus status) async {
      if (orchTraceId != null) {
        await TraceService.instance.endTrace(orchTraceId!, status);
        orchTraceId = null;
      }
    }

    if (effectiveMentionedAgentIds.isNotEmpty) {
      // 5a. User explicitly @mentioned agents — those agents respond directly
      final futures = <Future<void>>[];
      for (final agent in agents) {
        if (!effectiveMentionedAgentIds.contains(agent.id)) {
          onAgentDone?.call(agent.id, agent.name, true);
          continue;
        }
        onAgentStart?.call(agent.id, agent.name);
        final isFirstMessage = !agentIdsWithHistory.contains(agent.id);
        futures.add(
          _executor.processGroupAgent(
            agent: agent,
            channelId: channelId,
            content: effectiveContent,
            attachments: attachments,
            userId: userId,
            userName: userName,
            groupName: groupName,
            groupDescription: groupDescription,
            allAgents: agents,
            historyMessages: historyMessages,
            mentionedAgentIds: effectiveMentionedAgentIds,
            isFirstMessage: isFirstMessage,
            messageVersion: messageVersion,
            channelMembers: channelMembers,
            customSystemPrompt: customSystemPrompt,
            mentionMode: mentionMode,
            acpCancellationToken: acpCancellationToken,
            onStreamChunk: onStreamChunk,
            onAgentDone: onAgentDone,
            onInteractionRequest: onInteractionRequest,
            orchestrationTraceId: orchTraceId,
          ).catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(agent.id, agent.name, true);
            return const GroupTurnResult();
          }),
        );
      }
      await Future.wait(futures);

      // allMembers cascading for Path 5a: after mentioned agents respond,
      // check if any of them dispatched other agents via structured JSON.
      if (mentionMode == 'allMembers') {
        const maxCascadeDepth = 3;
        final respondedAgentIds = <String>{...effectiveMentionedAgentIds};
        final nonAdminAgentsForCascade = adminAgentId != null
            ? agents.where((a) => a.id != adminAgentId).toList()
            : agents;

        for (int cascadeRound = 0; cascadeRound < maxCascadeDepth; cascadeRound++) {
          if (acpCancellationToken?.isCancelled == true) break;

          final cascadeHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

          final newMentionedIds = <String>{};
          final cascadeSteps = <DispatchStep>[];
          for (final msg in cascadeHistory.reversed) {
            if (!msg.from.isAgent) continue;
            if (!respondedAgentIds.contains(msg.from.id)) continue;
            final dispatch = _dispatchParser.parseStructuredDispatch(msg.content, nonAdminAgentsForCascade);
            cascadeSteps.addAll(dispatch.steps);
            for (final mentionId in dispatch.steps.expand((s) => s.agentIds)) {
              if (!respondedAgentIds.contains(mentionId) && mentionId != adminAgentId) {
                newMentionedIds.add(mentionId);
              }
            }
            if (dispatch.steps.isNotEmpty) {
              await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, msg.from.id);
            }
          }

          if (newMentionedIds.isEmpty) break;

          LoggerService().debug('allMembers cascade (5a) round ${cascadeRound + 1}: dispatching ${newMentionedIds.length} newly-mentioned agents', tag: 'GroupOrchestrationService');

          final cascadeFutures = <Future<void>>[];
          final cascadeHistoryForAgents = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
          for (final agent in agents) {
            if (!newMentionedIds.contains(agent.id)) continue;
            onAgentStart?.call(agent.id, agent.name);
            final isFirst = !agentIdsWithHistory.contains(agent.id);
            cascadeFutures.add(
              _executor.processGroupAgent(
                agent: agent,
                channelId: channelId,
                content: GroupDispatchParser.taskContentForAgent(
                  agentId: agent.id,
                  steps: cascadeSteps,
                  fallback: effectiveContent,
                ),
                attachments: attachments,
                userId: userId,
                userName: userName,
                groupName: groupName,
                groupDescription: groupDescription,
                allAgents: agents,
                historyMessages: cascadeHistoryForAgents,
                mentionedAgentIds: newMentionedIds.toList(),
                isFirstMessage: isFirst,
                messageVersion: messageVersion,
                channelMembers: channelMembers,
                customSystemPrompt: customSystemPrompt,
                mentionMode: mentionMode,
                acpCancellationToken: acpCancellationToken,
                onStreamChunk: onStreamChunk,
                onAgentDone: onAgentDone,
                onInteractionRequest: onInteractionRequest,
                orchestrationTraceId: orchTraceId,
              ).catchError((e) {
                LoggerService().error('Cascade agent (5a) ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
                onAgentDone?.call(agent.id, agent.name, true);
                return const GroupTurnResult();
              }),
            );
          }
          await Future.wait(cascadeFutures);
          respondedAgentIds.addAll(newMentionedIds);
        }
      }

      await endOrchTrace(InferenceStatus.completed);
      onAllDone?.call();
      return;
    } else if (adminAgentId != null) {
      // 5b. Admin-first flow: only admin responds, then delegates via @mentions
      final adminAgent = agents.where((a) => a.id == adminAgentId).firstOrNull;
      if (adminAgent == null) {
        LoggerService().warning('Admin agent $adminAgentId not found, falling back to all-agents mode', tag: 'GroupOrchestrationService');
      }
      if (adminAgent != null) {
        // Skip non-admin agents immediately
        for (final agent in agents) {
          if (agent.id != adminAgentId) {
            onAgentDone?.call(agent.id, agent.name, true);
          }
        }

        final nonAdminAgents = agents.where((a) => a.id != adminAgentId).toList();

        // Flag: set when the admin agent itself triggers a non-blocking interaction
        // (form / file_upload / action_confirmation in non-flow mode) so the
        // orchestration loop can exit immediately and let the user respond in
        // the next conversation turn.
        bool adminTriggeredNonBlockingInteraction = false;
        Future<Map<String, dynamic>?> onInteractionRequestForAdmin(
          String agentId, String agentName, String interactionType, Map<String, dynamic> data,
        ) async {
          final result = await onInteractionRequest?.call(agentId, agentName, interactionType, data);
          if (result?['_non_blocking'] == true && agentId == adminAgent.id) {
            adminTriggeredNonBlockingInteraction = true;
          }
          return result;
        }

        // Helper to call _executor.processGroupAgent with orchestration trace context
        Future<void> callGroupAgent({
          required RemoteAgent agent,
          required List<Message> historyMessages,
          required List<String> mentionedAgentIds,
          required bool isFirstMessage,
          bool isAdmin = false,
          RemoteAgent? adminAgent,
          bool isLoopSummarize = false,
          bool isAbortSummarize = false,
          int? loopRound,
          List<String> failedAgentNames = const [],
          bool isFlowMode = false,
        }) => _executor.processGroupAgent(
          agent: agent,
          channelId: channelId,
          content: effectiveContent,
          attachments: attachments,
          userId: userId,
          userName: userName,
          groupName: groupName,
          groupDescription: groupDescription,
          allAgents: agents,
          historyMessages: historyMessages,
          mentionedAgentIds: mentionedAgentIds,
          isFirstMessage: isFirstMessage,
          isAdmin: isAdmin,
          messageVersion: messageVersion,
          channelMembers: channelMembers,
          adminAgent: adminAgent,
          customSystemPrompt: customSystemPrompt,
          isLoopSummarize: isLoopSummarize,
          isAbortSummarize: isAbortSummarize,
          loopRound: loopRound,
          mentionMode: mentionMode,
          failedAgentNames: failedAgentNames,
          acpCancellationToken: acpCancellationToken,
          isFlowMode: isFlowMode,
          onStreamChunk: onStreamChunk,
          onAgentDone: onAgentDone,
          onInteractionRequest: onInteractionRequest,
          orchestrationTraceId: orchTraceId,
        );

        // Detect non-text modality in recent history (e.g. images sent by user)
        final detectedModality = const GroupPromptBuilder().detectRecentAttachmentModality(historyMessages);

        // If admin cannot handle the detected modality, auto-delegate instead
        // of calling the LLM (which would fail with a 400 error).
        if (detectedModality != ModalityType.text &&
            !adminAgent.supportsModality(detectedModality)) {
          LoggerService().info('Admin ${adminAgent.name} does not support $detectedModality, auto-delegating', tag: 'GroupOrchestrationService');

          // Find a capable agent among non-admin members
          final capableAgent = nonAdminAgents.cast<RemoteAgent?>().firstWhere(
            (a) => a!.supportsModality(detectedModality),
            orElse: () => null,
          );

          if (capableAgent != null) {
            // Generate a delegation message from admin
            final modalityLabel = {
              ModalityType.image: '图片',
              ModalityType.audio: '音频',
              ModalityType.video: '视频',
            }[detectedModality] ?? '多模态';

            final delegationText =
                '这条消息包含${modalityLabel}内容，我无法直接处理，@${capableAgent.name} 请协助处理。';

            // Save admin's delegation message to the database
            final delegationMsgId = _uuid.v4();
            await _db.createMessage(
              id: delegationMsgId,
              channelId: channelId,
              senderId: adminAgent.id,
              senderType: 'agent',
              senderName: adminAgent.name,
              content: delegationText,
              messageType: 'text',
            );
            await _db.markMessageAsRead(delegationMsgId);
            notifyChannelUpdate(channelId);

            // Notify UI of admin's delegation message
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            onStreamChunk?.call(adminAgent.id, adminAgent.name, delegationText);
            onAgentDone?.call(adminAgent.id, adminAgent.name, false);

            // Now dispatch the capable agent
            onAgentStart?.call(capableAgent.id, capableAgent.name);
            final isFirst = !agentIdsWithHistory.contains(capableAgent.id);

            // Reload history so the delegated agent sees admin's delegation message
            final updatedHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

            try {
              await callGroupAgent(
                agent: capableAgent,
                historyMessages: updatedHistory,
                mentionedAgentIds: [capableAgent.id],
                isFirstMessage: isFirst,
                adminAgent: adminAgent,
              );
            } catch (e) {
              LoggerService().error('Delegated agent ${capableAgent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
              onAgentDone?.call(capableAgent.id, capableAgent.name, true);
            }
          } else {
            // No agent in the group can handle this modality
            final modalityLabel = {
              ModalityType.image: '图片',
              ModalityType.audio: '音频',
              ModalityType.video: '视频',
            }[detectedModality] ?? '多模态';

            final hintMsg = Message(
              id: _uuid.v4(),
              content: '当前群聊中没有成员能处理${modalityLabel}类型消息，请添加支持该功能的 Agent。',
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              from: MessageFrom(id: 'system', type: 'system', name: 'System'),
              type: MessageType.system,
            );
            await _db.createMessage(
              id: hintMsg.id,
              channelId: channelId,
              senderId: 'system',
              senderType: 'system',
              senderName: 'System',
              content: hintMsg.content,
              messageType: 'system',
            );
            await _db.markMessageAsRead(hintMsg.id);
            notifyChannelUpdate(channelId);

            // Mark admin as done (skipped)
            onAgentDone?.call(adminAgent.id, adminAgent.name, true);
          }

          await endOrchTrace(InferenceStatus.completed);
          onAllDone?.call();
          return;
        }

        // Admin supports the modality (or message is text-only) — loop orchestration flow
        final maxRounds = channel?.effectiveMaxLoopRounds ?? 50;
        int currentRound = 0;
        String adminResponseContent = '';
        var adminTurn = const GroupTurnResult();

        GroupTurnResult resolveAdminDecision(GroupTurnResult toolTurn) {
          final text = adminResponseContent;
          if (toolTurn.hasOrchestrationSignal) {
            return GroupTurnResult(
              content: text.isNotEmpty ? text : toolTurn.content,
              steps: toolTurn.steps,
              wantsContinue: toolTurn.wantsContinue,
              isDone: toolTurn.isDone || toolTurn.isPause,
              isPause: toolTurn.isPause,
              parseError: toolTurn.parseError,
              unresolvedNames: toolTurn.unresolvedNames,
              hasOrchestrationSignal: true,
            );
          }
          // Legacy fallback: ```json``` dispatch block in chat text.
          final parsed =
              _dispatchParser.parseStructuredDispatch(text, nonAdminAgents);
          if (parsed.parseError != null && parsed.steps.isEmpty) {
            return GroupTurnResult(
              content: text,
              parseError: parsed.parseError,
              unresolvedNames: parsed.unresolvedNames,
            );
          }
          return GroupTurnResult(
            content: text,
            steps: parsed.steps,
            wantsContinue: parsed.wantsContinue,
            isDone: parsed.isDone || parsed.isPause || (parsed.steps.isEmpty && !parsed.wantsContinue),
            isPause: parsed.isPause,
            unresolvedNames: parsed.unresolvedNames,
          );
        }

        // 1. First admin call
        onAgentStart?.call(adminAgent.id, adminAgent.name);
        final isFirstMessage = !agentIdsWithHistory.contains(adminAgent.id);
        adminResponseContent = '';
        try {
          adminTurn = await _executor.processGroupAgent(
            agent: adminAgent,
            channelId: channelId,
            content: effectiveContent,
            attachments: attachments,
            userId: userId,
            userName: userName,
            groupName: groupName,
            groupDescription: groupDescription,
            allAgents: agents,
            historyMessages: historyMessages,
            mentionedAgentIds: const [],
            isFirstMessage: isFirstMessage,
            isAdmin: true,
            messageVersion: messageVersion,
            channelMembers: channelMembers,
            customSystemPrompt: customSystemPrompt,
            mentionMode: mentionMode,
            isFlowMode: flowMode,
            acpCancellationToken: acpCancellationToken,
            onStreamChunk: (agentId, agentName, chunk) {
              adminResponseContent += chunk;
              onStreamChunk?.call(agentId, agentName, chunk);
            },
            onAgentDone: onAgentDone,
            onInteractionRequest: onInteractionRequestForAdmin,
            orchestrationTraceId: orchTraceId,
          );
        } catch (e) {
          LoggerService().error('Admin agent ${adminAgent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
          onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
        }
        currentRound++;
        adminTurn = resolveAdminDecision(adminTurn);

        // If the first admin reply already contains a plan or dispatch, create a workflow
        // before entering the delegation loop.
        final earlyFlowPlan = FlowPlan.tryParse(adminResponseContent);
        if (earlyFlowPlan != null &&
            earlyFlowPlan.stages.any((s) => s.steps.isNotEmpty)) {
          await _planningHelpers.stripFlowPlanBlockFromLastMessage(channelId, adminAgent.id);
          if (await _offerWorkflowFromPlan(
            channelId: channelId,
            adminAgent: adminAgent,
            flowPlan: earlyFlowPlan,
            triggerMessageId: userMessage.id,
            onActiveWorkflowChanged: onActiveWorkflowChanged,
            onInteractionRequest: onInteractionRequestForAdmin,
          )) {
            await endOrchTrace(InferenceStatus.completed);
            onAllDone?.call();
            return;
          }
        }

        final firstDispatch = adminTurn;
        if (firstDispatch.steps.isNotEmpty) {
          await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
          final dispatchPlan = _dispatchParser.buildFlowPlanFromDispatch(
            steps: firstDispatch.steps,
            mode: firstDispatch.steps.first.mode,
            agents: agents,
            summary: effectiveContent,
            title: groupName,
          );
          if (await _offerWorkflowFromPlan(
            channelId: channelId,
            adminAgent: adminAgent,
            flowPlan: dispatchPlan,
            triggerMessageId: userMessage.id,
            onActiveWorkflowChanged: onActiveWorkflowChanged,
            onInteractionRequest: onInteractionRequestForAdmin,
          )) {
            await endOrchTrace(InferenceStatus.completed);
            onAllDone?.call();
            return;
          }
        }

        // 2. Loop: parse dispatch JSON → delegate → admin summarize → repeat
        final failedAgentNames = <String>[];
        var dispatchNudgeCount = 0;
        const maxDispatchNudges = 2;
        // Compact record of the last dispatch. The dispatch JSON is stripped
        // from the admin's message (user-facing), so this note is re-injected
        // into the summarize round to let the admin remember its own plan.
        String? lastDispatchNote;
        while (true) {
          // If admin sent a form/file_upload in the previous round, exit immediately
          // so the user can fill it in (forms are non-blocking).
          if (adminTriggeredNonBlockingInteraction) {
            LoggerService().debug('Loop orchestration ended: admin triggered non-blocking interaction', tag: 'GroupOrchestrationService');
            break;
          }
          // Check cancellation — run abort-summarize before exiting if we have
          // already done at least one round (i.e. Admin has produced content).
          if (acpCancellationToken?.isCancelled == true) {
            LoggerService().info('Loop orchestration cancelled at round $currentRound', tag: 'GroupOrchestrationService');
            if (adminResponseContent.trim().isNotEmpty) {
              final abortHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: effectiveContent,
                  attachments: attachments,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: abortHistory,
                  mentionedAgentIds: const [],
                  isFirstMessage: false,
                  isAdmin: true,
                  isLoopSummarize: true,
                  isAbortSummarize: true,
                  loopRound: currentRound + 1,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                    failedAgentNames: List.unmodifiable(failedAgentNames),
                  onStreamChunk: (agentId, agentName, chunk) {
                    adminResponseContent += chunk;
                    onStreamChunk?.call(agentId, agentName, chunk);
                  },
                  onAgentDone: onAgentDone,
                  onInteractionRequest: onInteractionRequestForAdmin,
                  orchestrationTraceId: orchTraceId,
                );
              } catch (e) {
                LoggerService().error('Admin abort-summarize (loop-start cancel) error', tag: 'GroupOrchestrationService', error: e);
                onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
              }
              // Hide the closing {"done": true} JSON block from the user.
              await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
            }
            break;
          }

          // Check round limit
          if (currentRound >= maxRounds) {
            LoggerService().info('Loop orchestration reached max rounds ($maxRounds)', tag: 'GroupOrchestrationService');
            final limitMsg = Message(
              id: _uuid.v4(),
              content: '编排循环已达到最大轮次 $maxRounds 次，已自动停止。',
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              from: MessageFrom(id: 'system', type: 'system', name: 'System'),
              type: MessageType.system,
            );
            await _db.createMessage(
              id: limitMsg.id,
              channelId: channelId,
              senderId: 'system',
              senderType: 'system',
              senderName: 'System',
              content: limitMsg.content,
              messageType: 'system',
            );
            await _db.markMessageAsRead(limitMsg.id);
            notifyChannelUpdate(channelId);

            // Run abort-summarize so Admin can wrap up what was accomplished
            final maxRoundsHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: effectiveContent,
                attachments: attachments,
                userId: userId,
                userName: userName,
                groupName: groupName,
                groupDescription: groupDescription,
                allAgents: agents,
                historyMessages: maxRoundsHistory,
                mentionedAgentIds: const [],
                isFirstMessage: false,
                isAdmin: true,
                isLoopSummarize: true,
                isAbortSummarize: true,
                loopRound: currentRound + 1,
                messageVersion: messageVersion,
                channelMembers: channelMembers,
                customSystemPrompt: customSystemPrompt,
                mentionMode: mentionMode,
                  failedAgentNames: List.unmodifiable(failedAgentNames),
                onStreamChunk: (agentId, agentName, chunk) {
                  adminResponseContent += chunk;
                  onStreamChunk?.call(agentId, agentName, chunk);
                },
                onAgentDone: onAgentDone,
                onInteractionRequest: onInteractionRequestForAdmin,
                orchestrationTraceId: orchTraceId,
              );
            } catch (e) {
              LoggerService().error('Admin abort-summarize (maxRounds) error', tag: 'GroupOrchestrationService', error: e);
              onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
            }
            // Hide the closing {"done": true} JSON block from the user.
            await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
            break;
          }

          // Prefer tool-first orchestration; fall back to legacy text JSON.
          final dispatch = resolveAdminDecision(adminTurn);
          adminTurn = dispatch;
          final adminWantsContinue = dispatch.wantsContinue;
          final delegatedIds = dispatch.steps
              .expand((s) => s.agentIds)
              .toSet()
              .toList();

          final flowPlanInRound = FlowPlan.tryParse(adminResponseContent);
          if (flowPlanInRound != null &&
              flowPlanInRound.stages.any((s) => s.steps.isNotEmpty)) {
            await _planningHelpers.stripFlowPlanBlockFromLastMessage(channelId, adminAgent.id);
            if (await _offerWorkflowFromPlan(
              channelId: channelId,
              adminAgent: adminAgent,
              flowPlan: flowPlanInRound,
              triggerMessageId: userMessage.id,
              onActiveWorkflowChanged: onActiveWorkflowChanged,
              onInteractionRequest: onInteractionRequestForAdmin,
            )) {
              break;
            }
          }

          // Nudge when dispatch tool/text failed to produce usable steps.
          if (dispatch.parseError != null && dispatch.steps.isEmpty) {
            if (dispatchNudgeCount < maxDispatchNudges) {
              dispatchNudgeCount++;
              LoggerService().warning(
                'Dispatch failed at round $currentRound (${dispatch.parseError}); nudging admin ($dispatchNudgeCount/$maxDispatchNudges)',
                tag: 'GroupOrchestrationService',
              );
              await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
              final nudgeHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                adminTurn = await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: '$effectiveContent\n\n[SYSTEM] 你上一条回复中的派发指令无法执行：${dispatch.parseError}。请调用 `group_dispatch` 重新派活（agents 必须用注册名），或调用 `group_finish`（done/continue/pause）；若无需派发请直接给出最终答复并 finish。',
                  attachments: attachments,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: nudgeHistory,
                  mentionedAgentIds: const [],
                  isFirstMessage: false,
                  isAdmin: true,
                  isDispatchNudge: true,
                  loopRound: currentRound + 1,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                  acpCancellationToken: acpCancellationToken,
                  onStreamChunk: (agentId, agentName, chunk) {
                    adminResponseContent += chunk;
                    onStreamChunk?.call(agentId, agentName, chunk);
                  },
                  onAgentDone: onAgentDone,
                  onInteractionRequest: onInteractionRequestForAdmin,
                  orchestrationTraceId: orchTraceId,
                );
              } catch (e) {
                LoggerService().error('Admin nudge error at round $currentRound', tag: 'GroupOrchestrationService', error: e);
                onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
                break;
              }
              currentRound++;
              adminTurn = resolveAdminDecision(adminTurn);
              if (adminResponseContent.trim().isEmpty &&
                  !adminTurn.hasOrchestrationSignal) {
                LoggerService().warning('Admin nudge produced empty response at round $currentRound, stopping', tag: 'GroupOrchestrationService');
                break;
              }
              continue;
            }
            // Nudge budget exhausted — surface the failure and stop.
            await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
            await _saveOrchestrationSystemMessage(
              channelId,
              '⚠️ 管理员的派发指令多次无法解析（${dispatch.parseError}），流程已停止，请重新描述需求再试。',
            );
            break;
          }

          // Some dispatched names did not match any member — keep going with
          // the resolved steps but tell the user what was dropped.
          if (dispatch.unresolvedNames.isNotEmpty) {
            await _saveOrchestrationSystemMessage(
              channelId,
              '⚠️ 派发指令中的成员名称「${dispatch.unresolvedNames.join('、')}」未匹配到群成员，对应任务未执行。',
            );
          }

          // Record the dispatch plan before the JSON is stripped from the
          // admin's message, so the summarize round can be reminded of it.
          if (dispatch.steps.isNotEmpty) {
            lastDispatchNote = dispatch.steps.map((s) {
              final names = s.agentIds.map((id) {
                final a = agents.where((x) => x.id == id).firstOrNull;
                return a?.name ?? id;
              }).join('、');
              return '步骤${s.step}→$names：${s.task}';
            }).join('；');
          }

          // Record dispatch decision in orchestration trace
          if (orchTraceId != null) {
            final dSpanId = TraceService.instance.addSpan(
              traceId: orchTraceId!,
              spanType: 'dispatch_decision',
              name: 'Dispatch Round $currentRound',
              inputData: {
                'delegated_ids': delegatedIds,
                'wants_continue': adminWantsContinue,
                'is_done': delegatedIds.isEmpty && !adminWantsContinue,
                'step_count': dispatch.steps.length,
              },
            );
            TraceService.instance.endSpan(dSpanId, status: 'completed');
          }

          if (delegatedIds.isEmpty && !adminWantsContinue) {
            // No dispatch and no continue — orchestration complete. Strip the
            // closing {"done": true} JSON block so the user never sees it.
            LoggerService().debug('Loop orchestration ended: no dispatch at round $currentRound', tag: 'GroupOrchestrationService');
            await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
            break;
          }

          // If admin wants to continue on its own (no delegation needed),
          // strip the dispatch JSON block, reload history and re-invoke admin directly.
          if (delegatedIds.isEmpty && adminWantsContinue) {
            // Check cancellation before re-invoking admin — run abort-summarize first
            if (acpCancellationToken?.isCancelled == true) {
              LoggerService().info('Admin continue cancelled at round $currentRound', tag: 'GroupOrchestrationService');
              await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
              final abortHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: effectiveContent,
                  attachments: attachments,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: abortHistory,
                  mentionedAgentIds: const [],
                  isFirstMessage: false,
                  isAdmin: true,
                  isLoopSummarize: true,
                  isAbortSummarize: true,
                  loopRound: currentRound + 1,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                    failedAgentNames: List.unmodifiable(failedAgentNames),
                  onStreamChunk: (agentId, agentName, chunk) {
                    adminResponseContent += chunk;
                    onStreamChunk?.call(agentId, agentName, chunk);
                  },
                  onAgentDone: onAgentDone,
                  onInteractionRequest: onInteractionRequestForAdmin,
                  orchestrationTraceId: orchTraceId,
                );
              } catch (e) {
                LoggerService().error('Admin abort-summarize (continue cancel) error', tag: 'GroupOrchestrationService', error: e);
                onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
              }
              break;
            }

            LoggerService().debug('Admin continue at round $currentRound, re-invoking admin', tag: 'GroupOrchestrationService');
            await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);

            final continueHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              adminTurn = await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: effectiveContent,
                attachments: attachments,
                userId: userId,
                userName: userName,
                groupName: groupName,
                groupDescription: groupDescription,
                allAgents: agents,
                historyMessages: continueHistory,
                mentionedAgentIds: const [],
                isFirstMessage: false,
                isAdmin: true,
                isLoopSummarize: true,
                loopRound: currentRound + 1,
                messageVersion: messageVersion,
                channelMembers: channelMembers,
                customSystemPrompt: customSystemPrompt,
                mentionMode: mentionMode,
                failedAgentNames: List.unmodifiable(failedAgentNames),
                acpCancellationToken: acpCancellationToken,
                onStreamChunk: (agentId, agentName, chunk) {
                  adminResponseContent += chunk;
                  onStreamChunk?.call(agentId, agentName, chunk);
                },
                onAgentDone: onAgentDone,
                onInteractionRequest: onInteractionRequestForAdmin,
                orchestrationTraceId: orchTraceId,
              );
            } catch (e) {
              LoggerService().error('Admin continue error at round $currentRound', tag: 'GroupOrchestrationService', error: e);
              onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
              break;
            }
            currentRound++;
            adminTurn = resolveAdminDecision(adminTurn);

            // Guard against empty responses to prevent stuck loops
            if (adminResponseContent.trim().isEmpty &&
                !adminTurn.hasOrchestrationSignal) {
              LoggerService().warning('Admin continue produced empty response at round $currentRound, stopping', tag: 'GroupOrchestrationService');
              break;
            }
            continue;
          }

          // Strip dispatch JSON from saved message before delegating
          await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);

          // Structured task dispatch → create workflow + approval card instead of
          // running inline delegation (execution starts after user approval).
          if (dispatch.steps.isNotEmpty) {
            final flowPlanFromDispatch = _dispatchParser.buildFlowPlanFromDispatch(
              steps: dispatch.steps,
              mode: dispatch.steps.first.mode,
              agents: agents,
              summary: effectiveContent,
              title: groupName,
            );
            if (await _offerWorkflowFromPlan(
              channelId: channelId,
              adminAgent: adminAgent,
              flowPlan: flowPlanFromDispatch,
              triggerMessageId: userMessage.id,
              onActiveWorkflowChanged: onActiveWorkflowChanged,
              onInteractionRequest: onInteractionRequestForAdmin,
            )) {
              break;
            }
          }

          // Reset failed-agent tracking for this delegation round
          failedAgentNames.clear();

          // Execute delegated agents based on dispatch mode
          final isSequential = dispatch.steps.isNotEmpty &&
              dispatch.steps.first.mode == 'sequential';

          if (isSequential) {
            // Sequential workflow: execute steps in order
            for (final step in dispatch.steps) {
              if (acpCancellationToken?.isCancelled == true) break;
              final stepAgentIds = step.agentIds;

              // Reload history before each step so agents see previous steps' output
              final stepHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

              // Launch all agents within this step concurrently
              final stepFutures = <Future<void>>[];
              for (final agent in agents) {
                if (!stepAgentIds.contains(agent.id)) continue;
                onAgentStart?.call(agent.id, agent.name);
                final isFirst = !agentIdsWithHistory.contains(agent.id);
                stepFutures.add(
                  _executor.processGroupAgent(
                    agent: agent,
                    channelId: channelId,
                    content: step.contentOr(effectiveContent),
                    attachments: attachments,
                    userId: userId,
                    userName: userName,
                    groupName: groupName,
                    groupDescription: groupDescription,
                    allAgents: agents,
                    historyMessages: stepHistory,
                    mentionedAgentIds: delegatedIds,
                    isFirstMessage: isFirst,
                    messageVersion: messageVersion,
                    channelMembers: channelMembers,
                    adminAgent: adminAgent,
                    customSystemPrompt: customSystemPrompt,
                    mentionMode: mentionMode,
                    acpCancellationToken: acpCancellationToken,
                    onStreamChunk: onStreamChunk,
                    onAgentDone: onAgentDone,
                    onInteractionRequest: onInteractionRequest,
                  ).catchError((e) {
                    LoggerService().error('Step ${step.step} agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
                    failedAgentNames.add(agent.name);
                    onAgentDone?.call(agent.id, agent.name, true);
                    return const GroupTurnResult();
                  }),
                );
              }
              await Future.wait(stepFutures);

            }
          } else {
            // Concurrent execution (default)
            final updatedHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

            final delegatedFutures = <Future<void>>[];
            for (final agent in agents) {
              if (!delegatedIds.contains(agent.id)) continue;
              onAgentStart?.call(agent.id, agent.name);
              final isFirst = !agentIdsWithHistory.contains(agent.id);
              delegatedFutures.add(
                _executor.processGroupAgent(
                  agent: agent,
                  channelId: channelId,
                  content: GroupDispatchParser.taskContentForAgent(
                    agentId: agent.id,
                    steps: dispatch.steps,
                    fallback: effectiveContent,
                  ),
                  attachments: attachments,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: updatedHistory,
                  mentionedAgentIds: delegatedIds,
                  isFirstMessage: isFirst,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  adminAgent: adminAgent,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                  acpCancellationToken: acpCancellationToken,
                  onStreamChunk: onStreamChunk,
                  onAgentDone: onAgentDone,
                  onInteractionRequest: onInteractionRequest,
                ).catchError((e) {
                  LoggerService().error('Delegated agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
                  failedAgentNames.add(agent.name);
                  onAgentDone?.call(agent.id, agent.name, true);
                  return const GroupTurnResult();
                }),
              );
            }
            await Future.wait(delegatedFutures);
          }

          // allMembers cascading: after delegated agents respond, check if
          // any of them dispatched other agents via structured JSON. Cascade up to 3 extra rounds.
          if (mentionMode == 'allMembers') {
            const maxCascadeDepth = 3;
            final respondedAgentIds = <String>{...delegatedIds};

            for (int cascadeRound = 0; cascadeRound < maxCascadeDepth; cascadeRound++) {
              if (acpCancellationToken?.isCancelled == true) break;

              // Reload history to capture the latest agent messages
              final cascadeHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

              // Find messages from recently-responded agents and parse structured dispatch
              final newMentionedIds = <String>{};
              final cascadeSteps = <DispatchStep>[];
              for (final msg in cascadeHistory.reversed) {
                if (!msg.from.isAgent) continue;
                if (!respondedAgentIds.contains(msg.from.id)) continue;
                final dispatch = _dispatchParser.parseStructuredDispatch(msg.content, nonAdminAgents);
                cascadeSteps.addAll(dispatch.steps);
                for (final mentionId in dispatch.steps.expand((s) => s.agentIds)) {
                  if (!respondedAgentIds.contains(mentionId) && mentionId != adminAgentId) {
                    newMentionedIds.add(mentionId);
                  }
                }
                // Strip the dispatch JSON block from the member's message
                if (dispatch.steps.isNotEmpty) {
                  await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, msg.from.id);
                }
              }

              if (newMentionedIds.isEmpty) break;

              LoggerService().debug('allMembers cascade round ${cascadeRound + 1}: dispatching ${newMentionedIds.length} newly-mentioned agents', tag: 'GroupOrchestrationService');

              // Dispatch newly-mentioned agents
              final cascadeFutures = <Future<void>>[];
              final cascadeHistoryForAgents = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
              for (final agent in agents) {
                if (!newMentionedIds.contains(agent.id)) continue;
                onAgentStart?.call(agent.id, agent.name);
                final isFirst = !agentIdsWithHistory.contains(agent.id);
                cascadeFutures.add(
                  _executor.processGroupAgent(
                    agent: agent,
                    channelId: channelId,
                    content: GroupDispatchParser.taskContentForAgent(
                      agentId: agent.id,
                      steps: cascadeSteps,
                      fallback: effectiveContent,
                    ),
                    attachments: attachments,
                    userId: userId,
                    userName: userName,
                    groupName: groupName,
                    groupDescription: groupDescription,
                    allAgents: agents,
                    historyMessages: cascadeHistoryForAgents,
                    mentionedAgentIds: newMentionedIds.toList(),
                    isFirstMessage: isFirst,
                    messageVersion: messageVersion,
                    channelMembers: channelMembers,
                    adminAgent: adminAgent,
                    customSystemPrompt: customSystemPrompt,
                    mentionMode: mentionMode,
                    acpCancellationToken: acpCancellationToken,
                    onStreamChunk: onStreamChunk,
                    onAgentDone: onAgentDone,
                    onInteractionRequest: onInteractionRequest,
                  ).catchError((e) {
                    LoggerService().error('Cascade agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
                    failedAgentNames.add(agent.name);
                    onAgentDone?.call(agent.id, agent.name, true);
                    return const GroupTurnResult();
                  }),
                );
              }
              await Future.wait(cascadeFutures);
              respondedAgentIds.addAll(newMentionedIds);
            }
          }

          // Check cancellation after member execution.
          // Even when cancelled, run one final abort-summarize so Admin can
          // summarise the work already done before the loop exits.
          if (acpCancellationToken?.isCancelled == true) {
            LoggerService().info('Loop orchestration cancelled after member execution at round $currentRound — running abort-summarize', tag: 'GroupOrchestrationService');
            final abortHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: effectiveContent,
                attachments: attachments,
                userId: userId,
                userName: userName,
                groupName: groupName,
                groupDescription: groupDescription,
                allAgents: agents,
                historyMessages: abortHistory,
                mentionedAgentIds: const [],
                isFirstMessage: false,
                isAdmin: true,
                isLoopSummarize: true,
                isAbortSummarize: true,
                loopRound: currentRound + 1,
                messageVersion: messageVersion,
                channelMembers: channelMembers,
                customSystemPrompt: customSystemPrompt,
                mentionMode: mentionMode,
                  failedAgentNames: List.unmodifiable(failedAgentNames),
                // Do NOT pass acpCancellationToken — this final summary must run to completion.
                onStreamChunk: (agentId, agentName, chunk) {
                  adminResponseContent += chunk;
                  onStreamChunk?.call(agentId, agentName, chunk);
                },
                onAgentDone: onAgentDone,
                onInteractionRequest: onInteractionRequestForAdmin,
                orchestrationTraceId: orchTraceId,
              );
            } catch (e) {
              LoggerService().error('Admin abort-summarize error', tag: 'GroupOrchestrationService', error: e);
              onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
            }
            // Hide the closing {"done": true} JSON block from the user.
            await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);
            break;
          }

          // Reload history (now includes member replies) and call admin again to summarize
          final loopHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

          adminResponseContent = '';
          onAgentStart?.call(adminAgent.id, adminAgent.name);
          try {
            adminTurn = await _executor.processGroupAgent(
              agent: adminAgent,
              channelId: channelId,
              content: lastDispatchNote != null
                  ? '$effectiveContent\n\n[SYSTEM] 你上一轮的派发记录（该 JSON 已从你的消息中隐藏，仅供核对）：$lastDispatchNote'
                  : effectiveContent,
              attachments: attachments,
              userId: userId,
              userName: userName,
              groupName: groupName,
              groupDescription: groupDescription,
              allAgents: agents,
              historyMessages: loopHistory,
              mentionedAgentIds: const [],
              isFirstMessage: false,
              isAdmin: true,
              isLoopSummarize: true,
              loopRound: currentRound + 1,
              messageVersion: messageVersion,
              channelMembers: channelMembers,
              customSystemPrompt: customSystemPrompt,
              mentionMode: mentionMode,
              failedAgentNames: List.unmodifiable(failedAgentNames),
              acpCancellationToken: acpCancellationToken,
              onStreamChunk: (agentId, agentName, chunk) {
                adminResponseContent += chunk;
                onStreamChunk?.call(agentId, agentName, chunk);
              },
              onAgentDone: onAgentDone,
              onInteractionRequest: onInteractionRequestForAdmin,
              orchestrationTraceId: orchTraceId,
            );
          } catch (e) {
            LoggerService().error('Admin summarize error at round $currentRound', tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(adminAgent.id, adminAgent.name, adminResponseContent.trim().isEmpty);
            break;
          }
          currentRound++;
          adminTurn = resolveAdminDecision(adminTurn);

        }

        await endOrchTrace(InferenceStatus.completed);
        onAllDone?.call();
        return;
      }
    }

    // 5c. No admin set, admin not found, or no @mentions — all agents respond
    if (effectiveMentionedAgentIds.isEmpty) {
      final futures = <Future<void>>[];
      for (final agent in agents) {
        onAgentStart?.call(agent.id, agent.name);
        final isFirstMessage = !agentIdsWithHistory.contains(agent.id);
        futures.add(
          _executor.processGroupAgent(
            agent: agent,
            channelId: channelId,
            content: effectiveContent,
            attachments: attachments,
            userId: userId,
            userName: userName,
            groupName: groupName,
            groupDescription: groupDescription,
            allAgents: agents,
            historyMessages: historyMessages,
            mentionedAgentIds: effectiveMentionedAgentIds,
            isFirstMessage: isFirstMessage,
            messageVersion: messageVersion,
            channelMembers: channelMembers,
            customSystemPrompt: customSystemPrompt,
            mentionMode: mentionMode,
            acpCancellationToken: acpCancellationToken,
            onStreamChunk: onStreamChunk,
            onAgentDone: onAgentDone,
            onInteractionRequest: onInteractionRequest,
            orchestrationTraceId: orchTraceId,
          ).catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(agent.id, agent.name, true);
            return const GroupTurnResult();
          }),
        );
      }
      await Future.wait(futures);
    }

    await endOrchTrace(InferenceStatus.completed);
    onAllDone?.call();
  }

  /// Create a workflow execution from a [FlowPlan] and surface plan approval UI.
  Future<bool> _offerWorkflowFromPlan({
    required String channelId,
    required RemoteAgent adminAgent,
    required FlowPlan flowPlan,
    required String triggerMessageId,
    void Function(String? workflowId)? onActiveWorkflowChanged,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    if (flowPlan.stages.isEmpty ||
        flowPlan.stages.every((s) => s.steps.isEmpty)) {
      return false;
    }

    try {
      final execution = await _workflowService.createWorkflowExecution(
        channelId: channelId,
        title: flowPlan.title.isNotEmpty ? flowPlan.title : '群聊工作流',
        flowPlan: flowPlan,
        triggerMessage: triggerMessageId,
      );

      onActiveWorkflowChanged?.call(execution.id);

      final planData = flowPlan.toExecutionPlan().toJson();
      final adminMsgId = await _lastAgentMessageId(channelId, adminAgent.id);

      if (onInteractionRequest != null) {
        await onInteractionRequest(
          adminAgent.id,
          adminAgent.name,
          'plan_approval',
          {
            ...planData,
            '_workflowId': execution.id,
            '_non_blocking': true,
            if (adminMsgId != null) '_savedMessageId': adminMsgId,
          },
        );
      }

      LoggerService().info(
        'Created workflow ${execution.id} from group task dispatch (${execution.steps.length} steps)',
        tag: 'GroupOrchestrationService',
      );
      return true;
    } catch (e, st) {
      LoggerService().error(
        'Failed to create workflow from task dispatch',
        tag: 'GroupOrchestrationService',
        error: e,
        stackTrace: st,
      );
      try {
        final hintMsg = Message(
          id: _uuid.v4(),
          content: '⚠️ 工作流创建失败，未能启动任务分派。请重试或让管理员重新输出 dispatch JSON。',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: 'system', type: 'system', name: 'System'),
          type: MessageType.system,
        );
        await _db.createMessage(
          id: hintMsg.id,
          channelId: channelId,
          senderId: 'system',
          senderType: 'system',
          senderName: 'System',
          content: hintMsg.content,
          messageType: 'system',
        );
        await _db.markMessageAsRead(hintMsg.id);
        notifyChannelUpdate(channelId);
      } catch (_) {}
      return false;
    }
  }

  Future<String?> _lastAgentMessageId(String channelId, String agentId) async {
    try {
      final messages = await _db.getChannelMessages(channelId, limit: 20);
      for (final m in messages) {
        if (m['sender_id'] == agentId) {
          return m['id'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }
}
