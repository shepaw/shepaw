import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/workflow_models.dart';
import '../../services/local_database_service.dart';
import '../../services/workflow/workflow_service.dart';
import '../action_confirmation_buttons.dart';
import 'workflow_step_tile.dart';

/// A floating panel shown above the chat input area during workflow execution.
///
/// - **Pending approval**: shows approve/reject buttons
/// - **Collapsed**: single-row showing title + progress + expand/close buttons
/// - **Expanded**: scrollable list of stages and steps with real-time status
///
/// Listens to [WorkflowService.watchWorkflow] for live updates.
class WorkflowProgressPanel extends StatefulWidget {
  final String workflowId;
  final VoidCallback? onDismiss;
  final void Function(bool approved, {String? feedback})? onApprovalResponse;
  final WorkflowPeerApprovalPending? pendingPeerApproval;
  final void Function(String messageId)? onScrollToApproval;
  final void Function(
    String confirmationId,
    String actionId,
    String actionLabel,
  )? onPeerApprovalAction;

  const WorkflowProgressPanel({
    super.key,
    required this.workflowId,
    this.onDismiss,
    this.onApprovalResponse,
    this.pendingPeerApproval,
    this.onScrollToApproval,
    this.onPeerApprovalAction,
  });

  @override
  State<WorkflowProgressPanel> createState() => _WorkflowProgressPanelState();
}

