import 'dart:async';
import 'package:flutter/material.dart';
import '../models/workflow_models.dart';
import '../models/workflow_pending_approval.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../services/workflow/workflow_service.dart';
import '../widgets/action_confirmation_buttons.dart';
import '../widgets/workflow/workflow_status_badge.dart';
import '../widgets/workflow/workflow_step_tile.dart';
import '../l10n/app_localizations.dart';

/// Workflow detail screen showing full execution state with stages and steps.
///
/// Uses a stream to update in real time when the workflow is running.
class WorkflowDetailScreen extends StatefulWidget {
  final String workflowId;
  final WorkflowService workflowService;

  const WorkflowDetailScreen({
    super.key,
    required this.workflowId,
    required this.workflowService,
  });

  @override
  State<WorkflowDetailScreen> createState() => _WorkflowDetailScreenState();
}

class _WorkflowDetailScreenState extends State<WorkflowDetailScreen> {
  WorkflowExecution? _execution;
  WorkflowPendingApproval? _pendingPeerApproval;
  bool _loading = true;
  bool _submittingApproval = false;
  StreamSubscription? _updateSub;
  final Set<int> _expandedStages = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Watch for real-time updates
    _updateSub = widget.workflowService
        .watchWorkflow(widget.workflowId)
        .listen((execution) {
      if (mounted && execution != null) {
        setState(() => _execution = execution);
      }
    });
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final execution = await widget.workflowService
        .getWorkflowExecutionWithSteps(widget.workflowId);
    final pending = await widget.workflowService
        .getPendingApprovalForWorkflow(widget.workflowId);
    if (mounted) {
      setState(() {
        _execution = execution;
        _pendingPeerApproval = pending;
        _loading = false;
        // Auto-expand current running stage
        if (execution != null) {
          _expandedStages.add(execution.currentStageIndex);
        }
      });
    }
  }

  Future<void> _submitPeerApproval(
    String confirmationId,
    String actionId,
    String actionLabel,
  ) async {
    final l10n = AppLocalizations.of(context);
    final pending = _pendingPeerApproval;
    if (pending == null || _submittingApproval) return;
    setState(() => _submittingApproval = true);
    try {
      await PeerAgentClientService.instance.submitApproval(
        peerId: pending.peerId,
        approvalId: pending.confirmationId,
        selectedActionId: actionId,
        selectedActionLabel: actionLabel,
      );
      await widget.workflowService.markPendingApprovalSubmitted(
        confirmationId,
        selectedActionId: actionId,
      );
      if (mounted) {
        setState(() {
          _pendingPeerApproval = null;
          _submittingApproval = false;
        });
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.workflow_approvalSubmitted)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submittingApproval = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).workflow_approvalFailed('$e'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.workflow_detailTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_execution == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.workflow_detailTitle)),
        body: Center(child: Text(l10n.workflow_notFound)),
      );
    }

    final exec = _execution!;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          exec.title,
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 1,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Status banner
            _buildStatusBanner(exec),
            const SizedBox(height: 16),

            if (_pendingPeerApproval != null) ...[
              _buildPeerApprovalCard(_pendingPeerApproval!),
              const SizedBox(height: 16),
            ],

            // Summary (if completed)
            if (exec.summary != null && exec.summary!.isNotEmpty) ...[
              _buildSummaryCard(exec.summary!),
              const SizedBox(height: 16),
            ],

            // Error message (if failed)
            if (exec.errorMessage != null &&
                exec.status == WorkflowStatus.failed) ...[
              _buildErrorCard(exec.errorMessage!),
              const SizedBox(height: 16),
            ],

            // Stages & Steps
            _buildStagesSection(exec),

            const SizedBox(height: 16),

            // Trigger message
            if (exec.triggerMessage != null &&
                exec.triggerMessage!.isNotEmpty) ...[
              _buildInfoCard(
                icon: Icons.message_outlined,
                title: l10n.workflow_triggerMessage,
                content: exec.triggerMessage!,
              ),
              const SizedBox(height: 12),
            ],

            // Timing info
            _buildTimingCard(exec),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner(WorkflowExecution exec) {
    final l10n = AppLocalizations.of(context);
    final Color bgColor;
    final Color borderColor;
    switch (exec.status) {
      case WorkflowStatus.running:
        bgColor = Colors.blue.shade50;
        borderColor = Colors.blue.shade200;
        break;
      case WorkflowStatus.completed:
        bgColor = Colors.green.shade50;
        borderColor = Colors.green.shade200;
        break;
      case WorkflowStatus.failed:
        bgColor = Colors.red.shade50;
        borderColor = Colors.red.shade200;
        break;
      default:
        bgColor = Colors.grey.shade50;
        borderColor = Colors.grey.shade200;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          WorkflowStatusBadge(status: exec.status, fontSize: 13),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.workflow_stepsCompleted(exec.completedSteps, exec.totalSteps),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (exec.duration != null)
                  Text(
                    exec.status == WorkflowStatus.running
                        ? l10n.workflow_runningFor(exec.durationLabel)
                        : l10n.workflow_totalDurationValue(exec.durationLabel),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
              ],
            ),
          ),
          if (exec.totalSteps > 0)
            SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: exec.completedSteps / exec.totalSteps,
                    strokeWidth: 4,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      exec.status == WorkflowStatus.completed
                          ? Colors.green
                          : Colors.blue,
                    ),
                  ),
                  Text(
                    '${((exec.completedSteps / exec.totalSteps) * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPeerApprovalCard(WorkflowPendingApproval pending) {
    final l10n = AppLocalizations.of(context);
    final ui = pending.toUiPending();
    final data = pending.approvalData;
    final hasActions =
        (data['actions'] as List<dynamic>?)?.isNotEmpty == true;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.deepOrange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepOrange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_maybe_outlined,
                  color: Colors.deepOrange.shade700, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.workflow_waitingToolApproval(pending.agentName),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.deepOrange.shade900,
                  ),
                ),
              ),
            ],
          ),
          if (pending.approvalData['prompt'] != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.22,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  pending.approvalData['prompt'] as String,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.deepOrange.shade800,
                  ),
                ),
              ),
            ),
          ],
          if (hasActions && !_submittingApproval) ...[
            const SizedBox(height: 12),
            ActionConfirmationButtons(
              actionData: data,
              onActionSelected: _submitPeerApproval,
            ),
          ] else if (_submittingApproval)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.workflow_returnToChatForApproval,
                style: TextStyle(fontSize: 12, color: Colors.deepOrange.shade700),
              ),
            ),
          if (ui.risk == PeerApprovalRisk.low)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.workflow_lowRiskOp,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(String summary) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.summarize_outlined,
                  size: 16, color: Colors.green.shade700),
              const SizedBox(width: 6),
              Text(
                l10n.workflow_execSummary,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade800,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(String error) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                fontSize: 13,
                color: Colors.red.shade700,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStagesSection(WorkflowExecution exec) {
    final l10n = AppLocalizations.of(context);
    if (exec.steps.isEmpty) {
      return Text(l10n.workflow_noSteps);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.workflow_execStages,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        ...stageIndices.map((stageIdx) {
          final steps = stageMap[stageIdx]!;
          final stageName = stageNames[stageIdx] ?? l10n.workflow_stageN(stageIdx + 1);
          final isExpanded = _expandedStages.contains(stageIdx);
          final completedInStage = steps
              .where((s) =>
                  s.status == StepExecutionStatus.completed ||
                  s.status == StepExecutionStatus.skipped)
              .length;
          final hasRunning =
              steps.any((s) => s.status == StepExecutionStatus.running);
          final hasFailed =
              steps.any((s) => s.status == StepExecutionStatus.failed);
          final allDone = completedInStage == steps.length;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasRunning
                    ? Colors.blue.shade200
                    : hasFailed
                        ? Colors.red.shade200
                        : allDone
                            ? Colors.green.shade200
                            : Colors.grey.shade200,
              ),
            ),
            child: Column(
              children: [
                // Stage header (tappable)
                InkWell(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(10)),
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedStages.remove(stageIdx);
                      } else {
                        _expandedStages.add(stageIdx);
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        _buildStageIcon(
                            hasRunning, hasFailed, allDone),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            stageName,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '$completedInStage/${steps.length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          isExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 20,
                          color: Colors.grey.shade500,
                        ),
                      ],
                    ),
                  ),
                ),
                // Steps (expanded)
                if (isExpanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(
                      children: steps
                          .map((step) => WorkflowStepTile(
                                step: step,
                                waitingForPeerApproval:
                                    _pendingPeerApproval?.stepId == step.id,
                              ))
                          .toList(),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildStageIcon(bool hasRunning, bool hasFailed, bool allDone) {
    if (hasRunning) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade600),
        ),
      );
    }
    if (hasFailed) {
      return Icon(Icons.error, size: 18, color: Colors.red.shade600);
    }
    if (allDone) {
      return Icon(Icons.check_circle, size: 18, color: Colors.green.shade600);
    }
    return Icon(Icons.circle_outlined, size: 18, color: Colors.grey.shade400);
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String content,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade800,
              height: 1.4,
            ),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildTimingCard(WorkflowExecution exec) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                l10n.workflow_timeInfo,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTimingRow(l10n.agentDetail_createdAt, _formatDateTime(exec.createdAt)),
          if (exec.startedAt != null)
            _buildTimingRow(l10n.workflow_startTime, _formatDateTime(exec.startedAt!)),
          if (exec.completedAt != null)
            _buildTimingRow(l10n.workflow_endTime, _formatDateTime(exec.completedAt!)),
          if (exec.duration != null)
            _buildTimingRow(l10n.workflow_totalDuration, exec.durationLabel),
        ],
      ),
    );
  }

  Widget _buildTimingRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
