import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/dispatch_task.dart';
import '../../models/inference_log_entry.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../chat_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../messaging/agent_messaging_service.dart';
import '../she_service.dart';
import '../trace_service.dart';

/// She 单聊任务派发服务：登记 → 跟踪 → 回传闭环。
///
/// 流程：
/// 1. [dispatch] 落库派发记录，在 She↔用户 频道写状态消息，
///    以 She 身份把任务消息存进目标 agent 的 DM 频道并 fire-and-forget 发送
///    （严禁同步等待对方完成——会死锁 She 自己的工具循环）。
/// 2. 订阅 [ChatService.agentTaskCompletionStream]，按 `replyTo == 任务消息id`
///    精确匹配（失败路径无 replyTo 时退化为"该频道唯一在途派发"）。
/// 3. 终态后更新状态消息，并把结果以合成消息注入 She↔用户 频道、重新唤起
///    She，由她用自己的口吻向用户汇报。
///
/// 防回环：注入消息的 metadata 带 `dispatch_result: true`；完成事件只按在途
/// 派发匹配，She 汇报自身产生的完成事件不会被认领。
class DispatchService {
  static final DispatchService instance = DispatchService._();
  DispatchService._();

  /// 注入消息的虚拟发送者身份
  static const String senderId = 'dispatch-service';
  static const String senderName = 'Dispatch';

  /// 同一 agent 的在途派发上限
  static const int maxInFlightPerAgent = 3;

  /// 回传给 She 的结果正文最大字符数（防超长上下文）
  static const int maxResultChars = 6000;

  /// DB 里 result_summary 的最大字符数
  static const int maxSummaryChars = 500;

  final LocalDatabaseService _db = LocalDatabaseService();
  final Uuid _uuid = const Uuid();

  StreamSubscription<AgentTaskCompletion>? _sub;
  final Map<String, Timer> _timers = {};

  /// 在途派发：dispatchTaskId -> 任务消息 id（replyTo 精确匹配用）
  final Map<String, String> _inFlightMsgIds = {};

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

  /// 把任务 [prompt] 派发给 [targetAgent]（在其 [targetChannelId] DM 频道执行），
  /// 结果回传到 [sourceChannelId]（She↔用户 频道）。
  Future<Map<String, dynamic>> dispatch({
    required String sourceChannelId,
    required RemoteAgent targetAgent,
    required String targetChannelId,
    required String prompt,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    ensureStarted();

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
    );
    await _db.createDispatchTask(task);

    // 链路追踪：派发生命周期（traceRole = she_dispatch）
    final traceId = _traceIdFor(taskId);
    TraceService.instance.beginTrace(
      sessionId: traceId,
      agentId: targetAgent.id,
      agentName: targetAgent.name,
      channelId: sourceChannelId,
      executionMode: 'she_dispatch',
      userMessage: prompt,
      traceRole: 'she_dispatch',
    );
    TraceService.instance.addSpan(
      traceId: traceId,
      spanType: 'dispatch_decision',
      name: 'dispatch_created',
      inputData: {
        'dispatch_task_id': taskId,
        'target_channel_id': targetChannelId,
        'timeout_min': timeout.inMinutes,
      },
    );

    // 2. She↔用户 频道的状态消息（用户可见；完成后原地更新）
    final statusMsgId = _uuid.v4();
    await _writeStatusMessage(task, DispatchTask.statusRunning, statusMsgId);

    // 3. 以 She 身份构造任务消息并存入目标频道。
    //    必须自己保存：sendMessageToAgent 见到 existingUserMessage 会跳过保存。
    final userMsg = Message(
      id: _uuid.v4(),
      content: prompt,
      timestampMs: now,
      from: MessageFrom(
          id: SheService.sheId, type: 'user', name: SheService.sheName),
      to: MessageFrom(
          id: targetAgent.id, type: 'agent', name: targetAgent.name),
      type: MessageType.text,
      metadata: {'dispatch_task_id': taskId, 'is_dispatch_task': true},
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
      // 审批中转：agent 等待操作确认时更新状态卡（用户打开目标频道后
      // UI 回调会接管，此处仅在频道未打开时生效）
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
      'dispatched task $taskId → ${targetAgent.name} [channel: $targetChannelId]',
      tag: 'Dispatch',
    );

    return {
      'ok': true,
      'dispatch_task_id': taskId,
      'target': targetAgent.name,
      'target_channel_id': targetChannelId,
      'status': DispatchTask.statusRunning,
      'note': 'The agent is now working. Its result will be reported back into '
          'THIS conversation automatically when finished — do NOT poll '
          'agents.messages and do NOT dispatch the same task twice.',
    };
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
    }

