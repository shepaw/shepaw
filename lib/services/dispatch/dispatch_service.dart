import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/dispatch_task.dart';
import '../../models/inference_log_entry.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../local_user_identity.dart';
import '../logger_service.dart';
import '../messaging/agent_messaging_service.dart';
import '../she_service.dart';
import '../trace_service.dart';
import '../../storage/context_bundle.dart';
import 'she_relay_session_service.dart';

/// She 单聊任务派发服务：登记 → 跟踪 → 回传闭环。
///
/// 流程：
/// 1. [dispatch] 落库派发记录，在 She↔用户 频道写状态消息（仅 task 型），
///    以 She 身份把任务消息存进目标 agent 的 DM 频道并 fire-and-forget 发送
///    （严禁同步等待对方完成——会死锁 She 自己的工具循环）。
/// 2. 订阅 [ChatService.agentTaskCompletionStream]，按 `replyTo == 任务消息id`
///    精确匹配（失败路径无 replyTo 时退化为"该频道唯一在途派发"）。
/// 3. 终态后更新状态消息（仅 task 型），并把结果以合成消息注入 She↔用户 频道、
///    重新唤起 She，由她用自己的口吻向用户汇报（task 型）或继续对话（chat 型）。
/// 4. 超时只终态化派发记录、不取消底层 turn；归因挪入迟到观察表，迟到的
///    完成事件仍会把结果回报给 She（迟到成功则任务升级为 done）。
///
/// 防回环：注入消息的 metadata 带 `dispatch_result: true`（task）或
/// `she_chat_relay: true`（chat）；完成事件只按在途派发匹配，She 汇报自身
/// 产生的完成事件不会被认领。chat 型另有连续对聊轮次预算
/// （[maxChatRelayTurns]），耗尽后 agents.chat 直接拒绝，防止 She 与
/// agent 在无用户输入时无限接力。
class DispatchService {
  static final DispatchService instance = DispatchService._();
  DispatchService._();

  /// 注入消息的虚拟发送者身份
  static const String senderId = 'dispatch-service';
  static const String senderName = 'Dispatch';

  /// 同一 agent 的在途派发上限
  static const int maxInFlightPerAgent = 3;

  /// chat 型转发：无用户新输入时允许的连续自动接力轮次上限
  static const int maxChatRelayTurns = 5;

  /// 回传给 She 的结果正文最大字符数（防超长上下文）
  static const int maxResultChars = 6000;

  /// DB 里 result_summary 的最大字符数
  static const int maxSummaryChars = 500;

  final LocalDatabaseService _db = LocalDatabaseService();
  final SheRelaySessionService _relaySessions = SheRelaySessionService();
  final Uuid _uuid = const Uuid();

  StreamSubscription<AgentTaskCompletion>? _sub;
  final Map<String, Timer> _timers = {};

  /// 在途派发：dispatchTaskId -> 任务消息 id（replyTo 精确匹配用）
  final Map<String, String> _inFlightMsgIds = {};

  /// 已超时但底层 turn 仍在对端执行的派发：taskId -> (任务消息 id, 目标频道)。
  /// 迟到完成事件按此归因并回传结果给 She（见 [_onLateCompletion]）。
  final Map<String, ({String msgId, String channelId})> _lateWatch = {};

  /// 已终态的派发 id（同步防重：stream 与 catchError 可能双触发）
  final Set<String> _finalized = {};

  bool _started = false;

  /// 启动订阅并清扫上次运行遗留的在途记录。幂等。
  void ensureStarted() {
    if (_started) return;
    _started = true;
    _sub = ChatService().agentTaskCompletionStream.listen(
      (c) => unawaited(_onCompletion(c)),
    );
    unawaited(_db.failStaleDispatchTasks());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _started = false;
  }

  // ---------------------------------------------------------------------------
  // 发起派发
  // ---------------------------------------------------------------------------

