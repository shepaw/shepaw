import 'package:flutter/material.dart';

/// Indicator shown when there are queued messages waiting to be processed.
class ChatQueueIndicator extends StatelessWidget {
  final int queueLength;

  const ChatQueueIndicator({
    super.key,
    required this.queueLength,
  });

  @override
  Widget build(BuildContext context) {
    if (queueLength <= 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Colors.blue[50],
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.blue[400],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            queueLength == 1 ? '1 message queued' : '$queueLength messages queued',
            style: TextStyle(
              fontSize: 12,
              color: Colors.blue[700],
            ),
          ),
        ],
      ),
    );
  }
}
