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
import 'group_event.dart';
import 'group_prompt_builder.dart';
import 'group_member_session_service.dart';
import 'group_turn_result.dart';
import 'planning_helpers.dart';
import '../../models/mention_entry.dart';
import '../../storage/context_bundle.dart';
import '../../storage/group_workspace_service.dart';
import 'group_orchestration_tools.dart';

class GroupOrchestrationService {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final GroupAgentExecutor _executor;
  final GroupDispatchParser _dispatchParser;
  final PlanningHelpers _planningHelpers;
  final WorkflowService _workflowService;
  final void Function(String channelId) notifyChannelUpdate;
  final Future<List<Message>> Function(String channelId,
      {int limit, String? excludeMessageId}) loadAndTruncateHistory;
  final Future<Map<String, dynamic>?> Function({
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> planData,
    required String messageId,
  }) awaitPlanApproval;
  final Future<List<Message>> Function(String channelId, {int limit})
      loadChannelMessages;
  final Future<Message?> Function(String messageId) getMessageById;

  /// 群工作空间编排落盘回调（kind: round_start / dispatch_decision /
  /// members_done / round_complete / finish）。null 时为空操作，不破坏
  /// 现有调用方与测试。
  final Future<void> Function({
    required String channelId,
    required int round,
    required String kind,
    required Map<String, dynamic> payload,
  })? onOrchestrationRound;

  /// M5 群事件记录：每轮编排完成后发一个 `loopRoundCompleted` 被动事件。
  /// null 时为空操作（不破坏现有调用方/测试）。
  final void Function(GroupEvent event)? onGroupEvent;

  /// M5 上一轮事件感知行：为下一轮成员返回要注入的【上轮事件】文本行。
  /// null 或空列表时不注入。以 channelId 为参数以便按频道读取事件日志。
  final List<String> Function(String channelId, {String? orchestrationId})?
      loopEventLines;

