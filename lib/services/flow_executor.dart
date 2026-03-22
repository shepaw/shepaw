import 'dart:async';

import '../models/channel.dart';
import '../models/planning_models.dart';
import '../models/remote_agent.dart';
import 'acp_agent_connection.dart';
import 'logger_service.dart';

// ---------------------------------------------------------------------------
// Callback type aliases
// ---------------------------------------------------------------------------

typedef ProcessGroupAgentFn = Future<void> Function({
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
  bool isAdmin,
  Map<String, dynamic>? messageVersion,
  List<ChannelMember> channelMembers,
  RemoteAgent? adminAgent,
  String? customSystemPrompt,
  bool isLoopSummarize,
  bool isAbortSummarize,
  int? loopRound,
  String mentionMode,
  bool planningMode,
  ExecutionPlan? approvedPlan,
  bool isPlanRevise,
  List<String> failedAgentNames,
  ACPCancellationToken? acpCancellationToken,
  void Function(String agentId, String agentName, String chunk)? onStreamChunk,
  void Function(String agentId, String agentName, bool skipped)? onAgentDone,
  Future<Map<String, dynamic>?> Function(
    String agentId, String agentName, String interactionType, Map<String, dynamic> data,
  )? onInteractionRequest,
  bool isFlowStageReview,
  int? flowStageIndex,
});

typedef LoadHistoryFn = Future<List<dynamic>> Function(
    String channelId, {String? excludeMessageId});

typedef UpdateTaskBoardFn = Future<void> Function(
    String channelId, String msgId, ExecutionPlan plan);

typedef CreateSystemMessageFn = Future<void> Function(
    String channelId, String content);

typedef NotifyTaskBoardFn = Future<void> Function(
    String agentId, String agentName, String msgId, ExecutionPlan plan);

typedef AgentStartFn = void Function(String agentId, String agentName);
typedef AgentDoneFn = void Function(String agentId, String agentName, bool skipped);

// ---------------------------------------------------------------------------
// FlowExecutorContext — dependency injection container
// ---------------------------------------------------------------------------

class FlowExecutorContext {
  final String channelId;
  final String originalUserContent;
  final String userId;
  final String userName;
  final String groupName;
  final String groupDescription;
  final List<RemoteAgent> allAgents;
  final RemoteAgent adminAgent;
  final List<ChannelMember> channelMembers;
  final String? customSystemPrompt;
  final String mentionMode;
  final Map<String, dynamic>? messageVersion;
  final String userMessageId;
  final String taskBoardMsgId;
  final ACPCancellationToken? acpCancellationToken;

  FlowExecutorContext({
    required this.channelId,
    required this.originalUserContent,
    required this.userId,
    required this.userName,
    required this.groupName,
    required this.groupDescription,
    required this.allAgents,
    required this.adminAgent,
    required this.channelMembers,
    this.customSystemPrompt,
    required this.mentionMode,
    this.messageVersion,
    required this.userMessageId,
    required this.taskBoardMsgId,
    this.acpCancellationToken,
  });
}

// ---------------------------------------------------------------------------
// FlowExecutor
// ---------------------------------------------------------------------------

class FlowExecutor {
  final FlowPlan plan;
  final FlowExecutorContext ctx;

  final ProcessGroupAgentFn processGroupAgent;
  final LoadHistoryFn loadHistory;
  final UpdateTaskBoardFn updateTaskBoard;
  final CreateSystemMessageFn createSystemMessage;
  final NotifyTaskBoardFn? notifyTaskBoard;
  final AgentStartFn? onAgentStart;
  final AgentDoneFn? onAgentDone;
  final void Function(String agentId, String agentName, String chunk)? onStreamChunk;
  final Future<Map<String, dynamic>?> Function(
    String agentId, String agentName, String interactionType, Map<String, dynamic> data,
  )? onInteractionRequest;

  bool _isPaused = false;
  Completer<void>? _resumeCompleter;

  // Step-level user interaction waiting: when a step triggers a non-blocking
  // form/file_upload interaction, the executor pauses here until the user
  // submits the form (controller calls resumeWithInteractionResult).
  Completer<Map<String, dynamic>?>? _stepInteractionCompleter;

  // Accumulated flattened ExecutionPlan (kept in sync for TaskBoard UI)
  late ExecutionPlan _flatPlan;

  FlowExecutor({
    required this.plan,
    required this.ctx,
    required this.processGroupAgent,
    required this.loadHistory,
    required this.updateTaskBoard,
    required this.createSystemMessage,
    this.notifyTaskBoard,
    this.onAgentStart,
    this.onAgentDone,
    this.onStreamChunk,
    this.onInteractionRequest,
  }) {
    _flatPlan = plan.toExecutionPlan();
  }

  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  /// Called by the controller when the user submits a form/file-upload that
  /// was triggered by a flow step.  Resumes the suspended executor so it can
  /// proceed to the next stage.
  void resumeWithInteractionResult(Map<String, dynamic>? result) {
    LoggerService().info('FlowExecutor.resumeWithInteractionResult result=$result', tag: 'FlowExecutor');
    if (_stepInteractionCompleter != null && !_stepInteractionCompleter!.isCompleted) {
      _stepInteractionCompleter!.complete(result);
    }
  }