class _WorkflowProgressPanelState extends State<WorkflowProgressPanel>
    with SingleTickerProviderStateMixin {
  late final WorkflowService _workflowService;
  WorkflowExecution? _execution;
  bool _expanded = false;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _workflowService = WorkflowService(db: LocalDatabaseService());
    _load();
    _sub = _workflowService.watchWorkflow(widget.workflowId).listen((exec) {
      if (mounted && exec != null) {
        setState(() => _execution = exec);
      }
    });
  }

  @override
  void didUpdateWidget(WorkflowProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workflowId != widget.workflowId) {
      _sub?.cancel();
      _load();
      _sub = _workflowService.watchWorkflow(widget.workflowId).listen((exec) {
        if (mounted && exec != null) {
          setState(() => _execution = exec);
        }
      });
    }
    if (widget.pendingPeerApproval != null &&
        oldWidget.pendingPeerApproval?.stepId !=
            widget.pendingPeerApproval?.stepId) {
      setState(() => _expanded = true);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final exec =
        await _workflowService.getWorkflowExecutionWithSteps(widget.workflowId);
    if (mounted && exec != null) {
      setState(() => _execution = exec);
    }
  }

  @override
  Widget build(BuildContext context) {
    final exec = _execution;
    if (exec == null) return const SizedBox.shrink();

    final isPendingApproval = exec.status == WorkflowStatus.pendingApproval;
    final allDone = exec.status == WorkflowStatus.completed;
    final failed = exec.status == WorkflowStatus.failed;
    final pendingApproval = widget.pendingPeerApproval;
    final accentColor = isPendingApproval
        ? Colors.orange
        : pendingApproval != null
            ? Colors.deepOrange
            : allDone
            ? Colors.green
            : failed
                ? Colors.red
                : Colors.blue;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.04),
        border: Border(
          top: BorderSide(color: accentColor.withOpacity(0.3), width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header (always visible)
          _buildHeader(exec, accentColor, allDone, failed, pendingApproval),
          // Scrollable body — peer approval prompts can be very long (diffs, etc.)
          if (isPendingApproval ||
              pendingApproval != null ||
              (!isPendingApproval && _expanded))
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isPendingApproval) _buildApprovalButtons(),
                    if (!isPendingApproval && pendingApproval != null)
                      _buildPeerApprovalBanner(pendingApproval),
                    if (!isPendingApproval && _expanded)
                      _buildExpandedContent(exec),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(
      WorkflowExecution exec,
      Color accentColor,
      bool allDone,
      bool failed,
      WorkflowPeerApprovalPending? pendingPeerApproval) {
    final l10n = AppLocalizations.of(context);
    final total = exec.totalSteps;
    final done = exec.completedSteps;
    final progress = total > 0 ? done / total : 0.0;

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            // Progress indicator
            SizedBox(
              width: 26,
              height: 26,
              child: exec.status == WorkflowStatus.pendingApproval
                  ? Icon(Icons.pending_actions,
                      size: 22, color: Colors.orange.shade600)
                  : pendingPeerApproval != null
                      ? Icon(Icons.gpp_maybe_outlined,
                          size: 22, color: Colors.deepOrange.shade600)
                      : allDone
                      ? Icon(Icons.check_circle,
                          size: 22, color: Colors.green.shade600)
                      : failed
                      ? Icon(Icons.error, size: 22, color: Colors.red.shade600)
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 2.5,
                              backgroundColor: Colors.grey.shade300,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.blue.shade400),
                            ),
                            Text(
                              '$done',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
            ),
            const SizedBox(width: 10),
            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    exec.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: allDone
                          ? Colors.green.shade700
                          : failed
                              ? Colors.red.shade700
                              : Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    exec.status == WorkflowStatus.pendingApproval
                        ? l10n.workflow_waitingApprovalSteps(exec.totalSteps)
                        : pendingPeerApproval != null
                            ? l10n.workflow_waitingToolApproval(
                                pendingPeerApproval.agentName)
                            : allDone
                            ? l10n.workflow_allDone
                            : failed
                                ? l10n.workflow_execFailed
                                : l10n.workflow_stepsCompletedSlash(
                                    done, total),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            // Expand/collapse button
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: Colors.grey.shade500,
            ),
            const SizedBox(width: 4),
            // Close button
            GestureDetector(
              onTap: widget.onDismiss,
              child: Icon(Icons.close, size: 18, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerApprovalBanner(WorkflowPeerApprovalPending pending) {
    final l10n = AppLocalizations.of(context);
    final needsUser = pending.risk == PeerApprovalRisk.high;
    final approvalData = pending.approvalData;
    final hasInlineActions = approvalData != null &&
        (approvalData['actions'] as List<dynamic>?)?.isNotEmpty == true &&
        approvalData['selected_action_id'] == null &&
        pending.confirmationId != null;

    return Material(
      color: Colors.deepOrange.shade50,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.touch_app_outlined,
                    size: 18, color: Colors.deepOrange.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    needsUser
                        ? l10n.workflow_needToolConfirm
                        : l10n.workflow_waitingToolApprovalShort,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.deepOrange.shade800,
                    ),
                  ),
                ),
              ],
            ),
            if (hasInlineActions) ...[
              const SizedBox(height: 8),
              ActionConfirmationButtons(
                actionData: approvalData!,
                onActionSelected: (confirmationId, actionId, actionLabel) {
                  widget.onPeerApprovalAction?.call(
                    confirmationId,
                    actionId,
                    actionLabel,
                  );
                },
              ),
            ] else if (pending.prompt != null && pending.prompt!.isNotEmpty) ...[
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.18,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    pending.prompt!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.deepOrange.shade700,
                    ),
                  ),
                ),
              ),
              if (pending.messageId != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: () =>
                        widget.onScrollToApproval?.call(pending.messageId!),
                    child: Text(
                      l10n.workflow_viewRelatedMessage,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.deepOrange.shade700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildApprovalButtons() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                _showFeedbackDialog();
              },
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(l10n.plan_requestRevision),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange.shade700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: () {
                widget.onApprovalResponse?.call(true);
              },
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: Text(l10n.workflow_approveExec),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFeedbackDialog() {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.workflow_revisionComment),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: l10n.workflow_revisionHint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onApprovalResponse?.call(
                false,
                feedback: controller.text.trim(),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(l10n.common_submit),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  Widget _buildExpandedContent(WorkflowExecution exec) {
    final l10n = AppLocalizations.of(context);
    final pendingStepId = widget.pendingPeerApproval?.stepId;
    if (exec.steps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(l10n.workflow_noSteps, style: const TextStyle(fontSize: 12)),
      );
    }

    // Group steps by stage
    final stageMap = <int, List<WorkflowStepExecution>>{};
    final stageNames = <int, String>{};
    for (final step in exec.steps) {
      stageMap.putIfAbsent(step.stageIndex, () => []).add(step);
      if (step.stageName.isNotEmpty) {
        stageNames[step.stageIndex] = step.stageName;
      }
    }
    final stageIndices = stageMap.keys.toList()..sort();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: stageIndices.map((stageIdx) {
          final steps = stageMap[stageIdx]!;
          final stageName =
              stageNames[stageIdx] ?? l10n.workflow_stageN(stageIdx + 1);
          final completedInStage = steps
              .where((s) =>
                  s.status == StepExecutionStatus.completed ||
                  s.status == StepExecutionStatus.skipped)
              .length;
          final hasRunning =
              steps.any((s) => s.status == StepExecutionStatus.running);
          final allStageDone = completedInStage == steps.length;

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Stage header
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _stageIcon(hasRunning, allStageDone),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          stageName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ),
                      Text(
                        '$completedInStage/${steps.length}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
                // Steps
                ...steps.map((step) => WorkflowStepTile(
                      step: step,
                      waitingForPeerApproval: pendingStepId == step.id,
                      onTap: pendingStepId == step.id &&
                              widget.pendingPeerApproval?.messageId != null
                          ? () => widget.onScrollToApproval?.call(
                                widget.pendingPeerApproval!.messageId!,
                              )
                          : null,
                    )),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _stageIcon(bool hasRunning, bool allDone) {
    if (hasRunning) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade500),
        ),
      );
    }
    if (allDone) {
      return Icon(Icons.check_circle, size: 14, color: Colors.green.shade500);
    }
    return Icon(Icons.circle_outlined, size: 14, color: Colors.grey.shade400);
  }
}
