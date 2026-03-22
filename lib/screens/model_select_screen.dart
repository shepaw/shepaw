import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/model_definition.dart';
import '../services/model_registry.dart';
import 'model_management_screen.dart';

/// Full-page screen for selecting tool models per agent and configuring
/// per-agent usage scenarios.
///
/// Receives [toolModelScenarios] (toolName → scenario) and returns the
/// updated map via [Navigator.pop]. An empty string scenario means "use
/// the global description".
class ModelSelectScreen extends StatefulWidget {
  final Map<String, String> toolModelScenarios;

  const ModelSelectScreen({super.key, required this.toolModelScenarios});

  @override
  State<ModelSelectScreen> createState() => _ModelSelectScreenState();
}

class _ModelSelectScreenState extends State<ModelSelectScreen> {
  // toolName → TextEditingController for scenario input
  late Map<String, TextEditingController> _scenarioControllers;
  late Set<String> _enabledToolNames;

  @override
  void initState() {
    super.initState();
    _enabledToolNames = Set<String>.from(widget.toolModelScenarios.keys);
    _scenarioControllers = {};
    for (final def in ModelRegistry.instance.definitions) {
      _scenarioControllers[def.toolName] = TextEditingController(
        text: widget.toolModelScenarios[def.toolName] ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final c in _scenarioControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _buildResult() {
    final result = <String, String>{};
    for (final toolName in _enabledToolNames) {
      result[toolName] = _scenarioControllers[toolName]?.text.trim() ?? '';
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final defs = ModelRegistry.instance.definitions;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.toolModel_configureTitle),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _buildResult()),
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: defs.isEmpty
          ? _buildEmptyState(colorScheme, l10n)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Select all / deselect all
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _enabledToolNames =
                              defs.map((d) => d.toolName).toSet();
                        });
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
                      onPressed: () {
                        setState(() {
                          _enabledToolNames = {};
                        });
                      },
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
                const SizedBox(height: 8),
                ...defs.map((def) => _buildModelTile(def, colorScheme, l10n)),
              ],
            ),
    );
  }

  Widget _buildModelTile(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    final enabled = _enabledToolNames.contains(def.toolName);
    final controller = _scenarioControllers[def.toolName]!;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: enabled
              ? colorScheme.primary.withValues(alpha: 0.4)
              : colorScheme.outlineVariant,
        ),
      ),
      color: enabled
          ? colorScheme.primaryContainer.withValues(alpha: 0.08)
          : null,
      child: Column(
        children: [
          // Header row with toggle
          SwitchListTile(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            title: Row(
              children: [
                // Model name with pink-tinted background
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF48FB1).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      def.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            enabled ? FontWeight.w600 : FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Model type badges
                ...def.modelTypes.map((t) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: _modelTypeColor(t).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: _modelTypeColor(t).withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      _modelTypeLabel(t),
                      style: TextStyle(
                        fontSize: 9,
                        color: _modelTypeColor(t),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )),
              ],
            ),
            subtitle: def.route.model != null && def.route.model!.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(left: 0, top: 4),
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
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                  )
                : null,
            value: enabled,
            onChanged: (value) {
              setState(() {
                if (value) {
                  _enabledToolNames.add(def.toolName);
                } else {
                  _enabledToolNames.remove(def.toolName);
                }
              });
            },
          ),

          // Scenario input — shown only when enabled
          if (enabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_scenarioLabel,
                  hintText: def.description.isNotEmpty
                      ? def.description
                      : l10n.toolModel_scenarioPlaceholder,
                  helperText: l10n.toolModel_scenarioHint,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.tips_and_updates_outlined,
                      size: 18),
                  isDense: true,
                ),
                maxLines: 2,
                minLines: 1,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Returns a color for a given model type tag.
  Color _modelTypeColor(ModelType modelType) {
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

  /// Returns a short label for a given model type.
  String _modelTypeLabel(ModelType modelType) {
    switch (modelType) {
      case ModelType.text:
        return 'Text';
      case ModelType.imageUnderstanding:
        return 'Vision';
      case ModelType.imageGeneration:
        return 'ImgGen';
      case ModelType.audioUnderstanding:
        return 'Audio';
      case ModelType.videoUnderstanding:
        return 'Video';
      case ModelType.videoGeneration:
        return 'VideoGen';
      case ModelType.tts:
        return 'TTS';
    }
  }

  Widget _buildEmptyState(ColorScheme colorScheme, AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined,
                size: 48, color: colorScheme.outline.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              l10n.toolModel_noModelsAvailable,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colorScheme.outline),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ModelManagementScreen(),
                  ),
                );
                if (mounted) setState(() {});
              },
              child: Text(l10n.toolModel_goToManagement),
            ),
          ],
        ),
      ),
    );
  }
}
