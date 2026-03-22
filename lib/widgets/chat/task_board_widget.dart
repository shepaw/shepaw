import 'package:flutter/material.dart';
import '../../models/planning_models.dart';

/// A system message widget that shows live task execution progress
/// for a planning-mode group conversation.
///
/// Features:
/// - Animated status icon transitions
/// - Expandable task rows with description and complexity badge
/// - Color-coded row backgrounds per status
/// - Animated progress bar
/// - "All done" completion state with green styling
class TaskBoardWidget extends StatefulWidget {
  final Map<String, dynamic> planData;

  const TaskBoardWidget({
    super.key,
    required this.planData,
  });

  @override
  State<TaskBoardWidget> createState() => _TaskBoardWidgetState();
}

class _TaskBoardWidgetState extends State<TaskBoardWidget>
    with SingleTickerProviderStateMixin {
  late ExecutionPlan _plan;
  late AnimationController _completionAnimCtrl;
  late Animation<double> _completionScale;
  final Set<String> _expandedTaskIds = {};

  @override
  void initState() {
    super.initState();
    _plan = ExecutionPlan.fromJson(widget.planData);
    _completionAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _completionScale = CurvedAnimation(
      parent: _completionAnimCtrl,
      curve: Curves.elasticOut,
    );
    if (_isAllDone) _completionAnimCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(TaskBoardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planData != widget.planData) {
      final wasAllDone = _isAllDone;
      _plan = ExecutionPlan.fromJson(widget.planData);
      if (!wasAllDone && _isAllDone) {
        _completionAnimCtrl.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _completionAnimCtrl.dispose();
    super.dispose();
  }

  bool get _isAllDone {
    if (_plan.tasks.isEmpty) return false;
    return _plan.tasks.every(
      (t) => t.status == TaskStatus.done || t.status == TaskStatus.skipped,
    );
  }

  int get _doneCount => _plan.tasks
      .where((t) => t.status == TaskStatus.done || t.status == TaskStatus.skipped)
      .length;

  @override
  Widget build(BuildContext context) {
    final total = _plan.tasks.length;
    final done = _doneCount;
    final progress = total > 0 ? done / total : 0.0;
    final allDone = _isAllDone;

    final borderColor = allDone ? Colors.green.shade300 : Colors.blue.shade200;
    final headerColor = allDone ? Colors.green.shade50 : Colors.blue.shade50;
    final progressColor = allDone ? Colors.green : Colors.blue;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: borderColor.withOpacity(0.2),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: headerColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: allDone
                      ? ScaleTransition(
                          key: const ValueKey('done'),
                          scale: _completionScale,
                          child: const Icon(Icons.check_circle,
                              size: 18, color: Colors.green),
                        )
                      : const Icon(
                          key: ValueKey('progress'),
                          Icons.pending_actions_outlined,
                          size: 18,
                          color: Colors.blue,
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _plan.title.isNotEmpty ? _plan.title : '任务执行进度',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: allDone ? Colors.green.shade800 : Colors.blue.shade800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: allDone
                        ? Colors.green.shade100
                        : Colors.blue.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$done / $total',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: allDone
                          ? Colors.green.shade800
                          : Colors.blue.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Progress bar ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: progress),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
              builder: (_, value, __) => ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                ),
              ),
            ),
          ),

          // ── All-done summary ──
          if (allDone)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              child: Text(
                '全部任务已完成',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

          const SizedBox(height: 4),

          // ── Task list ──
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              children: _plan.tasks
                  .map((t) => _buildTaskRow(t))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskRow(PlanTask task) {
    final isExpanded = _expandedTaskIds.contains(task.id);
    final rowBg = _rowBackground(task.status);
    final textColor = task.status == TaskStatus.skipped
        ? Colors.grey
        : (task.status == TaskStatus.failed ? Colors.red.shade700 : Colors.black87);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: rowBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main row (tappable to expand if description exists)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: task.description.isNotEmpty
                  ? () => setState(() {
                        if (isExpanded) {
                          _expandedTaskIds.remove(task.id);
                        } else {
                          _expandedTaskIds.add(task.id);
                        }
                      })
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    // Animated status icon
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Text(
                        _statusIcon(task.status),
                        key: ValueKey('${task.id}_${task.status.name}'),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 13,
                          color: textColor,
                          fontWeight: task.status == TaskStatus.inProgress
                              ? FontWeight.w600
                              : FontWeight.normal,
                          decoration: task.status == TaskStatus.skipped
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    if (task.assignee.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _assigneeChipColor(task.status),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '@${task.assignee}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _assigneeChipTextColor(task.status),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                    if (task.description.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Icon(
                        isExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: Colors.grey.shade500,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Expandable detail section
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: isExpanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(34, 0, 10, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                              height: 1.4,
                            ),
                          ),
                          if (task.dependencies.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '依赖: ${task.dependencies.join(', ')}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                          if (task.estimatedComplexity.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            _complexityBadge(task.estimatedComplexity),
                          ],
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Color _rowBackground(TaskStatus status) {
    switch (status) {
      case TaskStatus.inProgress:
        return Colors.blue.shade50;
      case TaskStatus.done:
        return Colors.green.shade50;
      case TaskStatus.failed:
        return Colors.red.shade50;
      case TaskStatus.skipped:
        return Colors.grey.shade100;
      case TaskStatus.pending:
        return Colors.transparent;
    }
  }

  Color _assigneeChipColor(TaskStatus status) {
    switch (status) {
      case TaskStatus.inProgress:
        return Colors.blue.shade100;
      case TaskStatus.done:
        return Colors.green.shade100;
      case TaskStatus.failed:
        return Colors.red.shade100;
      default:
        return Colors.grey.shade200;
    }
  }

  Color _assigneeChipTextColor(TaskStatus status) {
    switch (status) {
      case TaskStatus.inProgress:
        return Colors.blue.shade800;
      case TaskStatus.done:
        return Colors.green.shade800;
      case TaskStatus.failed:
        return Colors.red.shade800;
      default:
        return Colors.grey.shade700;
    }
  }

  String _statusIcon(TaskStatus status) {
    switch (status) {
      case TaskStatus.pending:
        return '⏳';
      case TaskStatus.inProgress:
        return '🔄';
      case TaskStatus.done:
        return '✅';
      case TaskStatus.failed:
        return '❌';
      case TaskStatus.skipped:
        return '⏭️';
    }
  }

  Widget _complexityBadge(String complexity) {
    Color color;
    String label;
    switch (complexity.toLowerCase()) {
      case 'high':
        color = Colors.red.shade400;
        label = '高复杂度';
        break;
      case 'medium':
        color = Colors.orange.shade400;
        label = '中复杂度';
        break;
      default:
        color = Colors.green.shade400;
        label = '低复杂度';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color),
        ),
      ],
    );
  }
}
