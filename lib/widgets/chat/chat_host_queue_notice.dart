import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// 直接发出的消息被主机会话队列收下时的只读提示。
///
/// 这类消息不在本地待发面板里（本地以为已经发出去了），可编辑/删除/重排
/// 都作用不到主机队列，所以只展示状态、不给操作。
class ChatHostQueueNotice extends StatelessWidget {
  final int count;

  const ChatHostQueueNotice({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        border: const Border(
          top: BorderSide(color: AppColors.primaryLight, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.queue, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.chat_hostQueueNotice(count),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
