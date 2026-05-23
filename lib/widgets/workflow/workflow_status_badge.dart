import 'package:flutter/material.dart';
import '../../models/workflow_models.dart';

/// Small badge widget displaying workflow status with color coding.
class WorkflowStatusBadge extends StatelessWidget {
  final WorkflowStatus status;
  final double fontSize;

  const WorkflowStatusBadge({
    super.key,
    required this.status,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == WorkflowStatus.running)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(_textColor),
                ),
              ),
            ),
          Text(
            status.label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: _textColor,
            ),
          ),
        ],
      ),
    );
  }

  Color get _bgColor {
    switch (status) {
      case WorkflowStatus.pendingApproval:
        return Colors.orange.shade100;
      case WorkflowStatus.running:
        return Colors.blue.shade100;
      case WorkflowStatus.completed:
        return Colors.green.shade100;
      case WorkflowStatus.failed:
        return Colors.red.shade100;
      case WorkflowStatus.cancelled:
        return Colors.grey.shade200;
    }
  }

  Color get _textColor {
    switch (status) {
      case WorkflowStatus.pendingApproval:
        return Colors.orange.shade800;
      case WorkflowStatus.running:
        return Colors.blue.shade800;
      case WorkflowStatus.completed:
        return Colors.green.shade800;
      case WorkflowStatus.failed:
        return Colors.red.shade800;
      case WorkflowStatus.cancelled:
        return Colors.grey.shade700;
    }
  }
}