  Future<void> execute() async {
    LoggerService().info('FlowExecutor.execute() start, stages=${plan.stages.length}', tag: 'FlowExecutor');

    for (int i = 0; i < plan.stages.length; i++) {
      // Respect cancellation between stages
      if (ctx.acpCancellationToken?.isCancelled == true) {
        LoggerService().info('FlowExecutor cancelled before stage $i', tag: 'FlowExecutor');
        await _runAbortSummarize();
        return;
      }

      // Respect pause before advancing
      if (_isPaused) {
        LoggerService().info('FlowExecutor paused before stage $i, waiting for resume', tag: 'FlowExecutor');
        _resumeCompleter = Completer<void>();
        await _resumeCompleter!.future;
        _resumeCompleter = null;
      }

      final stage = plan.stages[i];
      stage.status = FlowStageStatus.running;
      _syncTaskBoard();

      await _executeStage(stage);

      if (stage.hasFailed) {
        stage.status = FlowStageStatus.failed;
        _syncTaskBoard();
        LoggerService().warning('FlowExecutor stage ${stage.stageId} has failed steps, aborting remaining stages', tag: 'FlowExecutor');
        await _runAbortSummarize();
        return;
      } else {
        stage.status = FlowStageStatus.done;
      }
      _syncTaskBoard();

      // Admin stage review (between stages, not after the last one)
      if (i < plan.stages.length - 1) {
        final shouldContinue = await _invokeAdminStageReview(stageIndex: i);
        if (!shouldContinue) {
          LoggerService().info('FlowExecutor aborted by Admin after stage $i', tag: 'FlowExecutor');
          return;
        }
      }
    }

    await _runFinalSummarize();
    LoggerService().info('FlowExecutor.execute() complete', tag: 'FlowExecutor');
  }

  // ---------------------------------------------------------------------------
  // Stage execution — parallel steps within stage
  // ---------------------------------------------------------------------------

  Future<void> _executeStage(FlowStage stage) async {
    LoggerService().info('FlowExecutor._executeStage ${stage.stageId} (${stage.label}), steps=${stage.steps.length}', tag: 'FlowExecutor');

    // Mark all steps as in-progress before launching
    for (final step in stage.steps) {
      if (step.status == TaskStatus.pending) {
        step.status = TaskStatus.inProgress;
      }
    }
    _syncTaskBoard();

    // Execute steps in parallel (skip already-skipped steps)
    await Future.wait(stage.steps
        .where((s) => s.status != TaskStatus.skipped)
        .map((step) => _executeStep(step)));

    // Mark remaining pending/inProgress as done if not already failed/skipped
    for (final step in stage.steps) {
      if (step.status == TaskStatus.inProgress) {
        step.status = TaskStatus.done;
      }
    }
    _syncTaskBoard();
  }

