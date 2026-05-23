import 'package:flutter/material.dart';
import '../../models/workflow_models.dart';
import 'workflow_status_badge.dart';

/// List tile widget for displaying a workflow execution in a list.
class WorkflowListTile extends StatelessWidget {
  final WorkflowExecution execution;
  final VoidCallback? onTap;

  const WorkflowListTile({
    super.key,
    required this.execution,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = execution.status == WorkflowStatus.running ||
        execution.status == WorkflowStatus.pendingApproval;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: isActive ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isActive
            ? BorderSide(color: Colors.blue.shade200, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row
              Row(
                children: [
                  Expanded(
                    child: Text(
                      execution.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  WorkflowStatusBadge(status: execution.status),
                ],
              ),

              const SizedBox(height: 6),

              // Progress info
              Row(
                children: [
                  Icon(Icons.account_tree_outlined,
                      size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text(
                    '${execution.totalStages} 阶段 · ${execution.totalSteps} 步骤',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  if (execution.status == WorkflowStatus.running) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${execution.completedSteps}/${execution.totalSteps} 完成',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (execution.status == WorkflowStatus.completed ||
                      execution.status == WorkflowStatus.failed) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.timer_outlined,
                        size: 13, color: Colors.grey.shade500),
                    const SizedBox(width: 2),
                    Text(
                      execution.durationLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ),

              // Progress bar for running workflows
              if (execution.status == WorkflowStatus.running &&
                  execution.totalSteps > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: execution.completedSteps / execution.totalSteps,
                    minHeight: 4,
                    backgroundColor: Colors.grey.shade200,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
              ],

              const SizedBox(height: 4),

              // Timestamp
              Text(
                _formatTime(execution.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
  }
}
