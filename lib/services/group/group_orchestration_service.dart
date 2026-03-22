import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../models/channel.dart';
import '../../models/planning_models.dart';
import '../../models/inference_log_entry.dart';
import '../../models/model_routing_config.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../trace_service.dart';
import '../flow_executor.dart';
import '../acp_agent_connection.dart';
import 'group_dispatch_parser.dart';
import 'group_agent_executor.dart';
import 'group_prompt_builder.dart';
import 'planning_helpers.dart';

class GroupOrchestrationService {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final GroupAgentExecutor _executor;
  final GroupDispatchParser _dispatchParser;
  final PlanningHelpers _planningHelpers;
  final void Function(String channelId) notifyChannelUpdate;
  final Future<List<Message>> Function(String channelId, {int limit, String? excludeMessageId}) loadAndTruncateHistory;
  final Future<Map<String, dynamic>?> Function({
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> planData,
    required String messageId,
  }) awaitPlanApproval;
  final Map<String, FlowExecutor> activeFlowExecutors;
  final Future<List<Message>> Function(String channelId, {int limit}) loadChannelMessages;
  final Future<Message?> Function(String messageId) getMessageById;

  GroupOrchestrationService({
    required LocalDatabaseService db,
    required Uuid uuid,
    required GroupAgentExecutor executor,
    required GroupDispatchParser dispatchParser,
    required PlanningHelpers planningHelpers,
    required this.notifyChannelUpdate,
    required this.loadAndTruncateHistory,
    required this.awaitPlanApproval,
    required this.activeFlowExecutors,
    required this.loadChannelMessages,
    required this.getMessageById,
  })  : _db = db,
        _uuid = uuid,
        _executor = executor,
        _dispatchParser = dispatchParser,
        _planningHelpers = planningHelpers;

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
    bool planningMode = false,
    bool flowMode = false,
    Map<String, dynamic>? userMessageMetadata,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)? onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
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

    // Truncate oldest messages if total history exceeds the character budget.
    // This prevents context overflow in long group conversations.
    const maxHistoryChars = 60000;
    int totalChars = historyMessages.fold(0, (sum, m) => sum + m.content.length);
    while (totalChars > maxHistoryChars && historyMessages.isNotEmpty) {
      totalChars -= historyMessages.first.content.length;
      historyMessages.removeAt(0);
    }

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

    // 5. Route to the appropriate flow based on admin setting and @mentions
    LoggerService().debug('Routing: mentions=${mentionedAgentIds.length}, admin=$adminAgentId, agents=${agents.map((a) => a.name).toList()}', tag: 'GroupOrchestrationService');

    // Begin orchestration-level trace when admin is present (path 5b)
    String? orchTraceId;
    if (adminAgentId != null) {
      final adminAgent = agents.where((a) => a.id == adminAgentId).firstOrNull;
      if (adminAgent != null) {
        orchTraceId = TraceService.instance.beginGroupOrchestration(
          channelId: channelId,
          adminAgentId: adminAgentId,
          adminAgentName: adminAgent.name,
          userMessage: content,
          memberAgentIds: agentIds,
          planningMode: planningMode,
          flowMode: flowMode,
        );
      }
    }

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
          ).catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(agent.id, agent.name, true);
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
          for (final msg in cascadeHistory.reversed) {
            if (!msg.from.isAgent) continue;
            if (!respondedAgentIds.contains(msg.from.id)) continue;
            final dispatch = _dispatchParser.parseStructuredDispatch(msg.content, nonAdminAgentsForCascade);
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
                content: effectiveContent,
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
              ).catchError((e) {
                LoggerService().error('Cascade agent (5a) ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
                onAgentDone?.call(agent.id, agent.name, true);
              }),
            );
          }
          await Future.wait(cascadeFutures);
          respondedAgentIds.addAll(newMentionedIds);
        }
      }
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
          bool planningMode = false,
          ExecutionPlan? approvedPlan,
          bool isPlanRevise = false,
          List<String> failedAgentNames = const [],
          bool isFlowMode = false,
          bool isFlowStageReview = false,
          int? flowStageIndex,
        }) => _executor.processGroupAgent(
          agent: agent,
          channelId: channelId,
          content: effectiveContent,
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
          planningMode: planningMode,
          approvedPlan: approvedPlan,
          isPlanRevise: isPlanRevise,
          failedAgentNames: failedAgentNames,
          acpCancellationToken: acpCancellationToken,
          isFlowMode: isFlowMode,
          isFlowStageReview: isFlowStageReview,
          flowStageIndex: flowStageIndex,
          onStreamChunk: onStreamChunk,
          onAgentDone: onAgentDone,
          onInteractionRequest: onInteractionRequest,
          orchestrationTraceId: orchTraceId,
        );

        // Helper to end orchestration trace on any exit path
        Future<void> endOrchTrace(InferenceStatus status) async {
          if (orchTraceId != null) {
            await TraceService.instance.endTrace(orchTraceId!, status);
            orchTraceId = null;
          }
        }

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

        // 1. First admin call
        onAgentStart?.call(adminAgent.id, adminAgent.name);
        final isFirstMessage = !agentIdsWithHistory.contains(adminAgent.id);
        adminResponseContent = '';
        try {
          await _executor.processGroupAgent(
            agent: adminAgent,
            channelId: channelId,
            content: effectiveContent,
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
            planningMode: planningMode || flowMode,
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

        // ── Flow 模式：检测 [FLOW_PLAN] 块 ──
        if (flowMode) {
          final flowPlan = FlowPlan.tryParse(adminResponseContent);
          if (flowPlan != null) {
            // Strip [FLOW_PLAN] JSON from saved Admin message; keep natural language
            final adminMsgId = await _planningHelpers.stripFlowPlanBlockFromLastMessage(channelId, adminAgent.id);

            // Reuse plan_approval interaction for user approval
            final flowPlanApprovalData = {
              ...flowPlan.toExecutionPlan().toJson(),
              if (adminMsgId != null) '_savedMessageId': adminMsgId,
            };
            // Notify UI to show the plan_approval card (non-blocking, just for display)
            await onInteractionRequest?.call(
              adminAgent.id, adminAgent.name, 'plan_approval',
              {...flowPlanApprovalData, '_non_blocking': true},
            );
            // Block here via ChatService-owned Completer so it survives channel switch
            final approvalResult = await awaitPlanApproval(
              channelId: channelId,
              agentId: adminAgent.id,
              agentName: adminAgent.name,
              planData: flowPlanApprovalData,
              messageId: adminMsgId ?? '',
            );

            if (approvalResult == null || approvalResult['approved'] != true) {
              await endOrchTrace(InferenceStatus.cancelled);
              onAllDone?.call();
              return;
            }

            // Apply any user-skipped steps from approval
            final skippedIds = ((approvalResult['skipped_task_ids'] as List?)
                    ?.map((e) => e.toString())
                    .toSet()) ??
                <String>{};
            if (skippedIds.isNotEmpty) {
              flowPlan.applySkippedStepIds(skippedIds);
            }

            // Create task board message for UI
            final flowTaskBoardMsgId = _uuid.v4();
            final initialPlan = flowPlan.toExecutionPlan();
            await _planningHelpers.createTaskBoardMessage(channelId, flowTaskBoardMsgId, initialPlan);
            notifyChannelUpdate(channelId);
            await onInteractionRequest?.call(
              adminAgent.id, adminAgent.name, 'task_board_update',
              {'_taskBoardMessageId': flowTaskBoardMsgId, 'plan': initialPlan.toJson()},
            );

            // Build context and run FlowExecutor
            final flowCtx = FlowExecutorContext(
              channelId: channelId,
              originalUserContent: effectiveContent,
              userId: userId,
              userName: userName,
              groupName: groupName,
              groupDescription: groupDescription,
              allAgents: agents,
              adminAgent: adminAgent,
              channelMembers: channelMembers,
              customSystemPrompt: customSystemPrompt,
              mentionMode: mentionMode,
              messageVersion: messageVersion,
              userMessageId: userMessage.id,
              taskBoardMsgId: flowTaskBoardMsgId,
              acpCancellationToken: acpCancellationToken,
            );

            final executor = FlowExecutor(
              plan: flowPlan,
              ctx: flowCtx,
              processGroupAgent: ({
                required RemoteAgent agent,
                required String channelId,
                required String content,
                required String userId,
                required String userName,
                required String groupName,
                required String groupDescription,
                required List<RemoteAgent> allAgents,
                required List<dynamic> historyMessages,
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
                bool planningMode = false,
                ExecutionPlan? approvedPlan,
                bool isPlanRevise = false,
                List<String> failedAgentNames = const [],
                ACPCancellationToken? acpCancellationToken,
                void Function(String, String, String)? onStreamChunk,
                void Function(String, String, bool)? onAgentDone,
                Future<Map<String, dynamic>?> Function(String, String, String, Map<String, dynamic>)? onInteractionRequest,
                bool isFlowStageReview = false,
                int? flowStageIndex,
              }) =>
                  _executor.processGroupAgent(
                    agent: agent,
                    channelId: channelId,
                    content: content,
                    userId: userId,
                    userName: userName,
                    groupName: groupName,
                    groupDescription: groupDescription,
                    allAgents: allAgents,
                    historyMessages: historyMessages.cast<Message>(),
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
                    planningMode: planningMode,
                    approvedPlan: approvedPlan,
                    isPlanRevise: isPlanRevise,
                    failedAgentNames: failedAgentNames,
                    acpCancellationToken: acpCancellationToken,
                    onStreamChunk: onStreamChunk,
                    onAgentDone: onAgentDone,
                    onInteractionRequest: onInteractionRequest,
                    isFlowStageReview: isFlowStageReview,
                    flowStageIndex: flowStageIndex,
                  ),
              loadHistory: (channelId, {String? excludeMessageId}) =>
                  loadAndTruncateHistory(channelId, excludeMessageId: excludeMessageId)
                      .then((list) => list as List<dynamic>),
              updateTaskBoard: (channelId, msgId, plan) =>
                  _planningHelpers.updateTaskBoardMessage(channelId, msgId, plan),
              createSystemMessage: (channelId, content) async {
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
              },
              notifyTaskBoard: (agentId, agentName, msgId, plan) =>
                  onInteractionRequest?.call(
                    agentId, agentName, 'task_board_update',
                    {'_taskBoardMessageId': msgId, 'plan': plan.toJson()},
                  ).then((_) {}) ?? Future.value(),
              onAgentStart: onAgentStart,
              onAgentDone: onAgentDone,
              onStreamChunk: onStreamChunk,
              onInteractionRequest: onInteractionRequest,
            );

            activeFlowExecutors[channelId] = executor;
            try {
              await executor.execute();
            } finally {
              activeFlowExecutors.remove(channelId);
            }
            await endOrchTrace(InferenceStatus.completed);
            onAllDone?.call();
            return;
          } else {
            // flowMode but Admin did not produce a [FLOW_PLAN] block.
            // This can happen when the LLM outputs a short text fragment then emits
            // a tool call (e.g. message_metadata) which truncates the text stream
            // before the [FLOW_PLAN] block is written.  Retry up to 2 times.
            const maxFlowPlanRetries = 2;
            int flowPlanRetry = 0;
            FlowPlan? retryFlowPlan;
            while (flowPlanRetry < maxFlowPlanRetries && retryFlowPlan == null) {
              flowPlanRetry++;
              LoggerService().info(
                'flowMode: Admin response contained no [FLOW_PLAN] (retry $flowPlanRetry/$maxFlowPlanRetries)',
                tag: 'GroupOrchestrationService',
              );
              final retryHistory = await loadAndTruncateHistory(
                channelId, excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: effectiveContent,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: retryHistory,
                  mentionedAgentIds: const [],
                  isFirstMessage: false,
                  isAdmin: true,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                  planningMode: true,
                  isFlowMode: true,
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
                LoggerService().error(
                  'flowMode: Admin retry $flowPlanRetry error',
                  tag: 'GroupOrchestrationService', error: e,
                );
                break;
              }
              retryFlowPlan = FlowPlan.tryParse(adminResponseContent);
            }

            if (retryFlowPlan == null) {
              // All retries exhausted without a valid [FLOW_PLAN].
              LoggerService().info(
                'flowMode: Admin failed to produce [FLOW_PLAN] after $flowPlanRetry retries, ending',
                tag: 'GroupOrchestrationService',
              );
              onAllDone?.call();
              return;
            }

            // Got a valid plan on retry — continue with approval flow.
            final adminMsgId = await _planningHelpers.stripFlowPlanBlockFromLastMessage(channelId, adminAgent.id);
            final flowPlanApprovalData = {
              ...retryFlowPlan.toExecutionPlan().toJson(),
              if (adminMsgId != null) '_savedMessageId': adminMsgId,
            };
            // Notify UI to show the plan_approval card (non-blocking, just for display)
            await onInteractionRequest?.call(
              adminAgent.id, adminAgent.name, 'plan_approval',
              {...flowPlanApprovalData, '_non_blocking': true},
            );
            // Block here via ChatService-owned Completer so it survives channel switch
            final approvalResult = await awaitPlanApproval(
              channelId: channelId,
              agentId: adminAgent.id,
              agentName: adminAgent.name,
              planData: flowPlanApprovalData,
              messageId: adminMsgId ?? '',
            );

            if (approvalResult == null || approvalResult['approved'] != true) {
              await endOrchTrace(InferenceStatus.cancelled);
              onAllDone?.call();
              return;
            }

            final skippedIds = ((approvalResult['skipped_task_ids'] as List?)
                    ?.map((e) => e.toString())
                    .toSet()) ??
                <String>{};
            if (skippedIds.isNotEmpty) {
              retryFlowPlan.applySkippedStepIds(skippedIds);
            }

            final flowTaskBoardMsgId2 = _uuid.v4();
            final initialPlan2 = retryFlowPlan.toExecutionPlan();
            await _planningHelpers.createTaskBoardMessage(channelId, flowTaskBoardMsgId2, initialPlan2);
            notifyChannelUpdate(channelId);
            await onInteractionRequest?.call(
              adminAgent.id, adminAgent.name, 'task_board_update',
              {'_taskBoardMessageId': flowTaskBoardMsgId2, 'plan': initialPlan2.toJson()},
            );

            final flowCtx2 = FlowExecutorContext(
              channelId: channelId,
              originalUserContent: effectiveContent,
              userId: userId,
              userName: userName,
              groupName: groupName,
              groupDescription: groupDescription,
              allAgents: agents,
              adminAgent: adminAgent,
              channelMembers: channelMembers,
              customSystemPrompt: customSystemPrompt,
              mentionMode: mentionMode,
              messageVersion: messageVersion,
              userMessageId: userMessage.id,
              taskBoardMsgId: flowTaskBoardMsgId2,
              acpCancellationToken: acpCancellationToken,
            );

            final executor2 = FlowExecutor(
              plan: retryFlowPlan,
              ctx: flowCtx2,
              processGroupAgent: ({
                required RemoteAgent agent,
                required String channelId,
                required String content,
                required String userId,
                required String userName,
                required String groupName,
                required String groupDescription,
                required List<RemoteAgent> allAgents,
                required List<dynamic> historyMessages,
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
                bool planningMode = false,
                ExecutionPlan? approvedPlan,
                bool isPlanRevise = false,
                List<String> failedAgentNames = const [],
                ACPCancellationToken? acpCancellationToken,
                void Function(String, String, String)? onStreamChunk,
                void Function(String, String, bool)? onAgentDone,
                Future<Map<String, dynamic>?> Function(String, String, String, Map<String, dynamic>)? onInteractionRequest,
                bool isFlowStageReview = false,
                int? flowStageIndex,
              }) =>
                  _executor.processGroupAgent(
                    agent: agent,
                    channelId: channelId,
                    content: content,
                    userId: userId,
                    userName: userName,
                    groupName: groupName,
                    groupDescription: groupDescription,
                    allAgents: allAgents,
                    historyMessages: historyMessages.cast<Message>(),
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
                    planningMode: planningMode,
                    approvedPlan: approvedPlan,
                    isPlanRevise: isPlanRevise,
                    failedAgentNames: failedAgentNames,
                    acpCancellationToken: acpCancellationToken,
                    onStreamChunk: onStreamChunk,
                    onAgentDone: onAgentDone,
                    onInteractionRequest: onInteractionRequest,
                    isFlowMode: true,
                    isFlowStageReview: isFlowStageReview,
                    flowStageIndex: flowStageIndex,
                    orchestrationTraceId: orchTraceId,
                  ),
              loadHistory: (channelId, {String? excludeMessageId}) =>
                  loadAndTruncateHistory(channelId, excludeMessageId: excludeMessageId)
                      .then((list) => list as List<dynamic>),
              updateTaskBoard: (channelId, msgId, plan) =>
                  _planningHelpers.updateTaskBoardMessage(channelId, msgId, plan),
              createSystemMessage: (channelId, content) async {
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
              },
              notifyTaskBoard: (agentId, agentName, msgId, plan) =>
                  onInteractionRequest?.call(
                    agentId, agentName, 'task_board_update',
                    {'_taskBoardMessageId': msgId, 'plan': plan.toJson()},
                  ).then((_) {}) ?? Future.value(),
              onAgentStart: onAgentStart,
              onAgentDone: onAgentDone,
              onStreamChunk: onStreamChunk,
              onInteractionRequest: onInteractionRequest,
            );

            activeFlowExecutors[channelId] = executor2;
            try {
              await executor2.execute();
            } finally {
              activeFlowExecutors.remove(channelId);
            }
            await endOrchTrace(InferenceStatus.completed);
            onAllDone?.call();
            return;
          }
        }

        // ── 计划模式：检测 [PLAN] 块（flowMode 开启时跳过，避免冲突）──
        ExecutionPlan? activePlan;
        String? taskBoardMsgId;
        if (planningMode && !flowMode) {
          // Loop to handle repeated plan revisions until the user approves or cancels
          ExecutionPlan? currentPlan = ExecutionPlan.tryParse(adminResponseContent);
          Map<String, dynamic>? approvalResult;
          while (currentPlan != null) {
            // Strip [PLAN] JSON from the saved Admin message; keep natural language summary
            final adminMsgId = await _planningHelpers.stripPlanBlockFromLastMessage(channelId, adminAgent.id);

            // Pause and wait for user approval via the interaction callback
            final planApprovalData = {
              ...currentPlan.toJson(),
              if (adminMsgId != null) '_savedMessageId': adminMsgId,
            };
            // Notify UI to show the plan_approval card (non-blocking, just for display)
            await onInteractionRequest?.call(
              adminAgent.id, adminAgent.name, 'plan_approval',
              {...planApprovalData, '_non_blocking': true},
            );
            // Block here via ChatService-owned Completer so it survives channel switch
            approvalResult = await awaitPlanApproval(
              channelId: channelId,
              agentId: adminAgent.id,
              agentName: adminAgent.name,
              planData: planApprovalData,
              messageId: adminMsgId ?? '',
            );

            if (approvalResult != null && approvalResult['approved'] == true) {
              // User approved — break out to proceed with execution
              break;
            }

            // User rejected or timed out
            final feedback = approvalResult?['feedback'] as String?;
            if (feedback != null && feedback.isNotEmpty) {
              // Inject feedback as system context and re-invoke Admin with revision
              LoggerService().info('Plan revision requested, feedback length=${feedback.length}', tag: 'GroupOrchestrationService');
              await _planningHelpers.injectPlanReviseContext(
                channelId, userId, userName, feedback, adminAgent);
              final reviseHistory = await loadAndTruncateHistory(
                channelId, excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: effectiveContent,
                  userId: userId,
                  userName: userName,
                  groupName: groupName,
                  groupDescription: groupDescription,
                  allAgents: agents,
                  historyMessages: reviseHistory,
                  mentionedAgentIds: const [],
                  isFirstMessage: false,
                  isAdmin: true,
                  messageVersion: messageVersion,
                  channelMembers: channelMembers,
                  customSystemPrompt: customSystemPrompt,
                  mentionMode: mentionMode,
                  planningMode: true,
                  isPlanRevise: true,
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
                LoggerService().error('Admin plan-revise error', tag: 'GroupOrchestrationService', error: e);
                await endOrchTrace(InferenceStatus.error);
                onAllDone?.call();
                return;
              }
              // Parse the revised plan and loop back to show the new plan_approval card.
              // If Admin failed to produce a valid [PLAN] block, keep the old plan so
              // the user can try again or approve the original.
              LoggerService().info('Plan revise done, adminResponseContent length=${adminResponseContent.length}, hasPlan=${adminResponseContent.contains("[PLAN]")}', tag: 'GroupOrchestrationService');
              final revisedPlan = ExecutionPlan.tryParse(adminResponseContent);
              if (revisedPlan != null) {
                currentPlan = revisedPlan;
              } else {
                LoggerService().warning(
                  'Admin did not produce a valid [PLAN] block after revision; re-showing current plan',
                  tag: 'GroupOrchestrationService',
                );
                // currentPlan stays unchanged; the while loop will show the card again
              }
            } else {
              // No feedback provided — user cancelled without input
              await endOrchTrace(InferenceStatus.cancelled);
              onAllDone?.call();
              return;
            }
          }

          if (currentPlan == null || approvalResult == null || approvalResult['approved'] != true) {
            await endOrchTrace(InferenceStatus.cancelled);
            onAllDone?.call();
            return;
          }

          activePlan = _planningHelpers.applyUserModifications(currentPlan, approvalResult);

          // Inject the approved plan as a system context message visible to Admin
          await _planningHelpers.injectApprovedPlanContext(channelId, activePlan!, adminAgent);

          // Create the live task board system message in the chat
          taskBoardMsgId = _uuid.v4();
          await _planningHelpers.createTaskBoardMessage(channelId, taskBoardMsgId!, activePlan!);
          notifyChannelUpdate(channelId);
          await onInteractionRequest?.call(
            adminAgent.id, adminAgent.name, 'task_board_update',
            {'_taskBoardMessageId': taskBoardMsgId, 'plan': activePlan!.toJson()},
          );

          // ── Re-invoke Admin with execution-phase prompt to kick off delegation ──
          // The planning-phase response has no @mentions, so without this the
          // while-loop would exit immediately.
          final execHistory = await loadAndTruncateHistory(
              channelId, excludeMessageId: userMessage.id);
          adminResponseContent = '';
          onAgentStart?.call(adminAgent.id, adminAgent.name);
          try {
            await _executor.processGroupAgent(
              agent: adminAgent,
              channelId: channelId,
              content: effectiveContent,
              userId: userId,
              userName: userName,
              groupName: groupName,
              groupDescription: groupDescription,
              allAgents: agents,
              historyMessages: execHistory,
              mentionedAgentIds: const [],
              isFirstMessage: false,
              isAdmin: true,
              isLoopSummarize: false,
              messageVersion: messageVersion,
              channelMembers: channelMembers,
              customSystemPrompt: customSystemPrompt,
              mentionMode: mentionMode,
              planningMode: planningMode,
              approvedPlan: activePlan,
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
            LoggerService().error(
                'Admin execution-start error after plan approval',
                tag: 'GroupOrchestrationService',
                error: e);
            onAgentDone?.call(adminAgent.id, adminAgent.name,
                adminResponseContent.trim().isEmpty);
          }
          currentRound++;

          // Parse any immediate task status markers from execution-start response
          {
            final updates = _planningHelpers.parseTaskStatusUpdates(adminResponseContent);
            if (updates.isNotEmpty) {
              for (final entry in updates.entries) {
                final task =
                    activePlan.tasks.where((t) => t.id == entry.key).firstOrNull;
                if (task != null) task.status = entry.value;
              }
              await _planningHelpers.updateTaskBoardMessage(channelId, taskBoardMsgId, activePlan);
              await onInteractionRequest?.call(
                adminAgent.id, adminAgent.name, 'task_board_update',
                {'_taskBoardMessageId': taskBoardMsgId, 'plan': activePlan.toJson()},
              );
            }
          }
        }

        // 2. Loop: parse dispatch JSON → delegate → admin summarize → repeat
        final failedAgentNames = <String>[];
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
                  planningMode: planningMode,
                  approvedPlan: activePlan,
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
                planningMode: planningMode,
                approvedPlan: activePlan,
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
            break;
          }

          // Parse structured JSON dispatch from admin's response
          final dispatch = _dispatchParser.parseStructuredDispatch(adminResponseContent, nonAdminAgents);
          final adminWantsContinue = dispatch.wantsContinue;
          final delegatedIds = dispatch.steps
              .expand((s) => s.agentIds)
              .toSet()
              .toList();

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
            // No dispatch and no continue — orchestration complete
            LoggerService().debug('Loop orchestration ended: no dispatch at round $currentRound', tag: 'GroupOrchestrationService');
            break;
          }

          // ── Planning mode: mark tasks inProgress when Admin delegates ──
          if (activePlan != null && taskBoardMsgId != null && delegatedIds.isNotEmpty) {
            final plan = activePlan;
            final tbId = taskBoardMsgId;
            bool anyChanged = false;
            for (final agentId in delegatedIds) {
              final agent = agents.firstWhere((a) => a.id == agentId,
                  orElse: () => agents.first);
              for (final task in plan.tasks) {
                if (task.status == TaskStatus.pending &&
                    task.assignee.toLowerCase() == agent.name.toLowerCase()) {
                  task.status = TaskStatus.inProgress;
                  anyChanged = true;
                }
              }
            }
            if (anyChanged) {
              await _planningHelpers.updateTaskBoardMessage(channelId, tbId, plan);
              await onInteractionRequest?.call(
                adminAgent.id, adminAgent.name, 'task_board_update',
                {'_taskBoardMessageId': tbId, 'plan': plan.toJson()},
              );
            }
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
                  planningMode: planningMode,
                  approvedPlan: activePlan,
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
              await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: effectiveContent,
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
                planningMode: planningMode,
                approvedPlan: activePlan,
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

            // Guard against empty responses to prevent stuck loops
            if (adminResponseContent.trim().isEmpty) {
              LoggerService().warning('Admin continue produced empty response at round $currentRound, stopping', tag: 'GroupOrchestrationService');
              break;
            }
            continue;
          }

          // Strip dispatch JSON from saved message before delegating
          await _dispatchParser.stripDispatchJsonFromLastMessage(channelId, adminAgent.id);

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
                    content: effectiveContent,
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
                  }),
                );
              }
              await Future.wait(stepFutures);

              // ── Planning mode: mark step tasks done by assignee completion ──
              if (activePlan != null && taskBoardMsgId != null) {
                final plan = activePlan;
                final tbId = taskBoardMsgId;
                bool anyChanged = false;
                for (final agentId in stepAgentIds) {
                  final agent = agents.firstWhere((a) => a.id == agentId,
                      orElse: () => agents.first);
                  for (final task in plan.tasks) {
                    if (task.status == TaskStatus.inProgress &&
                        task.assignee.toLowerCase() == agent.name.toLowerCase()) {
                      task.status = TaskStatus.done;
                      anyChanged = true;
                    }
                  }
                }
                if (anyChanged) {
                  await _planningHelpers.updateTaskBoardMessage(channelId, tbId, plan);
                  await onInteractionRequest?.call(
                    adminAgent.id, adminAgent.name, 'task_board_update',
                    {'_taskBoardMessageId': tbId, 'plan': plan.toJson()},
                  );
                }
              }
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
                  content: effectiveContent,
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
                }),
              );
            }
            await Future.wait(delegatedFutures);
          }

          // ── Planning mode: mark tasks done by assignee completion ──
          if (activePlan != null && taskBoardMsgId != null) {
            final plan = activePlan;
            final tbId = taskBoardMsgId;
            bool anyChanged = false;
            for (final agentId in delegatedIds) {
              final agent = agents.firstWhere((a) => a.id == agentId,
                  orElse: () => agents.first);
              for (final task in plan.tasks) {
                if (task.status == TaskStatus.inProgress &&
                    task.assignee.toLowerCase() == agent.name.toLowerCase()) {
                  task.status = TaskStatus.done;
                  anyChanged = true;
                }
              }
            }
            if (anyChanged) {
              await _planningHelpers.updateTaskBoardMessage(channelId, tbId, plan);
              await onInteractionRequest?.call(
                adminAgent.id, adminAgent.name, 'task_board_update',
                {'_taskBoardMessageId': tbId, 'plan': plan.toJson()},
              );
            }
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
              for (final msg in cascadeHistory.reversed) {
                if (!msg.from.isAgent) continue;
                if (!respondedAgentIds.contains(msg.from.id)) continue;
                final dispatch = _dispatchParser.parseStructuredDispatch(msg.content, nonAdminAgents);
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
                    content: effectiveContent,
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
                    onAgentDone?.call(agent.id, agent.name, true);
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
                planningMode: planningMode,
                approvedPlan: activePlan,
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
            break;
          }

          // Reload history (now includes member replies) and call admin again to summarize
          final loopHistory = await loadAndTruncateHistory(channelId, excludeMessageId: userMessage.id);

          adminResponseContent = '';
          onAgentStart?.call(adminAgent.id, adminAgent.name);
          try {
            await _executor.processGroupAgent(
              agent: adminAgent,
              channelId: channelId,
              content: effectiveContent,
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
              planningMode: planningMode,
              approvedPlan: activePlan,
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

          // Update task board if planning mode is active
          if (activePlan != null && taskBoardMsgId != null) {
            final plan = activePlan;
            final tbId = taskBoardMsgId;
            final updates = _planningHelpers.parseTaskStatusUpdates(adminResponseContent);
            if (updates.isNotEmpty) {
              for (final entry in updates.entries) {
                final task = plan.tasks
                    .where((t) => t.id == entry.key)
                    .firstOrNull;
                if (task != null) task.status = entry.value;
              }
              await _planningHelpers.updateTaskBoardMessage(channelId, tbId, plan);
              await onInteractionRequest?.call(
                adminAgent.id, adminAgent.name, 'task_board_update',
                {'_taskBoardMessageId': tbId, 'plan': plan.toJson()},
              );
            }
          }
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
          ).catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error', tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(agent.id, agent.name, true);
          }),
        );
      }
      await Future.wait(futures);
    }

    onAllDone?.call();
  }
}
