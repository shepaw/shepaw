import 'package:flutter/material.dart';
import '../models/message.dart';

/// Permission audit message card widget.
/// Displays a centered card with green (approved) or red (rejected) border.
class PermissionAuditBubble extends StatelessWidget {
  final Message message;

  const PermissionAuditBubble({Key? key, required this.message})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final audit =
        message.metadata?['permission_audit'] as Map<String, dynamic>? ?? {};
    final approved = audit['approved'] == true;
    final agentName = audit['agent_name'] as String? ?? 'Unknown Agent';
    final action = audit['action'] as String? ?? 'unknown';
    final sessionId = audit['session_id'] as String?;
    final timestampStr = audit['timestamp'] as String?;

    String timeDisplay = '';
    if (timestampStr != null) {
      try {
        final dt = DateTime.parse(timestampStr);
        timeDisplay =
            '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        timeDisplay = timestampStr;
      }
    }

    final borderColor = approved ? Colors.green : Colors.red;
    final statusLabel = approved ? 'Approved' : 'Rejected';
    final statusColor = approved ? Colors.green : Colors.red;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withOpacity(0.1),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.security, size: 18, color: borderColor),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Permission Audit',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Divider
                Divider(height: 1, color: Colors.grey[200]),

                // Details
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      _buildDetailRow('Requester', agentName),
                      const SizedBox(height: 6),
                      _buildDetailRow('Action', action),
                      if (sessionId != null) ...[
                        const SizedBox(height: 6),
                        _buildDetailRow('Session', sessionId),
                      ],
                      if (timeDisplay.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildDetailRow('Time', timeDisplay),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black87,
            ),
          ),
        ),
      ],
    );
  }
}