  /// L1/L2 近期事件感知行：为 mention-direct / broadcast / cascade / 工作流与
  /// loop 的 admin 收尾等回合返回要注入的【近期事件】文本行。null 或空列表
  /// 时不注入。以 channelId 为参数以便按频道读取事件日志。
  final List<String> Function(String channelId)? eventDigestLines;

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
    this.onOrchestrationRound,
    this.onGroupEvent,
    this.loopEventLines,
    this.eventDigestLines,
  })  : _db = db,
        _uuid = uuid,
        _executor = executor,
        _dispatchParser = dispatchParser,
        _planningHelpers = planningHelpers,
        _workflowService = workflowService;

  /// 汇总 [loopEventLines]（若提供）为一条「上轮事件」文本块，供成员任务注入。
  ///
  /// [orchestrationId] 为本次编排的用户消息 id，传给回调以过滤「只取当前
  /// 会话」的轮次事件（M4：避免连续两次任务时注入上一任务的轮次结论）。
  String _buildLoopEventNote(String channelId, {String? orchestrationId}) {
    final lines =
        loopEventLines?.call(channelId, orchestrationId: orchestrationId) ??
            const <String>[];
    return lines.join('\n');
  }

  /// 汇总 [eventDigestLines]（若提供）为近期事件感知行（L1/L2）。供
  /// mention-direct / broadcast / cascade / admin 收尾等回合注入。
  List<String> _buildEventDigestLines(String channelId) =>
      eventDigestLines?.call(channelId) ?? const <String>[];

  /// 把近期事件块附加到 [content] 尾部；无事件行时原样返回，不注入空标签。
  String _withEventDigest(String content, String channelId) =>
      GroupDispatchParser.withEventDigestNote(
        content,
        _buildEventDigestLines(channelId),
      );

  /// Matches `store://<space>/<device>/<path>…` tokens in free text, stopping
  /// at whitespace / markdown closers / CJK punctuation.
  static final RegExp _storeUriPattern = RegExp(r'store://[^\s\]\[\)\},，;]+');

  /// Extract unique `store://…` artifact URIs referenced in a member reply.
  static List<String> extractStoreUris(String text) {
    final uris = <String>[];
    for (final m in _storeUriPattern.allMatches(text)) {
      var uri = m.group(0)!.trim();
      while (uri.isNotEmpty &&
          (uri.endsWith(')') ||
              uri.endsWith(']') ||
              uri.endsWith('}') ||
              uri.endsWith(',') ||
              uri.endsWith('，') ||
              uri.endsWith('。') ||
              uri.endsWith(';') ||
              uri.endsWith('.') ||
              uri.endsWith('：'))) {
        uri = uri.substring(0, uri.length - 1);
      }
      if (uri.isNotEmpty && !uris.contains(uri)) uris.add(uri);
    }
    return uris;
  }

  /// Build the 【成员产物】 block for the admin's summarize turn: each member's
  /// produced store:// links. Empty when no member referenced an artifact.
  static String buildMemberArtifactsBlock(
    Map<String, GroupTurnResult> results,
    List<RemoteAgent> agents,
  ) {
    final lines = <String>[];
    for (final entry in results.entries) {
      final agent = agents.where((a) => a.id == entry.key).firstOrNull;
      final name = agent?.name ?? entry.key;
      final uris = extractStoreUris(entry.value.content);
      if (uris.isEmpty) continue;
      lines.add('- $name: ${uris.join('  ')}');
    }
    if (lines.isEmpty) return '';
    return '\n\n【成员产物】本轮成员产出并引用的 store:// 链接（若成员未在回复中列出，可能未写文件）：\n'
        '${lines.join('\n')}';
  }

  /// Emit one orchestration state snapshot to the group workspace (best-effort;
  /// failures are logged, never fatal to the loop).
  Future<void> _emitOrchestrationRound({
    required String channelId,
    required int round,
    required String kind,
    required Map<String, dynamic> payload,
  }) async {
    final cb = onOrchestrationRound;
    if (cb == null) return;
    try {
      await cb(
        channelId: channelId,
        round: round,
        kind: kind,
        payload: payload,
      );
    } catch (e) {
      LoggerService().error(
        'orchestration round emit failed ($kind at round $round)',
        tag: 'GroupOrchestrationService',
        error: e,
      );
    }
  }

  /// Persist a user-visible system message in the group channel so
  /// orchestration-level failures are never silent in the chat.
  Future<void> _saveOrchestrationSystemMessage(
      String channelId, String content) async {
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
      LoggerService().error('Failed to save orchestration system message',
          tag: 'GroupOrchestrationService', error: e);
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
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName)? onAgentStart,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    void Function()? onAllDone,
    void Function(String? workflowId)? onActiveWorkflowChanged,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
  }) async {
    LoggerService().info(
        'sendMessageToGroup: $channelId, agents: $agentIds, admin: $adminAgentId',
        tag: 'GroupOrchestrationService');

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
      LoggerService().warning(
          'No valid agents found for group, agentIds=$agentIds',
          tag: 'GroupOrchestrationService');
      onAllDone?.call();
      return;
    }

    // 4. Load conversation history ONCE before all agents start (snapshot)
    // For first-time conversations (no prior agent messages), load more history.
    final allMessages = await loadChannelMessages(channelId, limit: 100);
    // Include all non-system messages (text + attachment summaries) so agents
    // have context about shared files/images without loading raw content.
    final eligibleMessages = allMessages
        .where((m) =>
            m.type != MessageType.system &&
            m.type != MessageType.permissionAudit)
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
    if (historyMessages.isNotEmpty &&
        historyMessages.last.id == userMessage.id) {
      historyMessages = historyMessages.sublist(0, historyMessages.length - 1);
    }

    // Per-agent context budget is applied in GroupAgentExecutor:
    // local agents use HistoryCompactor; peer/ACP use FIFO truncate.
    // Pass the full loaded snapshot so compaction still has material.

    // Build message version info for agent context sync
    final messageVersion = <String, dynamic>{
      'total_count': allMessages.length,
      'latest_message_id': allMessages.isNotEmpty ? allMessages.last.id : null,
      'latest_timestamp':
          allMessages.isNotEmpty ? allMessages.last.timestampMs : null,
    };

    // Resolve quoted message content so agents understand reply context
    String effectiveContent = content;
    if (replyToId != null) {
      final quotedMessage = await getMessageById(replyToId);
      if (quotedMessage != null) {
        effectiveContent =
            '[引用 ${quotedMessage.from.name} 的消息: "${quotedMessage.content}"]\n\n$content';
      }
    }
    // §6.3 + ContextBundle：群编排委派注入产物 URI + runtime 上下文清单
    final groupOwnerId = (channel?.parentGroupId?.isNotEmpty == true)
        ? channel!.parentGroupId!
        : channelId;

    // 外接 agent（group MCP 工具）编排决定的 inbox 读取基准：
    // 本轮开始时间 + 外接 agent 宿主 hub 设备（从 metadata workspace_uri
    // 解析；解析不到则跳过 inbox 读取，优雅降级为文本约定）。
    var roundStartTime = DateTime.now();
    String? groupHubDevice;
    for (final a in agents) {
      final ws = a.metadata['workspace_uri'] as String?;
      if (ws != null && ws.startsWith('store://workspaces/')) {
        final rest = ws.substring('store://workspaces/'.length);
        final device = rest.split('/').first.trim();
        if (device.isNotEmpty) {
          groupHubDevice = device;
          break;
        }
      }
    }

    /// 读取外接 agent 本轮内经 MCP 写入的编排决定（dispatch/finish）。
    ///
    /// 新鲜度基准：优先「最后消费时间」（latest.json 的 consumed_at，由
    /// dispatch_decision 落盘写入）——崩溃重启后，重启前写入但未消费的
    /// 决定仍会被消费；无消费记录时回退本轮开始时间。
    Future<OrchestrationInbox> _readRoundInbox() async {
      final hub = groupHubDevice;
      if (hub == null) return const OrchestrationInbox();
      try {
        DateTime since = roundStartTime;
        final latest =
            await GroupWorkspaceService.instance.readLatestOrchestration(
          groupId: groupOwnerId,
          sessionId: channelId,
        );
        final consumedAt = latest?['consumed_at'] as String?;
        if (consumedAt != null && consumedAt.isNotEmpty) {
          final parsed = DateTime.tryParse(consumedAt);
          if (parsed != null) since = parsed;
        }
        return await GroupWorkspaceService.instance.readOrchestrationInbox(
          groupId: groupOwnerId,
          sessionId: channelId,
          since: since,
          homeDevice: hub,
        );
      } catch (e) {
        LoggerService().debug(
          'orchestration inbox read failed: $e',
          tag: 'GroupOrchestrationService',
        );
        return const OrchestrationInbox();
      }
    }

    /// 读取外接 agent 本轮内经 MCP 声明的成员提及（视为 admin 声明）。
    Future<List<MentionEntry>> _readInboxMentions() async {
      final hub = groupHubDevice;
      if (hub == null) return const [];
      try {
        final inbox =
            await GroupWorkspaceService.instance.readOrchestrationInbox(
          groupId: groupOwnerId,
          sessionId: channelId,
          since: roundStartTime,
          homeDevice: hub,
        );
        final raw = inbox.mentions?['mentions'];
        if (raw is! List || raw.isEmpty) return const [];
        return GroupDispatchParser.resolveMentionDeclarations(
          [inbox.mentions!],
          agents,
        ).mentions;
      } catch (e) {
        LoggerService().debug(
          'orchestration inbox mentions read failed: $e',
          tag: 'GroupOrchestrationService',
        );
        return const [];
      }
    }

    effectiveContent =
        await ContextBundleService.instance.wrapWithContextBundle(
      effectiveContent,
      ownerId: groupOwnerId,
      channelId: channelId,
      isGroup: true,
    );

    // 群记忆主动注入：任务开始时把最新群记忆（shared/memory/latest.md，
    // 上一个任务的蒸馏总结）带进 admin 上下文，跨任务共享结论。
    final groupMemory =
        await GroupWorkspaceService.instance.readSharedMemoryLatest(
      groupOwnerId,
    );
    if (groupMemory != null) {
      effectiveContent = '$effectiveContent\n\n'
          '[群历史任务总结（shared/memory/latest.md）]\n$groupMemory';
    }
    // 被派发的成员也带截断版群历史总结（全文只在 admin 上下文；成员
    // 只需要要点，避免每个成员每轮膨胀 token）。
    final memberMemoryNote = groupMemory != null
        ? '\n\n[群历史任务总结（截断）]\n'
            '${groupMemory.length <= 600 ? groupMemory : '${groupMemory.substring(0, 600)}…'}'
        : '';

    // 5. Route to the appropriate flow based on admin setting and @mentions
    LoggerService().debug(
        'Routing: mentions=${mentionedAgentIds.length}, admin=$adminAgentId, agents=${agents.map((a) => a.name).toList()}',
        tag: 'GroupOrchestrationService');

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

    // allMembers member-to-member cascade: turns whose replies declare
    // mentions (structured `group_mention` tool args / reply metadata, or a
    // legacy JSON dispatch block) activate them, up to [maxCascadeDepth] extra
    // rounds. Driven entirely by the executor's unified mention capture — no
    // DB re-read, no JSON-in-chat syntax required. Unresolved mention names
    // surface as a system message instead of failing silently.
    const maxCascadeDepth = 3;
    final adminForCascade = adminAgentId != null
        ? agents.where((a) => a.id == adminAgentId).firstOrNull
        : null;
    Future<void> runMentionCascade({
      required Map<String, GroupTurnResult> initialTurns,
      required Set<String> respondedAgentIds,
      List<String>? failedAgentNames,
      List<MentionEntry> inboxMentions = const [],
      // M7: 收集所有 cascade 轮的成员回合（初始 + 每轮新激活），供 admin 汇总
      // 时把级联子任务产物也纳入【成员产物】块。不传则只保留原行为。
      Map<String, GroupTurnResult>? allTurnsCollector,
    }) async {
      var turns = Map<String, GroupTurnResult>.from(initialTurns);
      if (allTurnsCollector != null) allTurnsCollector.addAll(turns);
      // 外接 agent MCP 群工具声明的提及（视为 admin 的声明；admin 自身
      // 不会被激活）。挂成 admin 的虚拟 turn 复用现有 cascade 逻辑。
      if (inboxMentions.isNotEmpty && adminAgentId != null) {
        turns[adminAgentId] = GroupTurnResult(mentions: inboxMentions);
        respondedAgentIds = {...respondedAgentIds, adminAgentId};
        if (allTurnsCollector != null) {
          allTurnsCollector[adminAgentId] = turns[adminAgentId]!;
        }
      }
      for (int cascadeRound = 0;
          cascadeRound < maxCascadeDepth;
          cascadeRound++) {
        if (acpCancellationToken?.isCancelled == true) break;

        final newMentionedIds = <String>{};
        final cascadeSteps = <DispatchStep>[];
        final unresolvedHints = <String>[];
        for (final entry in turns.entries) {
          final aid = entry.key;
          final turn = entry.value;
          if (!respondedAgentIds.contains(aid)) continue;
          cascadeSteps.addAll(turn.steps);
          for (final m in turn.mentions) {
            if (!m.notify) continue;
            // Admin is never activated by a member; already-responded agents
            // (including the mentioner itself) are skipped to prevent loops.
            if (m.id == adminAgentId || respondedAgentIds.contains(m.id)) {
              continue;
            }
            newMentionedIds.add(m.id);
          }
          for (final name in turn.unresolvedMentionNames) {
            if (!unresolvedHints.contains(name)) unresolvedHints.add(name);
          }
        }

        if (newMentionedIds.isEmpty) {
          if (unresolvedHints.isNotEmpty) {
            await _saveOrchestrationSystemMessage(
              channelId,
              '⚠️ 群成员提及了不存在的成员：${unresolvedHints.join('、')}（已忽略）',
            );
          }
          break;
        }

        // Structured declaration reasons are forwarded to the mentioned agent
        // so it knows why it was asked for help.
        final mentionReasonById = <String, String>{};
        for (final turn in turns.values) {
          for (final m in turn.mentions) {
            if (!m.notify || m.reason == null) continue;
            mentionReasonById.putIfAbsent(m.id, () => m.reason!);
          }
        }

        LoggerService().debug(
          'allMembers cascade round ${cascadeRound + 1}: dispatching ${newMentionedIds.length} newly-mentioned agents',
          tag: 'GroupOrchestrationService',
        );

        final cascadeHistory = await loadAndTruncateHistory(channelId,
            excludeMessageId: userMessage.id);
        final cascadeFutures =
            <({String agentId, Future<GroupTurnResult> future})>[];
        for (final agent in agents) {
          if (!newMentionedIds.contains(agent.id)) continue;
          onAgentStart?.call(agent.id, agent.name);
          final isFirst = !agentIdsWithHistory.contains(agent.id);
          cascadeFutures.add((
            agentId: agent.id,
            future: _executor
                .processGroupAgent(
              agent: agent,
              channelId: channelId,
              content: () {
                final baseContent = GroupDispatchParser.taskContentForAgent(
                  agentId: agent.id,
                  steps: cascadeSteps,
                  fallback: effectiveContent,
                );
                final reason = mentionReasonById[agent.id];
                final content = reason != null
                    ? '【成员提及】$reason\n\n$baseContent'
                    : baseContent;
                // L2：cascade 成员回合也注入近期事件感知行。
                return _withEventDigest('$content$memberMemoryNote', channelId);
              }(),
              attachments: attachments,
              userId: userId,
              userName: userName,
              groupName: groupName,
              groupDescription: groupDescription,
              allAgents: agents,
              historyMessages: cascadeHistory,
              mentionedAgentIds: newMentionedIds.toList(),
              isFirstMessage: isFirst,
              messageVersion: messageVersion,
              channelMembers: channelMembers,
              adminAgent: adminForCascade,
              customSystemPrompt: customSystemPrompt,
              mentionMode: mentionMode,
              acpCancellationToken: acpCancellationToken,
              onStreamChunk: onStreamChunk,
              onAgentDone: onAgentDone,
              onInteractionRequest: onInteractionRequest,
              orchestrationTraceId: orchTraceId,
            )
                .catchError((e) {
              LoggerService().error(
                  'Cascade agent ${agent.name} uncaught error',
                  tag: 'GroupOrchestrationService',
                  error: e);
              failedAgentNames?.add(agent.name);
              onAgentDone?.call(agent.id, agent.name, true);
              return const GroupTurnResult();
            }),
          ));
        }
        final newTurns = <String, GroupTurnResult>{};
        for (final t in cascadeFutures) {
          newTurns[t.agentId] = await t.future;
        }
        respondedAgentIds.addAll(newMentionedIds);
        turns = newTurns;
        if (allTurnsCollector != null) {
          allTurnsCollector.addAll(newTurns);
        }
      }
    }

    if (effectiveMentionedAgentIds.isNotEmpty) {
      // 5a. User explicitly @mentioned agents — those agents respond directly
      final turnFutures =
          <({String agentId, Future<GroupTurnResult> future})>[];
      for (final agent in agents) {
        if (!effectiveMentionedAgentIds.contains(agent.id)) {
          onAgentDone?.call(agent.id, agent.name, true);
          continue;
        }
        onAgentStart?.call(agent.id, agent.name);
        final isFirstMessage = !agentIdsWithHistory.contains(agent.id);
        turnFutures.add((
          agentId: agent.id,
          future: _executor
              .processGroupAgent(
            agent: agent,
            channelId: channelId,
            content: _withEventDigest(effectiveContent, channelId),
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
          )
              .catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error',
                tag: 'GroupOrchestrationService', error: e);
            onAgentDone?.call(agent.id, agent.name, true);
            return const GroupTurnResult();
          }),
        ));
      }
      final turnResults = <String, GroupTurnResult>{};
      for (final t in turnFutures) {
        turnResults[t.agentId] = await t.future;
      }
      final respondedAgentIds = <String>{...turnResults.keys};

      // allMembers cascading for Path 5a: members mentioning other members in
      // their replies (text @ or legacy JSON) activate them.
      if (mentionMode == 'allMembers') {
        await runMentionCascade(
          initialTurns: turnResults,
          respondedAgentIds: respondedAgentIds,
          inboxMentions: await _readInboxMentions(),
        );
      }

      await endOrchTrace(InferenceStatus.completed);
      onAllDone?.call();
      return;
    } else if (adminAgentId != null) {
      // 5b. Admin-first flow: only admin responds, then delegates via @mentions
      final adminAgent = agents.where((a) => a.id == adminAgentId).firstOrNull;
      if (adminAgent == null) {
        LoggerService().warning(
            'Admin agent $adminAgentId not found, falling back to all-agents mode',
            tag: 'GroupOrchestrationService');
      }
      if (adminAgent != null) {
        // Skip non-admin agents immediately
        for (final agent in agents) {
          if (agent.id != adminAgentId) {
            onAgentDone?.call(agent.id, agent.name, true);
          }
        }

        final nonAdminAgents =
            agents.where((a) => a.id != adminAgentId).toList();

        // Flag: set when the admin agent itself triggers a non-blocking interaction
        // (form / file_upload / action_confirmation in non-flow mode) so the
        // orchestration loop can exit immediately and let the user respond in
        // the next conversation turn.
        bool adminTriggeredNonBlockingInteraction = false;
        Future<Map<String, dynamic>?> onInteractionRequestForAdmin(
          String agentId,
          String agentName,
          String interactionType,
          Map<String, dynamic> data,
        ) async {
          final result = await onInteractionRequest?.call(
              agentId, agentName, interactionType, data);
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
        }) =>
            _executor.processGroupAgent(
              agent: agent,
              channelId: channelId,
              content: _withEventDigest(effectiveContent, channelId),
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
        final detectedModality = const GroupPromptBuilder()
            .detectRecentAttachmentModality(historyMessages);

        // If admin cannot handle the detected modality, auto-delegate instead
        // of calling the LLM (which would fail with a 400 error).
        if (detectedModality != ModalityType.text &&
            !adminAgent.supportsModality(detectedModality)) {
          LoggerService().info(
              'Admin ${adminAgent.name} does not support $detectedModality, auto-delegating',
              tag: 'GroupOrchestrationService');

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
                }[detectedModality] ??
                '多模态';

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
            final updatedHistory = await loadAndTruncateHistory(channelId,
                excludeMessageId: userMessage.id);

            try {
              await callGroupAgent(
                agent: capableAgent,
                historyMessages: updatedHistory,
                mentionedAgentIds: [capableAgent.id],
                isFirstMessage: isFirst,
                adminAgent: adminAgent,
              );
            } catch (e) {
              LoggerService().error(
                  'Delegated agent ${capableAgent.name} uncaught error',
                  tag: 'GroupOrchestrationService',
                  error: e);
              onAgentDone?.call(capableAgent.id, capableAgent.name, true);
            }
          } else {
            // No agent in the group can handle this modality
            final modalityLabel = {
                  ModalityType.image: '图片',
                  ModalityType.audio: '音频',
                  ModalityType.video: '视频',
                }[detectedModality] ??
                '多模态';

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
        // M8: 跨轮累积本轮全部成员（含 cascade）引用的产物 store:// URI，
        // finish 轮随 final_summary 一起蒸馏进群记忆，供后续轮次成员直接引用。
        final roundArtifactUris = <String>{};

        GroupTurnResult resolveAdminDecision(
          GroupTurnResult toolTurn, {
          Map<String, dynamic>? inboxDispatch,
          Map<String, dynamic>? inboxFinish,
        }) {
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
          // 外接 agent MCP 工具写入的编排决定（inbox 优先于文本 JSON 约定）。
          if (inboxDispatch != null) {
            final parsed = GroupOrchestrationTools.parseDispatchArgs(
              inboxDispatch,
              nonAdminAgents,
            );
            if (parsed.parseError == null || parsed.steps.isNotEmpty) {
              return GroupTurnResult(
                content: text,
                steps: parsed.steps,
                wantsContinue: parsed.steps.isNotEmpty,
                isDone: parsed.steps.isEmpty,
                unresolvedNames: parsed.unresolvedNames,
                hasOrchestrationSignal: true,
              );
            }
          }
          if (inboxFinish != null) {
            final action = inboxFinish['action'] as String?;
            if (action == 'continue') {
              return GroupTurnResult(
                content: text,
                wantsContinue: true,
                hasOrchestrationSignal: true,
              );
            }
            if (action == 'pause') {
              return GroupTurnResult(
                content: text,
                isPause: true,
                isDone: true,
                hasOrchestrationSignal: true,
              );
            }
            if (action == 'done') {
              return GroupTurnResult(
                content: text,
                isDone: true,
                hasOrchestrationSignal: true,
              );
            }
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
            isDone: parsed.isDone ||
                parsed.isPause ||
                (parsed.steps.isEmpty && !parsed.wantsContinue),
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
            content: '$effectiveContent\n\n'
                '[SYSTEM] 需求澄清：若用户需求不明确或信息不足，请先调用 '
                '`group_finish`（action=`pause`）向用户澄清，确认后再 '
                '`group_dispatch`，不要凭猜测派活。',
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
          LoggerService().error('Admin agent ${adminAgent.name} uncaught error',
              tag: 'GroupOrchestrationService', error: e);
          // M1: 执行器错误路径已不回调 onAgentDone，这里作为唯一上报方；回合
          // 失败一律按 skipped 上报（true），避免半截回复被当作正常完成。
          onAgentDone?.call(adminAgent.id, adminAgent.name, true);
        }
        currentRound++;
        final firstInbox = await _readRoundInbox();
        adminTurn = resolveAdminDecision(
          adminTurn,
          inboxDispatch: firstInbox.dispatch,
          inboxFinish: firstInbox.finish,
        );

        // If the first admin reply already contains a plan or dispatch, create a workflow
        // before entering the delegation loop.
        final earlyFlowPlan = FlowPlan.tryParse(adminResponseContent);
        if (earlyFlowPlan != null &&
            earlyFlowPlan.stages.any((s) => s.steps.isNotEmpty)) {
          await _planningHelpers.stripFlowPlanBlockFromLastMessage(
              channelId, adminAgent.id);
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
          await _dispatchParser.stripDispatchJsonFromLastMessage(
              channelId, adminAgent.id);
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

        // L3: 连续全失败轮计数器——成员全部失败时管理员反复重派只会空耗
        // （ACP 单轮最长 3h × maxRounds 50），连续 N 轮全失败即提前停止。
        var consecutiveAllFailedRounds = 0;
        const maxConsecutiveAllFailedRounds = 3;
        // Compact record of the last dispatch. The dispatch JSON is stripped
        // from the admin's message (user-facing), so this note is re-injected
        // into the summarize round to let the admin remember its own plan.
        String? lastDispatchNote;

        // M4：发一轮结束事件。正常派发路径在 summarize 后发（见下），但中断/
        // 取消/无派发等退出路径之前不发，导致下一轮成员感知断裂。此处统一
        // 封装，供各退出路径补发。
        void emitRoundEnd({
          List<String>? delegatedAgentNames,
          List<String>? failed = const [],
          String summary = '',
        }) {
          onGroupEvent?.call(GroupEvent.loopRoundCompleted(
            channelId: channelId,
            round: currentRound,
            delegatedAgentNames: delegatedAgentNames,
            failedAgentNames: failed,
            summary: summary,
            // M4：绑定本次编排会话（触发用户消息 id），下一轮成员只感知本
            // 任务的事件，避免连续两次任务时注入上一任务的轮次结论。
            orchestrationId: userMessage.id,
          ));
        }

        while (true) {
          // 新一轮开始：刷新 inbox 新鲜度基准（只消费本轮内 MCP 写入的决定）。
          roundStartTime = DateTime.now();
          // If admin sent a form/file_upload in the previous round, exit immediately
          // so the user can fill it in (forms are non-blocking).
          if (adminTriggeredNonBlockingInteraction) {
            LoggerService().debug(
                'Loop orchestration ended: admin triggered non-blocking interaction',
                tag: 'GroupOrchestrationService');
            // L1：本轮并不实际执行，先不落盘 round_start，避免 latest.json 留下
            // 一轮从未运行的「running」幽灵状态（随后 finish 的 rounds 计数对不上）。
            emitRoundEnd(summary: '管理员触发表单/文件交互，本轮暂停等待用户填写');
            break;
          }
          // 确认本轮确实要执行后才落盘 round_start（L1：早退路径不留下幽灵 running）。
          await _emitOrchestrationRound(
            channelId: channelId,
            round: currentRound,
            kind: 'round_start',
            payload: {
              'status': 'running',
              'channel_id': channelId,
              'message_id': userMessage.id,
              'started_at': roundStartTime.toIso8601String(),
            },
          );
          // Check cancellation — run abort-summarize before exiting if we have
          // already done at least one round (i.e. Admin has produced content).
          if (acpCancellationToken?.isCancelled == true) {
            LoggerService().info(
                'Loop orchestration cancelled at round $currentRound',
                tag: 'GroupOrchestrationService');
            if (adminResponseContent.trim().isNotEmpty) {
              final abortHistory = await loadAndTruncateHistory(channelId,
                  excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: _withEventDigest(effectiveContent, channelId),
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
                LoggerService().error(
                    'Admin abort-summarize (loop-start cancel) error',
                    tag: 'GroupOrchestrationService',
                    error: e);
                // M1: 唯一上报方；失败一律 skipped。
                onAgentDone?.call(adminAgent.id, adminAgent.name, true);
              }
              // Hide the closing {"done": true} JSON block from the user.
              await _dispatchParser.stripDispatchJsonFromLastMessage(
                  channelId, adminAgent.id);
            }
            emitRoundEnd(summary: '编排在第 $currentRound 轮被取消');
            break;
          }

          // Check round limit. currentRound 是「当前正要执行的第 N 轮」（首轮
          // 派发后 +1），故跑满 maxRounds 轮须用 `>` 而非 `>=`（M5 off-by-one）。
          if (currentRound > maxRounds) {
            LoggerService().info(
                'Loop orchestration reached max rounds ($maxRounds)',
                tag: 'GroupOrchestrationService');
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
            final maxRoundsHistory = await loadAndTruncateHistory(channelId,
                excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: _withEventDigest(effectiveContent, channelId),
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
              LoggerService().error('Admin abort-summarize (maxRounds) error',
                  tag: 'GroupOrchestrationService', error: e);
              // M1: 唯一上报方；失败一律 skipped。
              onAgentDone?.call(adminAgent.id, adminAgent.name, true);
            }
            // Hide the closing {"done": true} JSON block from the user.
            await _dispatchParser.stripDispatchJsonFromLastMessage(
                channelId, adminAgent.id);
            emitRoundEnd(
              summary: adminResponseContent.trim().isEmpty
                  ? '编排达到最大轮次 $maxRounds 自动停止'
                  : '编排达到最大轮次 $maxRounds 自动停止：$adminResponseContent',
            );
            break;
          }

          // Prefer tool-first orchestration; fall back to legacy text JSON.
          final roundInbox = await _readRoundInbox();
          final dispatch = resolveAdminDecision(
            adminTurn,
            inboxDispatch: roundInbox.dispatch,
            inboxFinish: roundInbox.finish,
          );
          adminTurn = dispatch;
          final adminWantsContinue = dispatch.wantsContinue;
          final delegatedIds =
              dispatch.steps.expand((s) => s.agentIds).toSet().toList();

          final flowPlanInRound = FlowPlan.tryParse(adminResponseContent);
          if (flowPlanInRound != null &&
              flowPlanInRound.stages.any((s) => s.steps.isNotEmpty)) {
            await _planningHelpers.stripFlowPlanBlockFromLastMessage(
                channelId, adminAgent.id);
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
              await _dispatchParser.stripDispatchJsonFromLastMessage(
                  channelId, adminAgent.id);
              final nudgeHistory = await loadAndTruncateHistory(channelId,
                  excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                adminTurn = await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content:
                      '$effectiveContent\n\n[SYSTEM] 你上一条回复中的派发指令无法执行：${dispatch.parseError}。请调用 `group_dispatch` 重新派活（agents 必须用注册名），或调用 `group_finish`（done/continue/pause）；若无需派发请直接给出最终答复并 finish。',
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
                LoggerService().error(
                    'Admin nudge error at round $currentRound',
                    tag: 'GroupOrchestrationService',
                    error: e);
                // M1: 唯一上报方；失败一律 skipped。
                onAgentDone?.call(adminAgent.id, adminAgent.name, true);
                break;
              }
              currentRound++;
              final nudgeInbox = await _readRoundInbox();
              adminTurn = resolveAdminDecision(
                adminTurn,
                inboxDispatch: nudgeInbox.dispatch,
                inboxFinish: nudgeInbox.finish,
              );
              if (adminResponseContent.trim().isEmpty &&
                  !adminTurn.hasOrchestrationSignal) {
                LoggerService().warning(
                    'Admin nudge produced empty response at round $currentRound, stopping',
                    tag: 'GroupOrchestrationService');
                emitRoundEnd(summary: '管理员多次未产出有效派发，流程停止');
                break;
              }
              continue;
            }
            // Nudge budget exhausted — surface the failure and stop.
            await _dispatchParser.stripDispatchJsonFromLastMessage(
                channelId, adminAgent.id);
            await _saveOrchestrationSystemMessage(
              channelId,
              '⚠️ 管理员的派发指令多次无法解析（${dispatch.parseError}），流程已停止，请重新描述需求再试。',
            );
            emitRoundEnd(summary: '管理员派发指令多次无法解析（${dispatch.parseError}），流程停止');
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

          // Record the parsed dispatch decision into the group workspace
          // (解析后结构，非原始 JSON 块；供恢复与跨端共享)。
          await _emitOrchestrationRound(
            channelId: channelId,
            round: currentRound,
            kind: 'dispatch_decision',
            payload: {
              'status': 'dispatched',
              'round': currentRound,
              'steps': dispatch.steps
                  .map((s) => {
                        'step': s.step,
                        'agents': s.agentIds,
                        'task': s.task,
                        'mode': s.mode,
                      })
                  .toList(),
              'wants_continue': adminWantsContinue,
              'unresolved_names': dispatch.unresolvedNames,
              'parse_error': dispatch.parseError,
            },
          );

          if (delegatedIds.isEmpty && !adminWantsContinue) {
            // No dispatch and no continue — orchestration complete. Strip the
            // closing {"done": true} JSON block so the user never sees it.
            LoggerService().debug(
                'Loop orchestration ended: no dispatch at round $currentRound',
                tag: 'GroupOrchestrationService');
            await _dispatchParser.stripDispatchJsonFromLastMessage(
                channelId, adminAgent.id);
            emitRoundEnd(summary: adminResponseContent);
            break;
          }

          // If admin wants to continue on its own (no delegation needed),
          // strip the dispatch JSON block, reload history and re-invoke admin directly.
          if (delegatedIds.isEmpty && adminWantsContinue) {
            // Check cancellation before re-invoking admin — run abort-summarize first
            if (acpCancellationToken?.isCancelled == true) {
              LoggerService().info(
                  'Admin continue cancelled at round $currentRound',
                  tag: 'GroupOrchestrationService');
              await _dispatchParser.stripDispatchJsonFromLastMessage(
                  channelId, adminAgent.id);
              final abortHistory = await loadAndTruncateHistory(channelId,
                  excludeMessageId: userMessage.id);
              adminResponseContent = '';
              onAgentStart?.call(adminAgent.id, adminAgent.name);
              try {
                await _executor.processGroupAgent(
                  agent: adminAgent,
                  channelId: channelId,
                  content: _withEventDigest(effectiveContent, channelId),
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
                LoggerService().error(
                    'Admin abort-summarize (continue cancel) error',
                    tag: 'GroupOrchestrationService',
                    error: e);
                // M1: 唯一上报方；失败一律 skipped。
                onAgentDone?.call(adminAgent.id, adminAgent.name, true);
              }
              emitRoundEnd(summary: '管理员继续处理在第 $currentRound 轮被取消');
              break;
            }

            LoggerService().debug(
                'Admin continue at round $currentRound, re-invoking admin',
                tag: 'GroupOrchestrationService');
            await _dispatchParser.stripDispatchJsonFromLastMessage(
                channelId, adminAgent.id);

            final continueHistory = await loadAndTruncateHistory(channelId,
                excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              adminTurn = await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: _withEventDigest(effectiveContent, channelId),
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
              LoggerService().error(
                  'Admin continue error at round $currentRound',
                  tag: 'GroupOrchestrationService',
                  error: e);
              // M1: 唯一上报方；失败一律 skipped。
              onAgentDone?.call(adminAgent.id, adminAgent.name, true);
              break;
            }
            currentRound++;
            final continueInbox = await _readRoundInbox();
            adminTurn = resolveAdminDecision(
              adminTurn,
              inboxDispatch: continueInbox.dispatch,
              inboxFinish: continueInbox.finish,
            );

            // Guard against empty responses to prevent stuck loops
            if (adminResponseContent.trim().isEmpty &&
                !adminTurn.hasOrchestrationSignal) {
              LoggerService().warning(
                  'Admin continue produced empty response at round $currentRound, stopping',
                  tag: 'GroupOrchestrationService');
              break;
            }
            continue;
          }

          // Strip dispatch JSON from saved message before delegating
          await _dispatchParser.stripDispatchJsonFromLastMessage(
              channelId, adminAgent.id);

          // Structured task dispatch → create workflow + approval card instead of
          // running inline delegation (execution starts after user approval).
          if (dispatch.steps.isNotEmpty) {
            final flowPlanFromDispatch =
                _dispatchParser.buildFlowPlanFromDispatch(
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

          // Execute delegated agents based on dispatch mode. Turn results are
          // captured per agent so the allMembers cascade below can activate
          // members mentioned in their replies without re-reading the DB.
          final delegatedTurnResults = <String, GroupTurnResult>{};
          final isSequential = dispatch.steps.isNotEmpty &&
              dispatch.steps.first.mode == 'sequential';

          if (isSequential) {
            // Sequential workflow: execute steps in order
            for (final step in dispatch.steps) {
              if (acpCancellationToken?.isCancelled == true) break;
              final stepAgentIds = step.agentIds;

              // Reload history before each step so agents see previous steps' output
              final stepHistory = await loadAndTruncateHistory(channelId,
                  excludeMessageId: userMessage.id);

              // Launch all agents within this step concurrently
              final stepFutures = <Future<void>>[];
              for (final agent in agents) {
                if (!stepAgentIds.contains(agent.id)) continue;
                onAgentStart?.call(agent.id, agent.name);
                final isFirst = !agentIdsWithHistory.contains(agent.id);
                final memberBrief = step.contentOr(effectiveContent);
                stepFutures.add(() async {
                  final result = await _executor
                      .processGroupAgent(
                    agent: agent,
                    channelId: channelId,
                    // 成员先看【全局需求】（用户完整消息），再看【你的任务】（局部 brief）。
                    content: GroupDispatchParser.buildMemberTurnContent(
                      memberBrief: memberBrief,
                      globalRequirement: effectiveContent,
                      memoryNote: memberMemoryNote,
                      dispatchPlanNote:
                          GroupDispatchParser.buildDispatchPlanNote(
                        steps: dispatch.steps,
                        agents: agents,
                      ),
                      loopEventNote: _buildLoopEventNote(channelId, orchestrationId: userMessage.id),
                    ),
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
                  )
                      .catchError((e) {
                    LoggerService().error(
                        'Step ${step.step} agent ${agent.name} uncaught error',
                        tag: 'GroupOrchestrationService',
                        error: e);
                    failedAgentNames.add(agent.name);
                    onAgentDone?.call(agent.id, agent.name, true);
                    return const GroupTurnResult();
                  });
                  delegatedTurnResults[agent.id] = result;
                }());
              }
              await Future.wait(stepFutures);
            }
          } else {
            // Concurrent execution (default)
            final updatedHistory = await loadAndTruncateHistory(channelId,
                excludeMessageId: userMessage.id);

            final delegatedFutures = <Future<void>>[];
            for (final agent in agents) {
              if (!delegatedIds.contains(agent.id)) continue;
              onAgentStart?.call(agent.id, agent.name);
              final isFirst = !agentIdsWithHistory.contains(agent.id);
              delegatedFutures.add(() async {
                // 成员先看【全局需求】（用户完整消息），再看【你的任务】（局部 brief）。
                final memberBrief = GroupDispatchParser.taskContentForAgent(
                  agentId: agent.id,
                  steps: dispatch.steps,
                  fallback: effectiveContent,
                );
                final result = await _executor
                    .processGroupAgent(
                  agent: agent,
                  channelId: channelId,
                  content: GroupDispatchParser.buildMemberTurnContent(
                    memberBrief: memberBrief,
                    globalRequirement: effectiveContent,
                    memoryNote: memberMemoryNote,
                    dispatchPlanNote: GroupDispatchParser.buildDispatchPlanNote(
                      steps: dispatch.steps,
                      agents: agents,
                    ),
                    loopEventNote: _buildLoopEventNote(channelId, orchestrationId: userMessage.id),
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
                )
                    .catchError((e) {
                  LoggerService().error(
                      'Delegated agent ${agent.name} uncaught error',
                      tag: 'GroupOrchestrationService',
                      error: e);
                  failedAgentNames.add(agent.name);
                  onAgentDone?.call(agent.id, agent.name, true);
                  return const GroupTurnResult();
                });
                delegatedTurnResults[agent.id] = result;
              }());
            }
            await Future.wait(delegatedFutures);
          }

          // M7: 汇总用回合集合 = 本轮派发成员 + cascade 级联激活的成员，
          // 保证 admin 收尾汇总能列出级联子任务的产物 URI。
          final memberTurnResults =
              Map<String, GroupTurnResult>.from(delegatedTurnResults);

          // allMembers cascading: after delegated agents respond, members
          // mentioning other members (text @ or legacy JSON) activate them.
          // Turn results carry the unified mentions — no DB re-read.
          if (mentionMode == 'allMembers') {
            await runMentionCascade(
              initialTurns: delegatedTurnResults,
              respondedAgentIds: {...delegatedIds},
              failedAgentNames: failedAgentNames,
              inboxMentions: await _readInboxMentions(),
              allTurnsCollector: memberTurnResults,
            );
          }

          // M8: 跨轮累积全部成员回合（含 cascade 级联成员）引用的产物 URI。
          for (final r in memberTurnResults.values) {
            roundArtifactUris.addAll(extractStoreUris(r.content));
          }

          // L3: 连续全失败轮提前终止。本轮派发成员全部失败（超时/抛错/空回复
          // 均计入 failedAgentNames）时，管理员再重派同一批成员只会继续空耗；
          // 连续 maxConsecutiveAllFailedRounds 轮全失败即停止并告知用户。
          if (delegatedIds.isNotEmpty) {
            final delegatedNames = delegatedIds.map((id) =>
                agents.where((a) => a.id == id).firstOrNull?.name ?? id);
            final allDelegatedFailed =
                delegatedNames.every(failedAgentNames.contains);
            if (allDelegatedFailed) {
              consecutiveAllFailedRounds++;
            } else {
              consecutiveAllFailedRounds = 0;
            }
            if (consecutiveAllFailedRounds >= maxConsecutiveAllFailedRounds) {
              LoggerService().warning(
                'Loop orchestration stopped: $consecutiveAllFailedRounds '
                'consecutive all-failed delegation rounds at round $currentRound',
                tag: 'GroupOrchestrationService',
              );
              await _saveOrchestrationSystemMessage(
                channelId,
                '⚠️ 连续 $consecutiveAllFailedRounds 轮所有成员均执行失败，'
                '流程已自动停止。请检查成员连接与任务配置后重试。',
              );
              emitRoundEnd(
                delegatedAgentNames: delegatedTurnResults.keys
                    .map((id) =>
                        agents.where((a) => a.id == id).firstOrNull?.name ?? id)
                    .toList(),
                failed: List.unmodifiable(failedAgentNames),
                summary: '连续 $consecutiveAllFailedRounds 轮成员全部执行失败，自动停止',
              );
              break;
            }
          }

          // Check cancellation after member execution.
          // Even when cancelled, run one final abort-summarize so Admin can
          // summarise the work already done before the loop exits.
          if (acpCancellationToken?.isCancelled == true) {
            LoggerService().info(
                'Loop orchestration cancelled after member execution at round $currentRound — running abort-summarize',
                tag: 'GroupOrchestrationService');
            final abortHistory = await loadAndTruncateHistory(channelId,
                excludeMessageId: userMessage.id);
            adminResponseContent = '';
            onAgentStart?.call(adminAgent.id, adminAgent.name);
            try {
              await _executor.processGroupAgent(
                agent: adminAgent,
                channelId: channelId,
                content: _withEventDigest(effectiveContent, channelId),
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
              LoggerService().error('Admin abort-summarize error',
                  tag: 'GroupOrchestrationService', error: e);
              // M1: 唯一上报方；失败一律 skipped。
              onAgentDone?.call(adminAgent.id, adminAgent.name, true);
            }
            // Hide the closing {"done": true} JSON block from the user.
            await _dispatchParser.stripDispatchJsonFromLastMessage(
                channelId, adminAgent.id);
            emitRoundEnd(
              delegatedAgentNames: delegatedTurnResults.keys
                  .map((id) =>
                      agents.where((a) => a.id == id).firstOrNull?.name ?? id)
                  .toList(),
              failed: List.unmodifiable(failedAgentNames),
              summary: '编排在成员执行后被取消',
            );
            break;
          }

          // Members finished — snapshot their structured outcomes before the
          // summarize round re-reads history from the DB.
          await _emitOrchestrationRound(
            channelId: channelId,
            round: currentRound,
            kind: 'members_done',
            payload: {
              'status': 'members_done',
              'round': currentRound,
              'member_results': {
                for (final e in memberTurnResults.entries)
                  e.key: {
                    'content': e.value.content,
                    'wants_continue': e.value.wantsContinue,
                    'is_done': e.value.isDone,
                    'has_dispatch': e.value.hasDispatch,
                    // 成员回复中引用的产物 store:// URI，落盘供审计/恢复
                    // （含 cascade 级联成员，M7）。
                    'artifacts': extractStoreUris(e.value.content),
                  },
              },
              'failed_agents': failedAgentNames,
            },
          );

          // Reload history (now includes member replies) and call admin again to summarize
          final loopHistory = await loadAndTruncateHistory(channelId,
              excludeMessageId: userMessage.id);

          adminResponseContent = '';
          onAgentStart?.call(adminAgent.id, adminAgent.name);
          try {
            adminTurn = await _executor.processGroupAgent(
              agent: adminAgent,
              channelId: channelId,
              content:
                  '${lastDispatchNote != null ? '$effectiveContent\n\n[SYSTEM] 你上一轮的派发记录（该 JSON 已从你的消息中隐藏，仅供核对）：$lastDispatchNote' : effectiveContent}'
                  '${buildMemberArtifactsBlock(memberTurnResults, agents)}',
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
            LoggerService().error(
                'Admin summarize error at round $currentRound',
                tag: 'GroupOrchestrationService',
                error: e);
            // M1: 唯一上报方；失败一律 skipped。
            onAgentDone?.call(adminAgent.id, adminAgent.name, true);
            break;
          }
          await _emitOrchestrationRound(
            channelId: channelId,
            round: currentRound,
            kind: 'round_complete',
            payload: {
              'status': 'round_complete',
              'round': currentRound,
              'admin_summary': adminResponseContent,
              'wants_continue': adminTurn.wantsContinue,
              'is_done': adminTurn.isDone,
            },
          );

          // M5：本轮编排完成 → 发被动 loopRoundCompleted 事件，供下一轮成员
          // 感知上一轮「谁做了什么、谁失败了」。被动事件只入事件日志，不触发
          // 管理员主动回合（不新增 LLM 调用）。
          onGroupEvent?.call(GroupEvent.loopRoundCompleted(
            channelId: channelId,
            round: currentRound,
            delegatedAgentNames: delegatedTurnResults.keys
                .map((id) =>
                    agents.where((a) => a.id == id).firstOrNull?.name ?? id)
                .toList(),
            failedAgentNames: List.unmodifiable(failedAgentNames),
            summary: adminResponseContent,
            // M4：绑定本次编排会话（触发用户消息 id）。
            orchestrationId: userMessage.id,
          ));

          currentRound++;
          final summarizeInbox = await _readRoundInbox();
          adminTurn = resolveAdminDecision(
            adminTurn,
            inboxDispatch: summarizeInbox.dispatch,
            inboxFinish: summarizeInbox.finish,
          );
        }

        await _emitOrchestrationRound(
          channelId: channelId,
          round: currentRound,
          kind: 'finish',
          payload: {
            'status': 'finished',
            'rounds': currentRound,
            'cancelled': acpCancellationToken?.isCancelled == true,
            'finished_at': DateTime.now().toIso8601String(),
            // 最后一次 summarize 的 admin 总结 → 群记忆蒸馏素材
            // （shared/memory/，零额外 LLM 调用）。
            'final_summary': adminResponseContent,
            // M8: 跨轮累积的成员产物 URI，随记忆一起落盘供后续轮次引用。
            'artifact_uris': roundArtifactUris.toList(),
          },
        );

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
          _executor
              .processGroupAgent(
            agent: agent,
            channelId: channelId,
            content: _withEventDigest(effectiveContent, channelId),
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
          )
              .catchError((e) {
            LoggerService().error('Group agent ${agent.name} uncaught error',
                tag: 'GroupOrchestrationService', error: e);
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
