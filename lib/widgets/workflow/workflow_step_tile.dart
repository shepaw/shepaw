import 'package:flutter/material.dart';
import '../../models/workflow_models.dart';

/// A compact row widget displaying a single workflow step's execution state.
class WorkflowStepTile extends StatelessWidget {
  final WorkflowStepExecution step;
  final bool showStageName;

  const WorkflowStepTile({
    super.key,
    required this.step,
    this.showStageName = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status icon
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _buildStatusIcon(),
          ),
          const SizedBox(width: 8),
          // Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Instruction (main text)
                Text(
                  step.instruction,
                  style: TextStyle(
                    fontSize: 13,
                    color: _textColor,
                    fontWeight: step.status == StepExecutionStatus.running
                        ? FontWeight.w600
                        : FontWeight.normal,
                    decoration: step.status == StepExecutionStatus.skipped
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Agent + duration row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: _agentChipColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '@${step.agentName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: _agentTextColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (step.duration != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        step.durationLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                    if (step.errorMessage != null &&
                        step.status == StepExecutionStatus.failed) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          step.errorMessage!,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.red.shade600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (step.status) {
      case StepExecutionStatus.pending:
        return Icon(Icons.circle_outlined, size: 16, color: Colors.grey.shade400);
      case StepExecutionStatus.running:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade600),
          ),
        );
      case StepExecutionStatus.completed:
        return Icon(Icons.check_circle, size: 16, color: Colors.green.shade600);
      case StepExecutionStatus.failed:
        return Icon(Icons.error, size: 16, color: Colors.red.shade600);
      case StepExecutionStatus.skipped:
        return Icon(Icons.skip_next, size: 16, color: Colors.grey.shade500);
    }
  }

  Color get _textColor {
    switch (step.status) {
      case StepExecutionStatus.skipped:
        return Colors.grey;
      case StepExecutionStatus.failed:
        return Colors.red.shade700;
      default:
        return Colors.black87;
    }
  }

  Color get _agentChipColor {
    switch (step.status) {
      case StepExecutionStatus.running:
        return Colors.blue.shade50;
      case StepExecutionStatus.completed:
        return Colors.green.shade50;
      case StepExecutionStatus.failed:
        return Colors.red.shade50;
      default:
        return Colors.grey.shade100;
    }
  }

  Color get _agentTextColor {
    switch (step.status) {
      case StepExecutionStatus.running:
        return Colors.blue.shade700;
      case StepExecutionStatus.completed:
        return Colors.green.shade700;
      case StepExecutionStatus.failed:
        return Colors.red.shade700;
      default:
        return Colors.grey.shade700;
    }
  }
}
