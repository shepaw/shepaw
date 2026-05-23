import 'dart:async';
import 'package:flutter/material.dart';
import '../models/workflow_models.dart';
import '../services/workflow/workflow_service.dart';
import '../widgets/workflow/workflow_status_badge.dart';
import '../widgets/workflow/workflow_step_tile.dart';

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
  bool _loading = true;
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
    if (mounted) {
      setState(() {
        _execution = execution;
        _loading = false;
        // Auto-expand current running stage
        if (execution != null) {
          _expandedStages.add(execution.currentStageIndex);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('工作流详情')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_execution == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('工作流详情')),
        body: const Center(child: Text('工作流不存在')),
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
                title: '触发消息',
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
                  '${exec.completedSteps}/${exec.totalSteps} 步骤完成',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (exec.duration != null)
                  Text(
                    exec.status == WorkflowStatus.running
                        ? '已运行 ${exec.durationLabel}'
                        : '总耗时 ${exec.durationLabel}',
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

  Widget _buildSummaryCard(String summary) {
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
                '执行摘要',
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
    if (exec.steps.isEmpty) {
      return const Text('暂无步骤信息');
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
        const Text(
          '执行阶段',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        ...stageIndices.map((stageIdx) {
          final steps = stageMap[stageIdx]!;
          final stageName = stageNames[stageIdx] ?? '阶段 ${stageIdx + 1}';
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
                          .map((step) => WorkflowStepTile(step: step))
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
                '时间信息',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTimingRow('创建时间', _formatDateTime(exec.createdAt)),
          if (exec.startedAt != null)
            _buildTimingRow('开始时间', _formatDateTime(exec.startedAt!)),
          if (exec.completedAt != null)
            _buildTimingRow('完成时间', _formatDateTime(exec.completedAt!)),
          if (exec.duration != null)
            _buildTimingRow('总耗时', exec.durationLabel),
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