    // 退化匹配：失败路径的系统消息没有 replyTo —— 该频道恰好只有一个在途派发时才认领
    taskId ??= await _matchSoleInFlight(c.channelId);
    if (taskId == null) return;

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

  Future<void> _onTimeout(String taskId, Duration timeout) async {
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

    // 更新源频道里的状态消息
    await _writeStatusMessage(updated, status, task.statusMessageId);

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

  /// agent 发出 `ui.actionConfirmation`（等待操作确认）时更新状态卡。
  Future<void> _markAwaitingConfirmation(
      String taskId, Map<String, dynamic> data) async {
    final task = await _db.getDispatchTaskById(taskId);
    if (task == null || task.isTerminal || task.statusMessageId == null) return;

    final title = (data['title'] as String?)?.trim().isNotEmpty == true
        ? data['title'] as String
        : (data['description'] as String? ?? '');
    final metadata = _statusMetadata(task, DispatchTask.statusRunning)
      ..['awaiting_confirmation'] = true
      ..['confirmation_title'] = title;

    await _db.updateMessage(
      messageId: task.statusMessageId!,
      content: title.isNotEmpty
          ? '⏳ ${task.targetAgentName} 等待操作确认：$title'
          : '⏳ ${task.targetAgentName} 等待操作确认',
      metadata: metadata,
    );
    ChatService().notifyChannelUpdate(task.sourceChannelId);
  }

  // ---------------------------------------------------------------------------
  // 确认门（dispatch_confirm agent）
  // ---------------------------------------------------------------------------

  /// 在 She↔用户 频道写入一张派发确认卡（metadata.dispatch_confirm）。
  Future<void> requestConfirmation({
    required String sourceChannelId,
    required RemoteAgent targetAgent,
    required String targetChannelId,
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
          'target_channel_id': targetChannelId,
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
    final result = await dispatch(
      sourceChannelId: channelId,
      targetAgent: agent,
      targetChannelId: payload['target_channel_id'] as String,
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
  }) async {
    final she = await _db.getRemoteAgentById(SheService.sheId);
    if (she == null) {
      LoggerService().warning('She agent not found, skip dispatch report',
          tag: 'Dispatch');
      return;
    }

    final content = _buildReportContent(task, status,
        result: result, errorMessage: errorMessage);
    final resultMsg = Message(
      id: _uuid.v4(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      from: MessageFrom(id: senderId, type: 'user', name: senderName),
      to: MessageFrom(id: she.id, type: 'agent', name: she.name),
      type: MessageType.text,
      metadata: {
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
  }) {
    final buf = StringBuffer()
      ..writeln('[Dispatch Result — ${task.id}]')
      ..writeln('Agent: ${task.targetAgentName} (${task.targetAgentId})')
      ..writeln('Task: ${_truncate(task.prompt, 300)}');

    switch (status) {
      case DispatchTask.statusDone:
        buf.writeln('Status: completed');
        buf
          ..writeln('--- Agent\'s reply ---')
          ..writeln(_truncate(result ?? '(empty reply)', maxResultChars))
          ..writeln('--- End of reply ---')
          ..writeln(
              'Summarize this for your master in your own voice: what was done '
              'and the key result. Do NOT call agents.dispatch again for this '
              'result unless your master asks.');
      case DispatchTask.statusTimeout:
        buf
          ..writeln('Status: timeout')
          ..writeln(
              'The agent did not finish within the timeout. It may still be '
              'working in its own channel. Tell your master, and suggest '
              'checking that channel directly. Do NOT call agents.dispatch '
              'again unless your master asks.');
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

  static String? _truncate(String? s, int max) {
    if (s == null) return null;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…(truncated)';
  }
}
