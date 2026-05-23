import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/workflow_models.dart';
import '../../services/local_database_service.dart';
import '../../services/workflow/workflow_service.dart';
import 'workflow_step_tile.dart';

/// A floating panel shown above the chat input area during workflow execution.
///
/// - **Collapsed**: single-row showing title + progress + expand/close buttons
/// - **Expanded**: scrollable list of stages and steps with real-time status
///
/// Listens to [WorkflowService.watchWorkflow] for live updates.
class WorkflowProgressPanel extends StatefulWidget {
  final String workflowId;
  final VoidCallback? onDismiss;

  const WorkflowProgressPanel({
    super.key,
    required this.workflowId,
    this.onDismiss,
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

    final allDone = exec.status == WorkflowStatus.completed;
    final failed = exec.status == WorkflowStatus.failed;
    final accentColor = allDone
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
          // Collapsed header (always visible)
          _buildHeader(exec, accentColor, allDone, failed),
          // Expanded content
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            child: _expanded ? _buildExpandedContent(exec) : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
      WorkflowExecution exec, Color accentColor, bool allDone, bool failed) {
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
              child: allDone
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
                    allDone
                        ? '全部完成'
                        : failed
                            ? '执行失败'
                            : '$done / $total 步骤完成',
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
              _expanded ? Icons.expand_more : Icons.expand_less,
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

  Widget _buildExpandedContent(WorkflowExecution exec) {
    if (exec.steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('暂无步骤信息', style: TextStyle(fontSize: 12)),
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

    final maxHeight = MediaQuery.of(context).size.height * 0.35;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: stageIndices.map((stageIdx) {
          final steps = stageMap[stageIdx]!;
          final stageName = stageNames[stageIdx] ?? '阶段 ${stageIdx + 1}';
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
                ...steps.map((step) => WorkflowStepTile(step: step)),
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