  /// 把任务 [prompt] 派发给 [targetAgent]，结果回传到 [sourceChannelId]
  /// （She↔用户 频道）。
  ///
  /// 执行频道由内部确保：在 She 与 [targetAgent] 的绑定 DM（
  /// [SheRelaySessionService]）中执行，不污染用户与该 agent 的普通单聊
  /// （peer/ACP session 与本地上下文均隔离）。
  ///
  /// [kind] 为 [DispatchTask.kindChat] 时走对话转发语义：不写状态卡片、
  /// 回复以 `[Agent Reply]` 注入并唤起 She 继续对话，且受连续对聊轮次
  /// 预算（[maxChatRelayTurns]）约束。
  Future<Map<String, dynamic>> dispatch({
    required String sourceChannelId,
    required RemoteAgent targetAgent,
    required String prompt,
    Duration timeout = const Duration(minutes: 30),
    String kind = DispatchTask.kindTask,
  }) async {
    ensureStarted();

    final isChat = kind == DispatchTask.kindChat;

    // chat 型：连续自动接力轮次预算，防 She↔agent 无用户输入时无限对聊
    if (isChat) {
      final recent = await ChatService()
          .loadChannelMessages(sourceChannelId, limit: 60);
      final used = countConsecutiveChatRelays(recent);
      if (used >= maxChatRelayTurns) {
        return {
          'error': 'Relay turn budget exhausted: this conversation has already '
              'relayed $used consecutive agent replies without new input from '
              'your master (limit $maxChatRelayTurns).',
          'note': 'Do NOT call agents.chat again for this thread. Summarize '
              'the conversation so far for your master and let them decide '
              'how to proceed.',
        };
      }
    }

    // 目标执行频道：She 与该 agent 的绑定 DM（独立上下文，按需创建）
    final targetChannelId = await _relaySessions.ensureRelaySession(
      sheChannelId: sourceChannelId,
      agent: targetAgent,
    );

    // 同一 agent 在途上限
    final running = await _db.listDispatchTasks(
      status: DispatchTask.statusRunning,
      targetChannelId: targetChannelId,
    );
    if (running.length >= maxInFlightPerAgent) {
      return {
        'error': 'Agent ${targetAgent.name} already has '
            '$maxInFlightPerAgent dispatches in flight. '
            'Wait for one to finish before dispatching more.',
      };
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final taskId = _uuid.v4();

    // 1. 落库派发记录
    final task = DispatchTask(
      id: taskId,
      sourceChannelId: sourceChannelId,
      targetAgentId: targetAgent.id,
      targetAgentName: targetAgent.name,
      targetChannelId: targetChannelId,
      prompt: prompt,
      status: DispatchTask.statusPending,
      createdAtMs: now,
      kind: kind,
    );
    await _db.createDispatchTask(task);

    // 链路追踪：派发生命周期（traceRole = she_dispatch）
    final traceId = _traceIdFor(taskId);
    TraceService.instance.beginTrace(
      sessionId: traceId,
      agentId: targetAgent.id,
      agentName: targetAgent.name,
      channelId: sourceChannelId,
      executionMode: isChat ? 'she_chat' : 'she_dispatch',
      userMessage: prompt,
      traceRole: isChat ? 'she_chat' : 'she_dispatch',
    );
    TraceService.instance.addSpan(
      traceId: traceId,
      spanType: 'dispatch_decision',
      name: 'dispatch_created',
      inputData: {
        'dispatch_task_id': taskId,
        'target_channel_id': targetChannelId,
        'timeout_min': timeout.inMinutes,
        'kind': kind,
      },
    );

    // 2. She↔用户 频道的状态消息（用户可见；完成后原地更新）。
    //    chat 型不写状态卡片——对话转发由 [Agent Reply] 注入与 She 的转述
    //    覆盖，状态卡会在多轮对聊时刷屏。
    String? statusMsgId;
    if (!isChat) {
      statusMsgId = _uuid.v4();
      await _writeStatusMessage(task, DispatchTask.statusRunning, statusMsgId);
    }

    // 3. 以 She 身份构造任务消息并存入目标频道。
    //    必须自己保存：sendMessageToAgent 见到 existingUserMessage 会跳过保存。
    //    §6.3 + ContextBundle：产物引用 + runtime 上下文清单。
    final taskPrompt = await ContextBundleService.instance.wrapWithContextBundle(
      prompt,
      ownerId: targetAgent.id,
      channelId: targetChannelId,
    );
    final userMsg = Message(
      id: _uuid.v4(),
      content: taskPrompt,
      timestampMs: now,
      from: MessageFrom(
          id: SheService.sheId, type: 'user', name: SheService.sheName),
      to: MessageFrom(
          id: targetAgent.id, type: 'agent', name: targetAgent.name),
      type: MessageType.text,
      metadata: {
        'dispatch_task_id': taskId,
        'is_dispatch_task': true,
        if (isChat) 'she_chat': true,
      },
    );
    await ChatService()
        .saveLocalMessage(userMsg, targetAgent.id, channelId: targetChannelId);

    await _db.updateDispatchTask(task.copyWith(
      status: DispatchTask.statusRunning,
      userMessageId: userMsg.id,
      statusMessageId: statusMsgId,
    ));
    _inFlightMsgIds[taskId] = userMsg.id;

    // 4. fire-and-forget 发送；发送期失败走 catchError 收尾
    unawaited(ChatService()
        .sendMessageToAgent(
      content: prompt,
      agent: targetAgent,
      userId: SheService.sheId,
      userName: SheService.sheName,
      channelId: targetChannelId,
      existingUserMessage: userMsg,
      // 审批代理：agent 等待操作确认时写 relay_approval 卡片到 She↔用户
      // 频道，用户在 She 窗口直接审批（应答路由回本执行频道）
      onActionConfirmation: (data) {
        unawaited(_markAwaitingConfirmation(taskId, data));
      },
    )
        .catchError((Object e, StackTrace st) {
      LoggerService().error(
        'dispatch send failed: ${targetAgent.name}',
        tag: 'Dispatch',
        error: e,
        stackTrace: st,
      );
      unawaited(_finalize(taskId, DispatchTask.statusError,
          errorMessage: e.toString()));
      return null;
    }));

    // 5. 超时看门狗
    _timers[taskId] = Timer(timeout, () {
      unawaited(_onTimeout(taskId, timeout));
    });

    LoggerService().info(
      'dispatched ${isChat ? 'chat' : 'task'} $taskId → ${targetAgent.name} [channel: $targetChannelId]',
      tag: 'Dispatch',
    );

    return {
      'ok': true,
      'dispatch_task_id': taskId,
      'target': targetAgent.name,
      'target_channel_id': targetChannelId,
      'status': DispatchTask.statusRunning,
      'note': isChat
          ? 'The agent is now replying. Its reply will arrive back into THIS '
              'conversation automatically as an [Agent Reply] message — do NOT '
              'poll agents.messages and do NOT send the same message twice. '
              'You will be re-invoked when it arrives.'
          : 'The agent is now working. Its result will be reported back into '
              'THIS conversation automatically when finished — do NOT poll '
              'agents.messages and do NOT dispatch the same task twice.',
    };
  }

  /// 统计源频道里"自最后一条真实用户消息以来"连续注入的 [Agent Reply]
  /// 转发消息数（chat 型接力已用轮次）。
  ///
  /// [messages] 为频道消息（时间升序）。从最新往前数：
  /// - `she_chat_relay` 注入消息 → 计 1 轮；
  /// - 真实用户消息（非本服务虚拟身份）→ 链中断，停止计数；
  /// - 其余（She 自己的回复、系统消息、task 型注入）→ 跳过不计。
  static int countConsecutiveChatRelays(List<Message> messages) {
    var count = 0;
    for (final m in messages.reversed) {
      if (m.metadata?['she_chat_relay'] == true) {
        count++;
        continue;
      }
      if (m.from.type == 'user' && m.from.id != senderId) break;
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // 完成事件匹配与收尾
  // ---------------------------------------------------------------------------

  Future<void> _onCompletion(AgentTaskCompletion c) async {
    String? taskId;

    // 精确匹配：最终消息的 replyTo 指向派发任务消息
    final replyTo = c.finalMessage?.replyTo;
    if (replyTo != null) {
      for (final entry in _inFlightMsgIds.entries) {
        if (entry.value == replyTo) {
          taskId = entry.key;
          break;
        }
      }
      // 迟到分支：超时后仍在对端跑的 turn 终于完成
      if (taskId == null) {
        for (final entry in _lateWatch.entries) {
          if (entry.value.msgId == replyTo) {
            await _onLateCompletion(entry.key, c);
            return;
          }
        }
      }
    }

    // 退化匹配：失败路径的系统消息没有 replyTo —— 该频道恰好只有一个在途派发时才认领
    taskId ??= await _matchSoleInFlight(c.channelId);
    if (taskId == null) {
      // 迟到 turn 的失败同样没有 replyTo —— 该频道恰有一个迟到观察时认领
      final lateId = _matchSoleLateWatch(c.channelId);
      if (lateId != null) await _onLateCompletion(lateId, c);
      return;
    }

    final content = c.finalMessage?.content;
    switch (c.outcome) {
      case AgentTaskOutcome.completed:
        // 用户在目标频道手动停止：最终消息以 [Stopped] 结尾
        if (content != null && content.trimRight().endsWith('[Stopped]')) {
          await _finalize(taskId, DispatchTask.statusError,
              result: content, errorMessage: 'stopped by user');
        } else {
          await _finalize(taskId, DispatchTask.statusDone, result: content);
        }
      case AgentTaskOutcome.stopped:
        await _finalize(taskId, DispatchTask.statusError,
            result: content, errorMessage: 'stopped by user');
      case AgentTaskOutcome.error:
        await _finalize(taskId, DispatchTask.statusError,
            result: content,
            errorMessage: c.errorMessage ?? 'unknown error');
    }
  }

  /// 该频道恰有一个在途（running）派发时返回其 id，否则 null。
  Future<String?> _matchSoleInFlight(String channelId) async {
    final running = await _db.listDispatchTasks(
      status: DispatchTask.statusRunning,
      targetChannelId: channelId,
    );
    // 只认内存里登记过的（本 session 发起的），避免误认领历史残留
    final candidates =
        running.where((t) => _inFlightMsgIds.containsKey(t.id)).toList();
    if (candidates.length == 1) return candidates.first.id;
    return null;
  }

  /// 该频道恰有一个迟到观察（超时但仍在跑）的派发时返回其 id，否则 null。
  String? _matchSoleLateWatch(String channelId) {
    final candidates = _lateWatch.entries
        .where((e) => e.value.channelId == channelId)
        .toList();
    return candidates.length == 1 ? candidates.first.key : null;
  }

  /// 超时后仍在对端执行的 turn 到达终态：把迟到结果回传给 She，不让
  /// agent 的最终回复无声消失。完成则把任务升级为 done（errorMessage 里
  /// 仍保留曾超时的事实）；失败/停止则保持 timeout 并补充错误信息。
  Future<void> _onLateCompletion(String taskId, AgentTaskCompletion c) async {
    _lateWatch.remove(taskId);
    final task = await _db.getDispatchTaskById(taskId);
    if (task == null) return;

    LoggerService().info(
      'dispatch $taskId late completion: ${c.outcome} (${task.targetAgentName})',
      tag: 'Dispatch',
    );

    if (c.outcome == AgentTaskOutcome.completed && c.finalMessage != null) {
      final content = c.finalMessage!.content;
      final updated = task.copyWith(
        status: DispatchTask.statusDone,
        resultSummary: _truncate(content, maxSummaryChars),
        completedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _db.updateDispatchTask(updated);
      if (!updated.isChat) {
        await _writeStatusMessage(
            updated, DispatchTask.statusDone, task.statusMessageId);
      }
      await _reportToShe(updated, DispatchTask.statusDone,
          result: content, late: true);
    } else {
      final err = c.errorMessage ?? 'stopped after timeout';
      final updated = task.copyWith(errorMessage: err);
      await _db.updateDispatchTask(updated);
      await _reportToShe(updated, DispatchTask.statusTimeout,
          errorMessage: err, late: true);
    }
  }

  Future<void> _onTimeout(String taskId, Duration timeout) async {
    // 超时只终态化派发记录，底层 turn 仍在对端跑。把归因挪到迟到观察表，
    // 让迟到的完成事件仍能把结果回报给 She。若任务已被先到的完成事件
    // 终态化（竞态），则不做迟到登记。
    final msgId = _inFlightMsgIds[taskId];
    final task = await _db.getDispatchTaskById(taskId);
    if (msgId != null && task != null && !task.isTerminal) {
      _lateWatch[taskId] = (msgId: msgId, channelId: task.targetChannelId);
    }
    await _finalize(taskId, DispatchTask.statusTimeout,
        errorMessage: 'agent did not finish within ${timeout.inMinutes} min');
  }

  /// 终态收尾：落库 → 更新状态消息 → 唤起 She 汇报。幂等。
  Future<void> _finalize(
    String taskId,
    String status, {
    String? result,
    String? errorMessage,
  }) async {
    // 同步防重（无 await 间隙，单线程下原子）
    if (_finalized.contains(taskId)) return;
    _finalized.add(taskId);

    _timers.remove(taskId)?.cancel();
    _inFlightMsgIds.remove(taskId);

    final task = await _db.getDispatchTaskById(taskId);
    if (task == null || task.isTerminal) return;

    final summary = _truncate(result, maxSummaryChars);
    final updated = task.copyWith(
      status: status,
      resultSummary: summary,
      errorMessage: errorMessage,
      completedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.updateDispatchTask(updated);

    LoggerService().info(
      'dispatch $taskId → $status (${task.targetAgentName})',
      tag: 'Dispatch',
    );

    // 链路追踪收尾（App 重启后 _activeSessions 已失，这些调用安全空转）
    final traceId = _traceIdFor(taskId);
    final resultSpanId = TraceService.instance.addSpan(
      traceId: traceId,
      spanType: 'dispatch_result',
      name: status,
    );
    TraceService.instance.endSpan(
      resultSpanId,
      status: status == DispatchTask.statusDone ? 'completed' : 'error',
      error: errorMessage,
      outputData: {
        if (summary != null) 'result_summary': summary,
        if (errorMessage != null) 'error': errorMessage,
      },
    );
    unawaited(TraceService.instance.endTrace(
      traceId,
      status == DispatchTask.statusDone
          ? InferenceStatus.completed
          : InferenceStatus.error,
      error: errorMessage,
      totalTextChars: result?.length ?? 0,
    ));

    // 更新源频道里的状态消息（chat 型无状态卡片，跳过）
    if (!updated.isChat) {
      await _writeStatusMessage(updated, status, task.statusMessageId);
    }

    // 唤起 She 向用户汇报
    await _reportToShe(updated, status,
        result: result, errorMessage: errorMessage);
  }

  // ---------------------------------------------------------------------------
  // 状态消息与结果回传
  // ---------------------------------------------------------------------------

  /// 写（或原地更新）She↔用户 频道里的派发状态消息。
  Future<void> _writeStatusMessage(
    DispatchTask task,
    String status,
    String? messageId,
  ) async {
    final name = task.targetAgentName;
    final text = switch (status) {
      DispatchTask.statusRunning => '📤 已把任务派发给 $name，等待执行结果…',
      DispatchTask.statusDone => '✅ $name 已完成派发的任务',
      DispatchTask.statusTimeout =>
        '⏱️ $name 执行超时，可在与 $name 的会话中查看进度',
      _ => '❌ $name 执行派发任务失败',
    };
    final metadata = _statusMetadata(task, status);

    if (messageId != null && status != DispatchTask.statusRunning) {
      await _db.updateMessage(
          messageId: messageId, content: text, metadata: metadata);
      ChatService().notifyChannelUpdate(task.sourceChannelId);
    } else {
      final msg = Message(
        id: messageId ?? _uuid.v4(),
        content: text,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
        metadata: metadata,
      );
      await ChatService()
          .saveLocalMessage(msg, SheService.sheId, channelId: task.sourceChannelId);
    }
  }

  /// 状态消息的统一 metadata（卡片渲染数据源）。
  Map<String, dynamic> _statusMetadata(DispatchTask task, String status) => {
        'dispatch_status': true,
        'dispatch_task_id': task.id,
        'target_agent_id': task.targetAgentId,
        'target_agent_name': task.targetAgentName,
        'target_channel_id': task.targetChannelId,
        'prompt_preview': _truncate(task.prompt, 100),
        'status': status,
      };

  /// agent 发出 `ui.actionConfirmation`（等待操作确认）时，把审批代理到
  /// She↔用户 频道：写一张可操作的审批卡（[RelayApprovalCard] 渲染，
  /// 应答走 [respondToRelayApproval] 路由回执行频道），task 型同时更新
  /// 状态卡文案指向该卡片。
  ///
  /// 卡片消息 id 取确定性 `appr_<taskId>`：同一任务的后续确认原地更新
  /// （in-band 一个回合任一时刻只有一个未决确认），不产生卡片堆积。
  Future<void> _markAwaitingConfirmation(
      String taskId, Map<String, dynamic> data) async {
    final task = await _db.getDispatchTaskById(taskId);
    if (task == null || task.isTerminal) return;

    // peer 审批的文案在 prompt 字段；直连 ACP 表单则可能是 title/description。
    final rawTitle = (data['title'] as String?) ??
        (data['prompt'] as String?) ??
        (data['description'] as String?) ??
        '';
    final title = rawTitle.trim();

    // 1. 代理审批卡（chat / task 都写）——用户在 She 窗口直接审批，
    //    无需感知中转会话的存在。
    final proxyMsgId = 'appr_$taskId';
    final existing = await _db.getMessageById(proxyMsgId);
    final proxyPayload = <String, dynamic>{
      'confirmation_id': data['confirmation_id'] ?? '',
      'prompt': data['prompt'] ?? data['description'] ?? title,
      'actions': data['actions'] ?? const [],
      'confirmation_context': data['confirmation_context'],
      'agent_id': task.targetAgentId,
      'agent_name': task.targetAgentName,
      'relay_channel_id': task.targetChannelId,
      'dispatch_task_id': task.id,
      'kind': task.kind,
      'status': 'pending',
    };
    final proxyMeta = <String, dynamic>{'relay_approval': proxyPayload};
    if (existing != null) {
      await _db.updateMessage(
        messageId: proxyMsgId,
        content: '⚠️ ${task.targetAgentName} 请求操作确认',
        metadata: proxyMeta,
      );
    } else {
      final proxyMsg = Message(
        id: proxyMsgId,
        content: '⚠️ ${task.targetAgentName} 请求操作确认',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
        metadata: proxyMeta,
      );
      await ChatService().saveLocalMessage(proxyMsg, SheService.sheId,
          channelId: task.sourceChannelId);
    }
    ChatService().notifyChannelUpdate(task.sourceChannelId);

    // 2. task 型状态卡同步文案（chat 型无状态卡）
    if (task.isChat || task.statusMessageId == null) return;
    final metadata = _statusMetadata(task, DispatchTask.statusRunning)
      ..['awaiting_confirmation'] = true
      ..['confirmation_title'] = title;

    await _db.updateMessage(
      messageId: task.statusMessageId!,
      content: title.isNotEmpty
          ? '⏳ ${task.targetAgentName} 等待操作确认：$title\n👉 可在下方审批卡片直接处理'
          : '⏳ ${task.targetAgentName} 等待操作确认\n👉 可在下方审批卡片直接处理',
      metadata: metadata,
    );
    ChatService().notifyChannelUpdate(task.sourceChannelId);
  }

  /// 代理审批卡按钮回调：把用户的选择路由回执行频道（She 绑定中转会话）
  /// 应答 agent 的待决确认。幂等（仅 pending 状态可响应）。
  ///
  /// 应答路径与在中转会话里直接点击完全一致：
  /// - in-band（阻塞式 ACP / peer）：`connection.submitResponse` 解开挂起的
  ///   `canUseTool`，需要执行频道上仍有活动回合，否则判为过期；
  /// - async-confirmation：以一条裁决消息重新唤起 agent（sendMessageToAgent）。
  Future<void> respondToRelayApproval(
    String messageId,
    String actionId,
    String actionLabel,
  ) async {
    final row = await _db.getMessageById(messageId);
    if (row == null) return;
    final meta =
        jsonDecode(row['metadata'] as String? ?? '{}') as Map<String, dynamic>;
    final payload = meta['relay_approval'] as Map<String, dynamic>?;
    if (payload == null || payload['status'] != 'pending') return;

    final sourceChannelId = row['channel_id'] as String;
    final agentId = payload['agent_id'] as String? ?? '';
    final relayChannelId = payload['relay_channel_id'] as String? ?? '';
    final confirmationId = payload['confirmation_id'] as String? ?? '';
    final confirmationContext = payload['confirmation_context'] as String?;

    final agent = await _db.getRemoteAgentById(agentId);
    if (agent == null || relayChannelId.isEmpty || confirmationId.isEmpty) {
      await _resolveProxyCard(messageId, meta, payload, 'failed',
          errorNote: 'agent or relay channel missing');
      ChatService().notifyChannelUpdate(sourceChannelId);
      return;
    }

    // 死回合检测（仅 in-band 必要）：执行频道上已无活动回合且 agent 不支持
    // async-confirmation，则审批不可能再送达——标记过期，不给出假希望。
    final connection = ChatService().getInteractiveConnection(agent);
    final isAsyncAgent = connection?.supportsAsyncConfirmation ?? false;
    if (!isAsyncAgent && ChatService().getActiveTask(relayChannelId) == null) {
      await _resolveProxyCard(messageId, meta, payload, 'expired');
      ChatService().notifyChannelUpdate(sourceChannelId);
      return;
    }

    // 找执行频道里承载该确认的原始消息（其 metadata 需要在应答时更新选中态）；
    // 找不到（流式途中尚未落库）时用合成消息兜底——应答本身不依赖该行存在。
    final relayMessage = await _findRelayConfirmationMessage(
          relayChannelId,
          confirmationId,
        ) ??
        Message(
          id: 'appr_relay_$confirmationId',
          content: '',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          from: MessageFrom(id: agent.id, type: 'agent', name: agent.name),
          type: MessageType.text,
          metadata: {
            'action_confirmation': {
              'confirmation_id': confirmationId,
              'prompt': payload['prompt'],
              'actions': payload['actions'],
              if (confirmationContext != null)
                'confirmation_context': confirmationContext,
            },
          },
        );

    try {
      await ChatService().submitActionConfirmationResponse(
        originalMessage: relayMessage,
        confirmationId: confirmationId,
        selectedActionId: actionId,
        selectedActionLabel: actionLabel,
        agent: agent,
        userId: LocalUserIdentity.id,
        userName: LocalUserIdentity.displayName,
        channelId: relayChannelId,
        confirmationContext: confirmationContext,
      );
    } catch (e, st) {
      LoggerService().error(
        'respondToRelayApproval: submit failed ($confirmationId)',
        tag: 'Dispatch',
        error: e,
        stackTrace: st,
      );
      await _resolveProxyCard(messageId, meta, payload, 'failed',
          errorNote: e.toString());
      ChatService().notifyChannelUpdate(sourceChannelId);
      return;
    }

    LoggerService().info(
      'relay approval answered via She channel: ${agent.name} '
      'confirmation=$confirmationId action=$actionId',
      tag: 'Dispatch',
    );
    await _resolveProxyCard(messageId, meta, payload, 'resolved',
        selectedActionLabel: actionLabel);
    ChatService().notifyChannelUpdate(sourceChannelId);
    ChatService().notifyChannelUpdate(relayChannelId);
  }

  /// 原地更新代理审批卡的终态（resolved / expired / failed）。
  Future<void> _resolveProxyCard(
    String messageId,
    Map<String, dynamic> meta,
    Map<String, dynamic> payload,
    String status, {
    String? selectedActionLabel,
    String? errorNote,
  }) async {
    payload['status'] = status;
    if (selectedActionLabel != null) {
      payload['selected_action_label'] = selectedActionLabel;
    }
    if (errorNote != null) payload['error_note'] = errorNote;
    meta['relay_approval'] = payload;

    final agentName = payload['agent_name'] as String? ?? '';
    final text = switch (status) {
      'resolved' => '✅ 已处理 $agentName 的操作确认：$selectedActionLabel',
      'expired' => '⌛ $agentName 的操作确认已过期（回合已结束）',
      _ => '❌ $agentName 的操作确认处理失败，请到该助手的会话中处理',
    };
    await _db.updateMessage(
        messageId: messageId, content: text, metadata: meta);
  }

  /// 在执行频道里按 confirmation_id 找承载该确认的消息（最新 50 条内）。
  Future<Message?> _findRelayConfirmationMessage(
    String relayChannelId,
    String confirmationId,
  ) async {
    final messages = await ChatService()
        .loadChannelMessages(relayChannelId, limit: 50);
    for (final m in messages.reversed) {
      final ac = m.metadata?['action_confirmation'];
      if (ac is Map && ac['confirmation_id'] == confirmationId) return m;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 确认门（dispatch_confirm agent）
  // ---------------------------------------------------------------------------

  /// 在 She↔用户 频道写入一张派发确认卡（metadata.dispatch_confirm）。
  Future<void> requestConfirmation({
    required String sourceChannelId,
    required RemoteAgent targetAgent,
    required String task,
    required int timeoutMin,
  }) async {
    final msg = Message(
      id: _uuid.v4(),
      content: '⚠️ She 请求把任务派发给 ${targetAgent.name}，等待你的确认',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: 'system', type: 'system', name: 'System'),
      type: MessageType.system,
      metadata: {
        'dispatch_confirm': {
          'agent_id': targetAgent.id,
          'agent_name': targetAgent.name,
          'task': task,
          'timeout_min': timeoutMin,
          'status': 'pending',
        },
      },
    );
    await ChatService()
        .saveLocalMessage(msg, SheService.sheId, channelId: sourceChannelId);
  }

  /// 确认卡按钮回调：确认则直接发起派发（绕过 CLI 的 --confirm 门），
  /// 取消则仅更新卡片状态。幂等（仅 pending 状态可响应）。
  Future<void> respondToConfirm(String messageId, bool approved) async {
    final row = await _db.getMessageById(messageId);
    if (row == null) return;
    final meta =
        jsonDecode(row['metadata'] as String? ?? '{}') as Map<String, dynamic>;
    final payload = meta['dispatch_confirm'] as Map<String, dynamic>?;
    if (payload == null || payload['status'] != 'pending') return;

    final channelId = row['channel_id'] as String;
    final agentName = payload['agent_name'] as String? ?? '';
    payload['status'] = approved ? 'confirmed' : 'cancelled';
    meta['dispatch_confirm'] = payload;

    await _db.updateMessage(
      messageId: messageId,
      content: approved
          ? '✅ 已确认，任务派发给 $agentName'
          : '🚫 已取消派发给 $agentName',
      metadata: meta,
    );
    ChatService().notifyChannelUpdate(channelId);

    if (!approved) return;

    final agentId = payload['agent_id'] as String? ?? '';
    final agent = await _db.getRemoteAgentById(agentId);
    if (agent == null) {
      LoggerService().warning(
          'respondToConfirm: agent $agentId not found', tag: 'Dispatch');
      return;
    }
    // 执行频道由 dispatch 内部确保（She 绑定 DM），旧卡片 payload 里的
    // target_channel_id 字段忽略。
    final result = await dispatch(
      sourceChannelId: channelId,
      targetAgent: agent,
      prompt: payload['task'] as String,
      timeout:
          Duration(minutes: (payload['timeout_min'] as num?)?.toInt() ?? 30),
    );
    if (result['ok'] != true) {
      LoggerService().warning(
          'respondToConfirm: dispatch failed: ${result['error']}',
          tag: 'Dispatch');
    }
  }

  static String _traceIdFor(String taskId) => 'dispatch_$taskId';

  /// 把派发结果注入 She↔用户 频道并唤起 She 汇报。
  ///
  /// She 正在处理用户消息时先避让（轮询等频道空闲），避免并发回合互相
  /// 覆盖 ActiveTask；超过等待上限则只留消息在频道里，由 She 下个回合
  /// 在历史中自然看到。
  Future<void> _reportToShe(
    DispatchTask task,
    String status, {
    String? result,
    String? errorMessage,
    bool late = false,
  }) async {
    final she = await _db.getRemoteAgentById(SheService.sheId);
    if (she == null) {
      LoggerService().warning('She agent not found, skip dispatch report',
          tag: 'Dispatch');
      return;
    }

    // chat 型：告知 She 接力预算消耗（注入本条后 used+1）
    int? relayTurnsUsed;
    if (task.isChat) {
      final recent = await ChatService()
          .loadChannelMessages(task.sourceChannelId, limit: 60);
      relayTurnsUsed = countConsecutiveChatRelays(recent) + 1;
    }

    final content = _buildReportContent(task, status,
        result: result,
        errorMessage: errorMessage,
        late: late,
        relayTurnsUsed: relayTurnsUsed);
    final resultMsg = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: senderId, type: 'user', name: senderName),
      to: MessageFrom(id: she.id, type: 'agent', name: she.name),
      type: MessageType.text,
      metadata: task.isChat
          ? {
              'she_chat_relay': true,
              'dispatch_task_id': task.id,
              'status': status,
            }
          : {
              'dispatch_result': true,
              'dispatch_task_id': task.id,
              'status': status,
            },
    );

    // 等待 She 频道空闲（最长 120s）
    const maxWait = Duration(seconds: 120);
    final deadline = DateTime.now().add(maxWait);
    while (ChatService().isChannelBusy(task.sourceChannelId) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
    }

    await ChatService()
        .saveLocalMessage(resultMsg, she.id, channelId: task.sourceChannelId);

    if (ChatService().isChannelBusy(task.sourceChannelId)) {
      LoggerService().warning(
        'She channel still busy after ${maxWait.inSeconds}s; '
        'result message left in channel history (task ${task.id})',
        tag: 'Dispatch',
      );
      return;
    }

    unawaited(ChatService()
        .sendMessageToAgent(
      content: resultMsg.content,
      agent: she,
      userId: senderId,
      userName: senderName,
      channelId: task.sourceChannelId,
      existingUserMessage: resultMsg,
    )
        .catchError((Object e, StackTrace st) {
      LoggerService().error(
        'failed to invoke She for dispatch report (task ${task.id})',
        tag: 'Dispatch',
        error: e,
        stackTrace: st,
      );
      return null;
    }));
  }

  String _buildReportContent(
    DispatchTask task,
    String status, {
    String? result,
    String? errorMessage,
    bool late = false,
    int? relayTurnsUsed,
  }) {
    if (task.isChat) {
      return _buildChatReportContent(task, status,
          result: result,
          errorMessage: errorMessage,
          late: late,
          relayTurnsUsed: relayTurnsUsed ?? 1);
    }

    final buf = StringBuffer()
      ..writeln('[Dispatch Result — ${task.id}]')
      ..writeln('Agent: ${task.targetAgentName} (${task.targetAgentId})')
      ..writeln('Task: ${_truncate(task.prompt, 300)}');

    switch (status) {
      case DispatchTask.statusDone:
        buf.writeln('Status: completed');
        if (late) {
          buf.writeln(
              'Note: this result arrived AFTER the dispatch had already been '
              'reported as timed out — it is the agent\'s real final reply.');
        }
        buf
          ..writeln('--- Agent\'s reply ---')
          ..writeln(_truncate(result ?? '(empty reply)', maxResultChars))
          ..writeln('--- End of reply ---')
          ..writeln(
              'Summarize this for your master in your own voice: what was done '
              'and the key result. Do NOT call agents.dispatch again for this '
              'result unless your master asks.');
      case DispatchTask.statusTimeout:
        if (late) {
          buf
            ..writeln('Status: failed after timeout')
            ..writeln(
                'The agent kept running past the timeout but then stopped or '
                'failed: ${_truncate(errorMessage ?? 'unknown', 300)}. Tell '
                'your master the late outcome in one sentence. Do NOT call '
                'agents.dispatch again unless your master asks.');
        } else {
          buf
            ..writeln('Status: timeout')
            ..writeln(
                'The agent did not finish within the timeout. It may still be '
                'working in its own channel. Tell your master, and suggest '
                'checking that channel directly. Do NOT call agents.dispatch '
                'again unless your master asks.');
        }
      default:
        buf.writeln('Status: failed');
        if (errorMessage != null) {
          buf.writeln('Error: ${_truncate(errorMessage, 500)}');
        }
        if (result != null && result.isNotEmpty) {
          buf
            ..writeln('--- Partial reply ---')
            ..writeln(_truncate(result, maxResultChars))
            ..writeln('--- End of partial reply ---');
        }
        buf.writeln(
            'Tell your master the dispatch failed, explain why in one sentence, '
            'and suggest a next step (retry / assign another agent / handle it '
            'yourself). Do NOT call agents.dispatch again unless your master asks.');
    }
    return buf.toString();
  }

  /// chat 型转发的注入模板：以 [Agent Reply] 呈现对方回复，引导 She 决定
  /// 继续对聊还是向用户汇报，并显式告知接力预算消耗。
  String _buildChatReportContent(
    DispatchTask task,
    String status, {
    String? result,
    String? errorMessage,
    bool late = false,
    required int relayTurnsUsed,
  }) {
    final buf = StringBuffer()
      ..writeln('[Agent Reply — ${task.targetAgentName} (${task.targetAgentId})]')
      ..writeln('Your message: ${_truncate(task.prompt, 300)}');

    switch (status) {
      case DispatchTask.statusDone:
        if (late) {
          buf.writeln('Note: this reply arrived AFTER the relay had already '
              'been reported as timed out — it is the agent\'s real final reply.');
        }
        buf
          ..writeln('--- ${task.targetAgentName}\'s reply ---')
          ..writeln(_truncate(result ?? '(empty reply)', maxResultChars))
          ..writeln('--- End of reply ---');
      case DispatchTask.statusTimeout:
        buf.writeln(late
            ? 'Status: failed after timeout — ${_truncate(errorMessage ?? 'unknown', 300)}'
            : 'Status: timeout — the agent did not reply within the limit. '
                'It may still be working in its own channel; suggest your '
                'master check that channel directly.');
      default:
        buf.writeln('Status: failed');
        if (errorMessage != null) {
          buf.writeln('Error: ${_truncate(errorMessage, 500)}');
        }
        if (result != null && result.isNotEmpty) {
          buf
            ..writeln('--- Partial reply ---')
            ..writeln(_truncate(result, maxResultChars))
            ..writeln('--- End of partial reply ---');
        }
    }

    buf.writeln('Relay turns used: $relayTurnsUsed/$maxChatRelayTurns '
        '(consecutive agent relays without new input from your master).');
    if (relayTurnsUsed >= maxChatRelayTurns) {
      buf.writeln('The budget is now exhausted — further agents.chat calls '
          'will be rejected. Summarize the conversation for your master and '
          'let them decide how to proceed.');
    } else {
      buf.writeln('Decide: relay your next message via agents.chat to '
          'continue the conversation, or report back to your master in your '
          'own voice. Do NOT relay the reply verbatim back and forth.');
    }
    return buf.toString();
  }

  static String? _truncate(String? s, int max) {
    if (s == null) return null;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…(truncated)';
  }
}
