import 'package:flutter/material.dart';
import 'model_icon.dart';
import '../models/model_definition.dart';
import '../services/model_registry.dart';
import '../l10n/app_localizations.dart';

/// Configuration card for enabling generation capabilities
/// (image gen, TTS, etc.) during agent creation or editing.
class ModelConfigCard extends StatelessWidget {
  final Set<String> enabledToolModels;
  final ValueChanged<Set<String>> onChanged;

  const ModelConfigCard({
    super.key,
    required this.enabledToolModels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final defs = ModelRegistry.instance.definitions.forDelegation();

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
            Row(
              children: [
                ModelIcon(size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.toolModel_configTitle,
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
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.toolModel_configHint,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),

            if (defs.isEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.toolModel_noGenerationModels,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      onChanged(defs.map((d) => d.toolName).toSet());
                    },
                    icon: const Icon(Icons.select_all, size: 16),
                    label: Text(l10n.toolModel_selectAll),
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => onChanged({}),
                    icon: const Icon(Icons.deselect, size: 16),
                    label: Text(l10n.toolModel_deselectAll),
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
              ...defs.map((def) {
                final enabled = enabledToolModels.contains(def.toolName);
                return SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFFF48FB1).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            def.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      ...def.modelTypes
                          .where(kDelegatableModelTypes.contains)
                          .map(
                            (t) => Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _modelTypeColor(t)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: _modelTypeColor(t)
                                        .withValues(alpha: 0.35),
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  _modelTypeLabel(t, l10n),
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: _modelTypeColor(t),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (def.description.isNotEmpty)
                        Text(
                          def.description,
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (def.route.model != null &&
                          def.route.model!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              def.route.model!,
                              style: TextStyle(
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  value: enabled,
                  onChanged: (value) {
                    final updated = Set<String>.from(enabledToolModels);
                    if (value) {
                      updated.add(def.toolName);
                    } else {
                      updated.remove(def.toolName);
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

  static Color _modelTypeColor(ModelType modelType) {
    switch (modelType) {
      case ModelType.text:
        return const Color(0xFF1976D2);
      case ModelType.imageUnderstanding:
        return const Color(0xFF388E3C);
      case ModelType.imageGeneration:
        return const Color(0xFF7B1FA2);
      case ModelType.audioUnderstanding:
        return const Color(0xFFE64A19);
      case ModelType.videoUnderstanding:
        return const Color(0xFF0097A7);
      case ModelType.videoGeneration:
        return const Color(0xFF00796B);
      case ModelType.tts:
        return const Color(0xFFF57C00);
    }
  }

  static String _modelTypeLabel(ModelType modelType, AppLocalizations l10n) {
    switch (modelType) {
      case ModelType.text:
        return l10n.modelType_text;
      case ModelType.imageUnderstanding:
        return l10n.modelType_imageUnderstanding;
      case ModelType.imageGeneration:
        return l10n.modelType_imageGeneration;
      case ModelType.audioUnderstanding:
        return l10n.modelType_audioUnderstanding;
      case ModelType.videoUnderstanding:
        return l10n.modelType_videoUnderstanding;
      case ModelType.videoGeneration:
        return l10n.modelType_videoGeneration;
      case ModelType.tts:
        return l10n.modelType_tts;
    }
  }
}
