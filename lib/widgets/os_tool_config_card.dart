import 'package:flutter/material.dart';
import '../services/os_tool_registry.dart';
import '../l10n/app_localizations.dart';

/// Configuration card for enabling/disabling individual OS tools
/// during agent creation or editing.
class OsToolConfigCard extends StatelessWidget {
  final Set<String> enabledTools;
  final ValueChanged<Set<String>> onChanged;

  const OsToolConfigCard({
    super.key,
    required this.enabledTools,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.build_circle, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.osTool_configTitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  l10n.common_optional,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.osTool_configHint,
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
            const SizedBox(height: 8),

            // Select All / Deselect All
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    onChanged(Set<String>.from(registry.platformToolNames));
                  },
                  icon: const Icon(Icons.select_all, size: 16),
                  label: Text(l10n.osTool_selectAll),
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () {
                    onChanged({});
                  },
                  icon: const Icon(Icons.deselect, size: 16),
                  label: Text(l10n.osTool_deselectAll),
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const Divider(),

            // Grouped tool list
            ...registry.toolsByCategory.entries.map((entry) {
              final category = entry.key;
              final tools = entry.value;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      _categoryLabel(category, l10n),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ...tools.map((tool) {
                    final supported = tool.supportedPlatforms.contains(platform);
                    final enabled = enabledTools.contains(tool.name);

                    return SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          Icon(
                            _iconForTool(tool.name),
                            size: 16,
                            color: supported
                                ? colorScheme.onSurface
                                : colorScheme.outline.withValues(alpha: 0.5),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tool.name,
                              style: TextStyle(
                                fontSize: 13,
                                color: supported
                                    ? null
                                    : colorScheme.outline.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          _riskBadge(tool.defaultRiskLevel, colorScheme),
                        ],
                      ),
                      subtitle: Text(
                        supported
                            ? tool.description.split('.').first.trim()
                            : l10n.osTool_notSupported(platform),
                        style: TextStyle(
                          fontSize: 11,
                          color: supported
                              ? colorScheme.outline
                              : colorScheme.outline.withValues(alpha: 0.4),
                        ),
                      ),
                      value: enabled && supported,
                      onChanged: supported
                          ? (value) {
                              final updated = Set<String>.from(enabledTools);
                              if (value) {
                                updated.add(tool.name);
                              } else {
                                updated.remove(tool.name);
                              }
                              onChanged(updated);
                            }
                          : null,
                    );
                  }),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _riskBadge(String riskLevel, ColorScheme colorScheme) {
    final Color bgColor;
    final Color fgColor;
    final String label;
    switch (riskLevel) {
      case 'safe':
        bgColor = Colors.green.withValues(alpha: 0.1);
        fgColor = Colors.green;
        label = 'SAFE';
        break;
      case 'highRisk':
        bgColor = colorScheme.errorContainer;
        fgColor = colorScheme.error;
        label = 'HIGH';
        break;
      default: // lowRisk
        bgColor = Colors.orange.withValues(alpha: 0.1);
        fgColor = Colors.orange;
        label = 'LOW';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: fgColor),
      ),
    );
  }

  String _categoryLabel(String category, AppLocalizations l10n) {
    switch (category) {
      case 'command':
        return l10n.osTool_catCommand;
      case 'file':
        return l10n.osTool_catFile;
      case 'app':
        return l10n.osTool_catApp;
      case 'clipboard':
        return l10n.osTool_catClipboard;
      case 'macos':
        return l10n.osTool_catMacos;
      case 'process':
        return l10n.osTool_catProcess;
      default:
        return category;
    }
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
