import 'package:flutter/material.dart';
import '../services/cli_namespace_registry.dart';
import '../l10n/app_localizations.dart';

/// 配置卡片：用于 agent 编辑/创建时选择可用的 CLI 命令
/// 
/// 仿照 OsToolConfigCard 设计，支持：
/// - 按命名空间分组显示
/// - 全选/全不选
/// - 单个命令选择/取消
class CliCommandConfigCard extends StatelessWidget {
  final Set<String> enabledCommands;
  final ValueChanged<Set<String>> onChanged;

  const CliCommandConfigCard({
    super.key,
    required this.enabledCommands,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final registry = CliNamespaceRegistry.instance;

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
                Icon(Icons.terminal, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'CLI Commands',
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
              'Select CLI commands this agent can execute. Commands not selected will be blocked.',
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
            const SizedBox(height: 8),

            // Select All / Deselect All
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    onChanged(Set<String>.from(registry.allCommandIds));
                  },
                  icon: const Icon(Icons.select_all, size: 16),
                  label: const Text('Select All'),
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
                  label: const Text('Deselect All'),
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

            // Grouped command list by namespace
            ...registry.namespaces.entries.map((entry) {
              final nsInfo = entry.value;
              final commands = nsInfo.commands;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Row(
                      children: [
                        Text(
                          nsInfo.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '(${commands.length} commands)',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    nsInfo.description,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Commands in this namespace
                  ...commands.map((cmdId) {
                    final enabled = enabledCommands.contains(cmdId);
                    final cmdLabel = registry.getCommandLabel(cmdId);

                    return SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        cmdId,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: Text(
                        cmdLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.outline,
                        ),
                      ),
                      value: enabled,
                      onChanged: (v) {
                        final updated = Set<String>.from(enabledCommands);
                        if (v) {
                          updated.add(cmdId);
                        } else {
                          updated.remove(cmdId);
                        }
                        onChanged(updated);
                      },
                    );
                  }),

                  const SizedBox(height: 8),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
