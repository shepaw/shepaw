import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

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
      color: AppColors.primaryContainer,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            queueLength == 1 ? '1 message queued' : '$queueLength messages queued',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.primaryDark,
            ),
          ),
        ],
      ),
    );
  }
}
