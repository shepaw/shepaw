import 'package:flutter/material.dart';
import '../services/skill_registry.dart';
import '../l10n/app_localizations.dart';

/// Configuration card for enabling/disabling individual skills
/// during agent creation or editing.
class SkillConfigCard extends StatelessWidget {
  final Set<String> enabledSkills;
  final ValueChanged<Set<String>> onChanged;

  const SkillConfigCard({
    super.key,
    required this.enabledSkills,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final registry = SkillRegistry.instance;
    final skills = registry.skills;

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
                Icon(Icons.auto_stories, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.skill_configTitle,
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
              l10n.skill_configHint,
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
            const SizedBox(height: 8),

            if (skills.isEmpty) ...[
              // No skills found
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: colorScheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.skill_noSkillsFound,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // Action buttons
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      onChanged(Set<String>.from(registry.allSkillNames));
                    },
                    icon: const Icon(Icons.select_all, size: 16),
                    label: Text(l10n.skill_selectAll),
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
                    label: Text(l10n.skill_deselectAll),
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      await registry.rescan();
                      // Trigger rebuild by calling onChanged with current set
                      // (filtered to still-existing skills)
                      final validNames = registry.allSkillNames;
                      onChanged(enabledSkills.intersection(validNames));
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.skill_rescan),
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

              // Skill list
              ...skills.map((skill) {
                final enabled = enabledSkills.contains(skill.toolName);

                return SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Icon(
                        Icons.article,
                        size: 16,
                        color: colorScheme.onSurface,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          skill.displayName,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        skill.description,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.outline,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (skill.fileCount > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: colorScheme.tertiaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.skillMgmt_fileCount(skill.fileCount),
                              style: TextStyle(
                                fontSize: 10,
                                color: colorScheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  value: enabled,
                  onChanged: (value) {
                    final updated = Set<String>.from(enabledSkills);
                    if (value) {
                      updated.add(skill.toolName);
                    } else {
                      updated.remove(skill.toolName);
                    }
                    onChanged(updated);
                  },
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
