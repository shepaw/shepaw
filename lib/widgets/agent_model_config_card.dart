import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/agent_scenario_models.dart';
import '../models/model_definition.dart';
import '../models/model_routing_config.dart';
import '../screens/model_management_screen.dart';
import '../services/model_registry.dart';
import 'model_icon.dart';

/// Unified agent model configuration: main chat model + attachment routing.
class AgentModelConfigCard extends StatefulWidget {
  final String? mainModelId;
  final ValueChanged<String?> onMainModelChanged;
  final AgentScenarioModels scenarioModels;
  final ValueChanged<AgentScenarioModels> onScenarioModelsChanged;
  final bool showRequiredBadge;
  final FormFieldValidator<String>? mainModelValidator;

  const AgentModelConfigCard({
    super.key,
    required this.mainModelId,
    required this.onMainModelChanged,
    required this.scenarioModels,
    required this.onScenarioModelsChanged,
    this.showRequiredBadge = false,
    this.mainModelValidator,
  });

  @override
  State<AgentModelConfigCard> createState() => _AgentModelConfigCardState();
}

class _AgentModelConfigCardState extends State<AgentModelConfigCard> {
  ModelDefinition? get _mainDef => widget.mainModelId != null
      ? ModelRegistry.instance.getById(widget.mainModelId!)
      : null;