  Future<void> _executeStep(FlowStep step) async {
    LoggerService().info('FlowExecutor._executeStep ${step.stepId} → agent=${step.agent}', tag: 'FlowExecutor');

    final agent = _resolveAgent(step.agent);
    if (agent == null) {
      LoggerService().warning('FlowExecutor: agent "${step.agent}" not found, skipping step ${step.stepId}', tag: 'FlowExecutor');
      step.status = TaskStatus.skipped;
      _syncTaskBoard();
      return;
    }

    final history = await loadHistory(ctx.channelId, excludeMessageId: ctx.userMessageId);

    // Pre-create the interaction completer so it is ready before processGroupAgent
    // starts.  This avoids a race where the user submits the form between the
    // moment onInteractionRequest returns _non_blocking and the moment we create
    // the Completer below — which would cause resumeWithInteractionResult to
    // be a no-op and leave the executor stalled forever.
    final interactionCompleter = Completer<Map<String, dynamic>?>();
    _stepInteractionCompleter = interactionCompleter;
    bool stepTriggeredNonBlocking = false;

    Future<Map<String, dynamic>?> wrappedInteraction(
      String agentId, String agentName, String interactionType, Map<String, dynamic> data,
    ) async {
      final result = await onInteractionRequest?.call(agentId, agentName, interactionType, data);
      if (result?['_non_blocking'] == true) {
        stepTriggeredNonBlocking = true;
      }
      return result;
    }

    try {
      await processGroupAgent(
        agent: agent,
        channelId: ctx.channelId,
        content: step.instruction,
        userId: ctx.userId,
        userName: ctx.userName,
        groupName: ctx.groupName,
        groupDescription: ctx.groupDescription,
        allAgents: ctx.allAgents,
        historyMessages: history,
        mentionedAgentIds: [agent.id],
        isFirstMessage: false,
        messageVersion: ctx.messageVersion,
        channelMembers: ctx.channelMembers,
        adminAgent: ctx.adminAgent,
        customSystemPrompt: ctx.customSystemPrompt,
        mentionMode: ctx.mentionMode,
        acpCancellationToken: ctx.acpCancellationToken,
        onStreamChunk: onStreamChunk,
        onAgentDone: onAgentDone,
        onInteractionRequest: onInteractionRequest != null ? wrappedInteraction : null,
      );
      step.status = TaskStatus.done;
    } catch (e) {
      LoggerService().error('FlowExecutor step ${step.stepId} failed', tag: 'FlowExecutor', error: e);
      step.status = TaskStatus.failed;
    }
    _syncTaskBoard();

    // If the step triggered a non-blocking user interaction (form / file_upload),
    // wait for the user to submit before continuing to the next stage.
    // The controller calls resumeWithInteractionResult() when the user submits.
    // The completer was created before processGroupAgent ran, so any submit that
    // arrives between onInteractionRequest returning and here will already have
    // completed it — we won't stall.
    if (stepTriggeredNonBlocking && ctx.acpCancellationToken?.isCancelled != true) {
      LoggerService().info('FlowExecutor step ${step.stepId} waiting for user interaction', tag: 'FlowExecutor');
      if (!interactionCompleter.isCompleted) {
        await interactionCompleter.future.timeout(
          const Duration(minutes: 30),
          onTimeout: () => null,
        );
      }
      _stepInteractionCompleter = null;
      LoggerService().info('FlowExecutor step ${step.stepId} user interaction completed, resuming', tag: 'FlowExecutor');
    } else {
      _stepInteractionCompleter = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Admin inter-stage review
  // ---------------------------------------------------------------------------

  Future<bool> _invokeAdminStageReview({required int stageIndex}) async {
    LoggerService().info('FlowExecutor._invokeAdminStageReview after stage $stageIndex', tag: 'FlowExecutor');

    final history = await loadHistory(ctx.channelId, excludeMessageId: ctx.userMessageId);
    String adminResponseContent = '';

    onAgentStart?.call(ctx.adminAgent.id, ctx.adminAgent.name);
    try {
      await processGroupAgent(
        agent: ctx.adminAgent,
        channelId: ctx.channelId,
        content: ctx.originalUserContent,
        userId: ctx.userId,
        userName: ctx.userName,
        groupName: ctx.groupName,
        groupDescription: ctx.groupDescription,
        allAgents: ctx.allAgents,
        historyMessages: history,
        mentionedAgentIds: const [],
        isFirstMessage: false,
        isAdmin: true,
        messageVersion: ctx.messageVersion,
        channelMembers: ctx.channelMembers,
        customSystemPrompt: ctx.customSystemPrompt,
        mentionMode: ctx.mentionMode,
        acpCancellationToken: ctx.acpCancellationToken,
        onStreamChunk: (agentId, agentName, chunk) {
          adminResponseContent += chunk;
          onStreamChunk?.call(agentId, agentName, chunk);
        },
        onAgentDone: onAgentDone,
        onInteractionRequest: onInteractionRequest,
        isFlowStageReview: true,
        flowStageIndex: stageIndex,
      );
    } catch (e) {
      LoggerService().error('FlowExecutor admin stage review error', tag: 'FlowExecutor', error: e);
    }

    // Parse any [FLOW_CTRL] directive from the Admin response
    final ctrl = FlowCtrlCommand.tryParse(adminResponseContent);
    if (ctrl == null) {
      // No directive — automatically continue to next stage
      return true;
    }

    return await _applyFlowCtrl(ctrl, stageIndex: stageIndex);
  }

  // ---------------------------------------------------------------------------
  // Apply FlowCtrl directive
  // ---------------------------------------------------------------------------

  Future<bool> _applyFlowCtrl(FlowCtrlCommand cmd, {required int stageIndex}) async {
    LoggerService().info('FlowExecutor._applyFlowCtrl action=${cmd.action}', tag: 'FlowExecutor');

    switch (cmd.action) {
      case FlowCtrlAction.pause:
        _isPaused = true;
        return true;

      case FlowCtrlAction.resume:
        _isPaused = false;
        _resumeCompleter?.complete();
        return true;

      case FlowCtrlAction.skipStep:
        if (cmd.targetStepId != null) {
          for (final stage in plan.stages) {
            for (final step in stage.steps) {
              if (step.stepId == cmd.targetStepId) {
                step.status = TaskStatus.skipped;
              }
            }
          }
          _syncTaskBoard();
        }
        return true;

      case FlowCtrlAction.retryTask:
        if (cmd.targetStepId != null) {
          for (final stage in plan.stages) {
            for (final step in stage.steps) {
              if (step.stepId == cmd.targetStepId &&
                  step.status == TaskStatus.failed) {
                step.status = TaskStatus.pending;
              }
            }
          }
          // Re-execute stages that have pending steps
          for (final stage in plan.stages) {
            if (stage.steps.any((s) => s.status == TaskStatus.pending)) {
              stage.status = FlowStageStatus.pending;
              await _executeStage(stage);
            }
          }
        }
        return true;

      case FlowCtrlAction.injectMessage:
        if (cmd.message != null && cmd.message!.isNotEmpty) {
          await createSystemMessage(ctx.channelId,
              '[SYSTEM] Admin 注入消息: ${cmd.message}');
        }
        return true;

      case FlowCtrlAction.abort:
        await _runAbortSummarize();
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Summarize helpers
  // ---------------------------------------------------------------------------

  Future<void> _runAbortSummarize() async {
    LoggerService().info('FlowExecutor._runAbortSummarize', tag: 'FlowExecutor');
    final history = await loadHistory(ctx.channelId, excludeMessageId: ctx.userMessageId);
    onAgentStart?.call(ctx.adminAgent.id, ctx.adminAgent.name);
    try {
      await processGroupAgent(
        agent: ctx.adminAgent,
        channelId: ctx.channelId,
        content: ctx.originalUserContent,
        userId: ctx.userId,
        userName: ctx.userName,
        groupName: ctx.groupName,
        groupDescription: ctx.groupDescription,
        allAgents: ctx.allAgents,
        historyMessages: history,
        mentionedAgentIds: const [],
        isFirstMessage: false,
        isAdmin: true,
        isLoopSummarize: true,
        isAbortSummarize: true,
        messageVersion: ctx.messageVersion,
        channelMembers: ctx.channelMembers,
        customSystemPrompt: ctx.customSystemPrompt,
        mentionMode: ctx.mentionMode,
        acpCancellationToken: ctx.acpCancellationToken,
        onStreamChunk: onStreamChunk,
        onAgentDone: onAgentDone,
        onInteractionRequest: onInteractionRequest,
      );
    } catch (e) {
      LoggerService().error('FlowExecutor abort-summarize error', tag: 'FlowExecutor', error: e);
    }
  }

  Future<void> _runFinalSummarize() async {
    LoggerService().info('FlowExecutor._runFinalSummarize', tag: 'FlowExecutor');
    final history = await loadHistory(ctx.channelId, excludeMessageId: ctx.userMessageId);
    onAgentStart?.call(ctx.adminAgent.id, ctx.adminAgent.name);
    try {
      await processGroupAgent(
        agent: ctx.adminAgent,
        channelId: ctx.channelId,
        content: ctx.originalUserContent,
        userId: ctx.userId,
        userName: ctx.userName,
        groupName: ctx.groupName,
        groupDescription: ctx.groupDescription,
        allAgents: ctx.allAgents,
        historyMessages: history,
        mentionedAgentIds: const [],
        isFirstMessage: false,
        isAdmin: true,
        isLoopSummarize: true,
        messageVersion: ctx.messageVersion,
        channelMembers: ctx.channelMembers,
        customSystemPrompt: ctx.customSystemPrompt,
        mentionMode: ctx.mentionMode,
        acpCancellationToken: ctx.acpCancellationToken,
        onStreamChunk: onStreamChunk,
        onAgentDone: onAgentDone,
        onInteractionRequest: onInteractionRequest,
      );
    } catch (e) {
      LoggerService().error('FlowExecutor final-summarize error', tag: 'FlowExecutor', error: e);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  RemoteAgent? _resolveAgent(String name) {
    return ctx.allAgents.cast<RemoteAgent?>().firstWhere(
          (a) => a!.name == name,
          orElse: () => null,
        );
  }

  /// Fire-and-forget: sync TaskBoard UI with current flat plan state.
  void _syncTaskBoard() {
    _flatPlan = plan.toExecutionPlan();
    // updateTaskBoard is async but we don't need to await it here
    updateTaskBoard(ctx.channelId, ctx.taskBoardMsgId, _flatPlan).catchError((e) {
      LoggerService().warning('FlowExecutor _syncTaskBoard error: $e', tag: 'FlowExecutor');
    });
    if (notifyTaskBoard != null) {
      notifyTaskBoard!(
        ctx.adminAgent.id,
        ctx.adminAgent.name,
        ctx.taskBoardMsgId,
        _flatPlan,
      ).catchError((e) {
        LoggerService().warning('FlowExecutor _syncTaskBoard notify error: $e', tag: 'FlowExecutor');
      });
    }
  }
}
