import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

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
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isGroupMode ? Icons.group : Icons.chat_bubble_outline,
            size: 64,
            color: scheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            isGroupMode ? l10n.chat_emptyGroupTitle : l10n.chat_emptyTitle,
            style: TextStyle(
              fontSize: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (agentName != null && !isGroupMode) ...[
            const SizedBox(height: 8),
            Text(
              l10n.chat_emptyWithAgent(agentName!),
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
