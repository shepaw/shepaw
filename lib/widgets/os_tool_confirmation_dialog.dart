import 'package:flutter/material.dart';
import '../services/os_tool_executor.dart';
import '../l10n/app_localizations.dart';

/// Dialog for confirming high-risk OS tool operations.
class OsToolConfirmationDialog extends StatelessWidget {
  final String toolName;
  final Map<String, dynamic> args;
  final RiskLevel risk;

  const OsToolConfirmationDialog({
    super.key,
    required this.toolName,
    required this.args,
    required this.risk,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final description = getRiskDescription(risk, toolName, args);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _iconForTool(toolName),
            color: risk == RiskLevel.highRisk ? colorScheme.error : colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.osTool_confirmTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Risk level badge
          if (risk == RiskLevel.highRisk)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                l10n.osTool_highRisk,
                style: TextStyle(
                  color: colorScheme.onErrorContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

          // Tool name
          Text(
            '${l10n.osTool_tool}: $toolName',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),

          // Operation description
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),

          const SizedBox(height: 12),
          Text(
            l10n.osTool_confirmDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.outline,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.osTool_deny),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: risk == RiskLevel.highRisk
              ? FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                )
              : null,
          child: Text(l10n.osTool_approve),
        ),
      ],
    );
  }

  IconData _iconForTool(String name) {
    switch (name) {
      case 'shell_exec':
        return Icons.terminal;
      case 'file_read':
        return Icons.description;
      case 'file_write':
        return Icons.edit_document;
      case 'file_delete':
        return Icons.delete_forever;
      case 'file_move':
        return Icons.drive_file_move;
      case 'file_list':
        return Icons.folder_open;
      case 'app_open':
        return Icons.launch;
      case 'url_open':
        return Icons.open_in_browser;
      case 'screenshot':
        return Icons.screenshot;
      case 'clipboard_read':
        return Icons.content_paste;
      case 'clipboard_write':
        return Icons.content_copy;
      case 'system_info':
        return Icons.info_outline;
      case 'applescript_exec':
        return Icons.code;
      case 'process_list':
        return Icons.list_alt;
      case 'process_kill':
        return Icons.dangerous;
      case 'process_detail':
        return Icons.analytics;
      case 'network_connections':
        return Icons.lan;
      default:
        return Icons.build;
    }
  }
}