  bool get _needsInputScenarioConfiguration {
    final mainDef = _mainDef;
    if (mainDef == null) return true;
    for (final modality in kInputScenarioModalities) {
      if (widget.scenarioModels.modelIdFor(modality) != null) continue;
      if (!mainModelCoversModality(mainDef, modality)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final defs = ModelRegistry.instance.definitions;
    final mainDef = _mainDef;
    final uncovered = _uncoveredModalities(mainDef, l10n);

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
                Expanded(
                  child: Text(
                    l10n.addAgent_modelConfig,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                if (widget.showRequiredBadge)
                  Text(
                    l10n.common_required,
                    style: TextStyle(fontSize: 12, color: colorScheme.error),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.addAgent_modelConfigHint,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (defs.isEmpty)
              _buildEmptyRegistryState(colorScheme, l10n)
            else ...[
              _LabeledField(
                label: l10n.agentModelConfig_mainChat,
                child: DropdownButtonFormField<String>(
                  initialValue: widget.mainModelId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.chat_bubble_outline),
                    isDense: true,
                  ),
                  hint: Text(l10n.agentModelConfig_selectMainChat),
                  selectedItemBuilder: (context) =>
                      defs.map((def) => _buildCompactModelLabel(def, colorScheme, l10n)).toList(),
                  items: defs
                      .map(
                        (def) => DropdownMenuItem<String>(
                          value: def.id,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: _buildExpandedModelLabel(def, colorScheme, l10n),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: widget.onMainModelChanged,
                  validator: widget.mainModelValidator,
                ),
              ),
              if (widget.mainModelId != null) ...[
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Text(
                  l10n.agentModelConfig_attachmentsSection,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.scenarioModels_hint,
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                if (!_needsInputScenarioConfiguration &&
                    widget.scenarioModels.configuredCount == 0)
                  _StatusBanner(
                    icon: Icons.check_circle_outline,
                    color: colorScheme.primary,
                    text: l10n.scenarioModels_coveredByMain,
                  )
                else if (uncovered.isNotEmpty)
                  _StatusBanner(
                    icon: Icons.info_outline,
                    color: colorScheme.tertiary,
                    text: l10n.scenarioModels_needsConfig(uncovered),
                  ),
                if (!_needsInputScenarioConfiguration ||
                    widget.scenarioModels.configuredCount > 0 ||
                    uncovered.isNotEmpty)
                  const SizedBox(height: 8),
                ...kConfigurableScenarioModalities.map(
                  (modality) => _ScenarioRow(
                    modality: modality,
                    mainDef: mainDef,
                    selectedId: widget.scenarioModels.modelIdFor(modality),
                    onSelected: (id) => widget.onScenarioModelsChanged(
                      widget.scenarioModels.withOverride(modality, id),
                    ),
                    inheritFromMain: modality.isInputScenario,
                    unsetLabel: modality.isInputScenario
                        ? (mainModelCoversModality(mainDef, modality)
                            ? l10n.scenarioModels_inheritMainCovered
                            : l10n.scenarioModels_inheritMain)
                        : l10n.scenarioModels_notConfigured,
                    modalityLabel: _modalityLabel(modality, l10n),
                    l10n: l10n,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyRegistryState(ColorScheme colorScheme, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_outlined, size: 16, color: colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.addAgent_noModels,
                  style: TextStyle(fontSize: 12, color: colorScheme.error),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ModelManagementScreen(),
                ),
              );
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.settings_outlined, size: 16),
            label: Text(l10n.toolModel_goToManagement),
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontSize: 13),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactModelLabel(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return _ModelLabelBuilder.compact(def, colorScheme, l10n);
  }

  Widget _buildExpandedModelLabel(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return _ModelLabelBuilder.expanded(def, colorScheme, l10n);
  }

  String _uncoveredModalities(ModelDefinition? mainDef, AppLocalizations l10n) {
    final labels = <String>[];
    for (final modality in kInputScenarioModalities) {
      if (widget.scenarioModels.modelIdFor(modality) != null) continue;
      if (!mainModelCoversModality(mainDef, modality)) {
        labels.add(_modalityLabel(modality, l10n));
      }
    }
    return labels.join(l10n.common_listSeparator);
  }

  String _modalityLabel(ModalityType modality, AppLocalizations l10n) {
    switch (modality) {
      case ModalityType.text:
        return l10n.modelRouting_text;
      case ModalityType.image:
        return l10n.modelRouting_image;
      case ModalityType.audio:
        return l10n.modelRouting_audio;
      case ModalityType.video:
        return l10n.modelRouting_video;
      case ModalityType.imageGeneration:
        return l10n.modelType_imageGeneration;
      case ModalityType.tts:
        return l10n.modelType_tts;
      case ModalityType.videoGeneration:
        return l10n.modelType_videoGeneration;
    }
  }
}

class _ModelLabelBuilder {
  _ModelLabelBuilder._();

  static Widget compact(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return Row(
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF48FB1).withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              def.displayName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
        ...def.modelTypes.take(2).map(
              (t) => Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: _modelTypeColor(t).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _modelTypeShortLabel(t),
                    style: TextStyle(
                      fontSize: 10,
                      color: _modelTypeColor(t),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  static Widget expanded(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF48FB1).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  def.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ...def.modelTypes.map(
              (t) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: _modelTypeColor(t).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _modelTypeColor(t).withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    _modelTypeLabel(t, l10n),
                    style: TextStyle(
                      fontSize: 10,
                      color: _modelTypeColor(t),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (def.route.model != null && def.route.model!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              def.route.model!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
            ),
          ),
      ],
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

  static String _modelTypeShortLabel(ModelType modelType) {
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

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _StatusBanner({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

class _ScenarioRow extends StatelessWidget {
  final ModalityType modality;
  final ModelDefinition? mainDef;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool inheritFromMain;
  final String unsetLabel;
  final String modalityLabel;
  final AppLocalizations l10n;

  const _ScenarioRow({
    required this.modality,
    required this.mainDef,
    required this.selectedId,
    required this.onSelected,
    required this.inheritFromMain,
    required this.unsetLabel,
    required this.modalityLabel,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final defs = ModelRegistry.instance.definitions
        .forScenario(modality, includeId: selectedId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _LabeledField(
        label: modalityLabel,
        child: DropdownButtonFormField<String?>(
          initialValue: selectedId,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          selectedItemBuilder: (context) => [
            Text(
              unsetLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            ...defs.map(
              (def) => _ModelLabelBuilder.compact(def, colorScheme, l10n),
            ),
          ],
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                unsetLabel,
                style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
            ),
            ...defs.map((def) {
              final isMain = inheritFromMain && mainDef?.id == def.id;
              return DropdownMenuItem<String?>(
                value: def.id,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _ModelLabelBuilder.expanded(def, colorScheme, l10n),
                    ),
                    if (isMain) ...[
                      const SizedBox(width: 6),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(Icons.star_outline,
                            size: 14, color: colorScheme.primary),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
          onChanged: onSelected,
        ),
      ),
    );
  }
}
