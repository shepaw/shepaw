import 'package:flutter/material.dart';

/// Empty state widget shown when there are no messages yet.
class ChatEmptyState extends StatelessWidget {
  final String? agentName;
  final bool isGroupMode;

  const ChatEmptyState({
    super.key,
    this.agentName,
    this.isGroupMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isGroupMode ? Icons.group : Icons.chat_bubble_outline,
            size: 64,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            isGroupMode
                ? 'Start a group conversation'
                : 'No messages yet',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[500],
            ),
          ),
          if (agentName != null && !isGroupMode) ...[
            const SizedBox(height: 8),
            Text(
              'Send a message to start chatting with $agentName',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[400],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
