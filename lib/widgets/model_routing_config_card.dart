import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/model_routing_config.dart';
import '../models/remote_agent.dart';
import '../services/model_registry.dart';

/// Configuration card for multi-modal model routing.
///
/// Allows users to optionally configure different LLM models for different
/// content types (text, image, audio, video) and custom modalities.
/// Unconfigured modalities inherit the agent's default (fallback) model.
class ModelRoutingConfigCard extends StatefulWidget {
  /// Current built-in routing config.
  final Map<ModalityType, ModelRouteConfig> routes;

  /// Current custom modality list.
  final List<CustomModality> customModalities;

  /// Called when any route or custom modality is changed.
  final void Function(
    Map<ModalityType, ModelRouteConfig> routes,
    List<CustomModality> customModalities,
  ) onChanged;

  const ModelRoutingConfigCard({
    super.key,
    required this.routes,
    this.customModalities = const [],
    required this.onChanged,
  });

  @override
  State<ModelRoutingConfigCard> createState() => _ModelRoutingConfigCardState();
}

/// State holder for a single custom modality entry's controllers.
class _CustomModalityState {
  final TextEditingController keyController;
  final TextEditingController labelController;
  final TextEditingController descriptionController;
  final TextEditingController modelController;
  final TextEditingController providerController;
  final TextEditingController apiBaseController;
  final TextEditingController apiKeyController;
  final TextEditingController apiPathController;
  final TextEditingController requestBodyTemplateController;
  final TextEditingController responseBodyPathController;
  bool showAdvanced;
  bool obscureApiKey;
  bool streamEnabled;

  _CustomModalityState({
    String key = '',
    String label = '',
    String description = '',
    String model = '',
    String provider = '',
    String apiBase = '',
    String apiKey = '',
    String apiPath = '',
    String requestBodyTemplate = '',
    String responseBodyPath = '',
    bool? stream,
  })  : keyController = TextEditingController(text: key),
        labelController = TextEditingController(text: label),
        descriptionController = TextEditingController(text: description),
        modelController = TextEditingController(text: model),
        providerController = TextEditingController(text: provider),
        apiBaseController = TextEditingController(text: apiBase),
        apiKeyController = TextEditingController(text: apiKey),
        apiPathController = TextEditingController(text: apiPath),
        requestBodyTemplateController =
            TextEditingController(text: requestBodyTemplate),
        responseBodyPathController =
            TextEditingController(text: responseBodyPath),
        showAdvanced = false,
        obscureApiKey = true,
        streamEnabled = stream ?? true;

  void dispose() {
    keyController.dispose();
    labelController.dispose();
    descriptionController.dispose();
    modelController.dispose();
    providerController.dispose();
    apiBaseController.dispose();
    apiKeyController.dispose();
    apiPathController.dispose();
    requestBodyTemplateController.dispose();
    responseBodyPathController.dispose();
  }

  CustomModality toCustomModality() {
    final streamVal = streamEnabled;
    return CustomModality(
      key: keyController.text.trim(),
      label: labelController.text.trim(),
      description: descriptionController.text.trim(),
      route: ModelRouteConfig(
        model: modelController.text.trim().isEmpty
            ? null
            : modelController.text.trim(),
        provider: providerController.text.trim().isEmpty
            ? null
            : providerController.text.trim(),
        apiBase: apiBaseController.text.trim().isEmpty
            ? null
            : apiBaseController.text.trim(),
        apiKey: apiKeyController.text.trim().isEmpty
            ? null
            : apiKeyController.text.trim(),
        stream: streamVal ? null : false,
        apiPath: apiPathController.text.trim().isEmpty
            ? null
            : apiPathController.text.trim(),
        requestBodyTemplate:
            requestBodyTemplateController.text.trim().isEmpty
                ? null
                : requestBodyTemplateController.text.trim(),
        responseBodyPath: responseBodyPathController.text.trim().isEmpty
            ? null
            : responseBodyPathController.text.trim(),
      ),
    );
  }
}

class _ModelRoutingConfigCardState extends State<ModelRoutingConfigCard> {
  bool _isExpanded = false;

  // Per-modality controllers
  final Map<ModalityType, TextEditingController> _modelControllers = {};
  final Map<ModalityType, TextEditingController> _providerControllers = {};
  final Map<ModalityType, TextEditingController> _apiBaseControllers = {};
  final Map<ModalityType, TextEditingController> _apiKeyControllers = {};
  final Map<ModalityType, TextEditingController> _apiPathControllers = {};
  final Map<ModalityType, TextEditingController> _requestBodyTemplateControllers = {};
  final Map<ModalityType, TextEditingController> _responseBodyPathControllers = {};

  // Track which modalities show advanced fields
  final Map<ModalityType, bool> _showAdvanced = {};

  // Track API key visibility per modality
  final Map<ModalityType, bool> _obscureApiKey = {};

  // Track stream toggle per modality (true = SSE, false = non-SSE)
  final Map<ModalityType, bool> _streamEnabled = {};

  // Custom modalities state
  final List<_CustomModalityState> _customModalityStates = [];

  @override
  void initState() {
    super.initState();
    for (final type in ModalityType.values) {
      final route = widget.routes[type];
      _modelControllers[type] =
          TextEditingController(text: route?.model ?? '');
      _providerControllers[type] =
          TextEditingController(text: route?.provider ?? '');
      _apiBaseControllers[type] =
          TextEditingController(text: route?.apiBase ?? '');
      _apiKeyControllers[type] =
          TextEditingController(text: route?.apiKey ?? '');
      _apiPathControllers[type] =
          TextEditingController(text: route?.apiPath ?? '');
      _requestBodyTemplateControllers[type] =
          TextEditingController(text: route?.requestBodyTemplate ?? '');
      _responseBodyPathControllers[type] =
          TextEditingController(text: route?.responseBodyPath ?? '');
      _apiKeyControllers[type]!.addListener(() => _repairApiKeyIfGarbled(type));
      _showAdvanced[type] = false;
      _obscureApiKey[type] = true;
      _streamEnabled[type] = route?.stream ?? true;
    }

    // Initialize custom modality states from widget props
    for (final cm in widget.customModalities) {
      _customModalityStates.add(_CustomModalityState(
        key: cm.key,
        label: cm.label,
        description: cm.description,
        model: cm.route.model ?? '',
        provider: cm.route.provider ?? '',
        apiBase: cm.route.apiBase ?? '',
        apiKey: cm.route.apiKey ?? '',
        apiPath: cm.route.apiPath ?? '',
        requestBodyTemplate: cm.route.requestBodyTemplate ?? '',
        responseBodyPath: cm.route.responseBodyPath ?? '',
        stream: cm.route.stream,
      ));
    }

    _isExpanded = true;
  }

  @override
  void dispose() {
    for (final c in _modelControllers.values) {
      c.dispose();
    }
    for (final c in _providerControllers.values) {
      c.dispose();
    }
    for (final c in _apiBaseControllers.values) {
      c.dispose();
    }
    for (final c in _apiKeyControllers.values) {
      c.dispose();
    }
    for (final c in _apiPathControllers.values) {
      c.dispose();
    }
    for (final c in _requestBodyTemplateControllers.values) {
      c.dispose();
    }
    for (final c in _responseBodyPathControllers.values) {
      c.dispose();
    }
    for (final s in _customModalityStates) {
      s.dispose();
    }
    super.dispose();
  }

  void _notifyChanged() {
    final routes = <ModalityType, ModelRouteConfig>{};
    for (final type in ModalityType.values) {
      final streamVal = _streamEnabled[type] ?? true;
      final config = ModelRouteConfig(
        model: _modelControllers[type]!.text.trim().isEmpty
            ? null
            : _modelControllers[type]!.text.trim(),
        provider: _providerControllers[type]!.text.trim().isEmpty
            ? null
            : _providerControllers[type]!.text.trim(),
        apiBase: _apiBaseControllers[type]!.text.trim().isEmpty
            ? null
            : _apiBaseControllers[type]!.text.trim(),
        apiKey: _apiKeyControllers[type]!.text.trim().isEmpty
            ? null
            : _apiKeyControllers[type]!.text.trim(),
        stream: streamVal ? null : false,
        apiPath: _apiPathControllers[type]!.text.trim().isEmpty
            ? null
            : _apiPathControllers[type]!.text.trim(),
        requestBodyTemplate:
            _requestBodyTemplateControllers[type]!.text.trim().isEmpty
                ? null
                : _requestBodyTemplateControllers[type]!.text.trim(),
        responseBodyPath:
            _responseBodyPathControllers[type]!.text.trim().isEmpty
                ? null
                : _responseBodyPathControllers[type]!.text.trim(),
      );
      if (!config.isEmpty) {
        routes[type] = config;
      }
    }

    final customModalities =
        _customModalityStates.map((s) => s.toCustomModality()).toList();

    widget.onChanged(routes, customModalities);
  }

  void _repairApiKeyIfGarbled(ModalityType type) {
    final controller = _apiKeyControllers[type]!;
    final text = controller.text;
    final repaired = repairUtf16Garbled(text);
    if (repaired != text) {
      controller.value = TextEditingValue(
        text: repaired,
        selection: TextSelection.collapsed(offset: repaired.length),
      );
    }
  }

  String _modalityLabel(ModalityType type, AppLocalizations l10n) {
    switch (type) {
      case ModalityType.text:
        return l10n.modelRouting_text;
      case ModalityType.image:
        return l10n.modelRouting_image;
      case ModalityType.audio:
        return l10n.modelRouting_audio;
      case ModalityType.video:
        return l10n.modelRouting_video;
    }
  }

  IconData _modalityIcon(ModalityType type) {
    switch (type) {
      case ModalityType.text:
        return Icons.text_fields;
      case ModalityType.image:
        return Icons.image;
      case ModalityType.audio:
        return Icons.audiotrack;
      case ModalityType.video:
        return Icons.videocam;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    final configuredCount =
        widget.routes.values.where((r) => !r.isEmpty).length;
    final customCount =
        _customModalityStates.where((s) => s.keyController.text.trim().isNotEmpty).length;
    final totalConfigured = configuredCount + customCount;

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
            // Header — tap to expand/collapse
            InkWell(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Icon(Icons.route, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.modelRouting_title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  if (totalConfigured > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$totalConfigured',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _isExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ),

            if (_isExpanded) ...[
              const SizedBox(height: 8),
              Text(
                l10n.modelRouting_hint,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.outline,
                ),
              ),
              const Divider(height: 24),

              // One section per built-in modality
              for (final type in ModalityType.values) ...[
                _buildModalitySection(type, colorScheme, l10n),
                if (type != ModalityType.video) const SizedBox(height: 12),
              ],

              // Custom modalities section (deprecated — use Tool Models instead)
              // const SizedBox(height: 16),
              // _buildCustomModalitiesSection(colorScheme, l10n),
            ],
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // Quick-select helper
  // =========================================================================

  Widget _buildModelQuickSelect({
    required List<dynamic> modelDefs,
    required ColorScheme colorScheme,
    required AppLocalizations l10n,
    required void Function(dynamic def) onSelected,
  }) {
    if (modelDefs.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<dynamic>(
      tooltip: l10n.modelRouting_selectFromRegistry,
      onSelected: onSelected,
      itemBuilder: (_) => modelDefs
          .map((def) => PopupMenuItem(
                value: def,
                child: Row(
                  children: [
                    Icon(Icons.memory, size: 16, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(def.displayName,
                              style: const TextStyle(fontSize: 13)),
                          if (def.route.model != null &&
                              def.route.model!.isNotEmpty)
                            Text(
                              def.route.model!,
                              style: TextStyle(
                                  fontSize: 11, color: colorScheme.outline),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: colorScheme.secondary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 14, color: colorScheme.secondary),
            const SizedBox(width: 4),
            Text(
              l10n.modelRouting_selectFromRegistry,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down,
                size: 16, color: colorScheme.secondary),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // Built-in modality section (unchanged logic)
  // =========================================================================

  Widget _buildModalitySection(
    ModalityType type,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    final hasValue = _modelControllers[type]!.text.trim().isNotEmpty;
    final showAdv = _showAdvanced[type] ?? false;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasValue
            ? colorScheme.primaryContainer.withValues(alpha: 0.15)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasValue
              ? colorScheme.primary.withValues(alpha: 0.3)
              : colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Modality header
          Row(
            children: [
              Icon(_modalityIcon(type), size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                _modalityLabel(type, l10n),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (hasValue)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.modelRouting_configured,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                )
              else
                Text(
                  l10n.modelRouting_usingDefault,
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Quick-select from ModelRegistry
          _buildModelQuickSelect(
            modelDefs: ModelRegistry.instance.definitions,
            colorScheme: colorScheme,
            l10n: l10n,
            onSelected: (def) {
              setState(() {
                _modelControllers[type]!.text = def.route.model ?? '';
                if (def.route.provider != null) {
                  _providerControllers[type]!.text = def.route.provider!;
                }
                if (def.route.apiBase != null) {
                  _apiBaseControllers[type]!.text = def.route.apiBase!;
                }
                if (def.route.apiKey != null) {
                  _apiKeyControllers[type]!.text = def.route.apiKey!;
                }
                _showAdvanced[type] = true;
              });
              _notifyChanged();
            },
          ),

          // Model name field
          TextFormField(
            controller: _modelControllers[type],
            decoration: InputDecoration(
              hintText: l10n.modelRouting_modelHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.memory, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) {
              setState(() {});
              _notifyChanged();
            },
          ),

          // Advanced toggle
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              setState(() {
                _showAdvanced[type] = !showAdv;
              });
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showAdv ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    l10n.modelRouting_advanced,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (showAdv) ...[
            const SizedBox(height: 4),
            // Provider type
            TextFormField(
              controller: _providerControllers[type],
              decoration: InputDecoration(
                hintText: l10n.modelRouting_providerHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.cloud, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // API Base
            TextFormField(
              controller: _apiBaseControllers[type],
              decoration: InputDecoration(
                hintText: l10n.modelRouting_apiBaseHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.language, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // API Key
            TextFormField(
              controller: _apiKeyControllers[type],
              decoration: InputDecoration(
                hintText: l10n.modelRouting_apiKeyHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                suffixIcon: IconButton(
                  icon: Icon(
                    (_obscureApiKey[type] ?? true)
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 18,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureApiKey[type] = !(_obscureApiKey[type] ?? true);
                    });
                  },
                ),
              ),
              style: const TextStyle(fontSize: 13),
              obscureText: _obscureApiKey[type] ?? true,
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // Stream toggle
            SwitchListTile(
              title: Text(
                l10n.modelRouting_enableStreaming,
                style: const TextStyle(fontSize: 13),
              ),
              value: _streamEnabled[type] ?? true,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (val) {
                setState(() {
                  _streamEnabled[type] = val;
                });
                _notifyChanged();
              },
            ),
            // Non-SSE specific fields (shown when stream is off)
            if (!(_streamEnabled[type] ?? true)) ...[
              const SizedBox(height: 4),
              // API Path
              TextFormField(
                controller: _apiPathControllers[type],
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_apiPathHint,
                  labelText: l10n.modelRouting_apiPath,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.link, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 8),
              // Request Body Template
              TextFormField(
                controller: _requestBodyTemplateControllers[type],
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_requestBodyTemplateHint,
                  labelText: l10n.modelRouting_requestBodyTemplate,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.code, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                maxLines: 3,
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 8),
              // Response Body Path
              TextFormField(
                controller: _responseBodyPathControllers[type],
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_responseBodyPathHint,
                  labelText: l10n.modelRouting_responseBodyPath,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.output, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => _notifyChanged(),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // =========================================================================
  // Custom modalities section
  // =========================================================================

  Widget _buildCustomModalitiesSection(
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.extension, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              l10n.modelRouting_customModalities,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.modelRouting_customModalitiesHint,
          style: TextStyle(fontSize: 11, color: colorScheme.outline),
        ),
        const SizedBox(height: 8),

        // Existing custom modality entries
        for (int i = 0; i < _customModalityStates.length; i++) ...[
          _buildCustomModalityEntry(i, colorScheme, l10n),
          const SizedBox(height: 8),
        ],

        // Add button
        OutlinedButton.icon(
          onPressed: () {
            setState(() {
              _customModalityStates.add(_CustomModalityState());
            });
          },
          icon: const Icon(Icons.add, size: 16),
          label: Text(l10n.modelRouting_addCustomModality),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomModalityEntry(
    int index,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    final state = _customModalityStates[index];
    final hasValue = state.keyController.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasValue
            ? colorScheme.tertiaryContainer.withValues(alpha: 0.15)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasValue
              ? colorScheme.tertiary.withValues(alpha: 0.3)
              : colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with delete button
          Row(
            children: [
              Icon(Icons.extension, size: 16, color: colorScheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.keyController.text.trim().isNotEmpty
                      ? (state.labelController.text.trim().isNotEmpty ? state.labelController.text.trim() : state.keyController.text.trim())
                      : l10n.modelRouting_addCustomModality,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 18, color: colorScheme.error),
                tooltip: l10n.modelRouting_deleteModality,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _customModalityStates[index].dispose();
                    _customModalityStates.removeAt(index);
                  });
                  _notifyChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Key field
          TextFormField(
            controller: state.keyController,
            decoration: InputDecoration(
              hintText: l10n.modelRouting_modalityKeyHint,
              labelText: l10n.modelRouting_modalityKey,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.vpn_key, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) {
              setState(() {});
              _notifyChanged();
            },
          ),
          const SizedBox(height: 8),

          // Label field
          TextFormField(
            controller: state.labelController,
            decoration: InputDecoration(
              hintText: l10n.modelRouting_modalityLabelHint,
              labelText: l10n.modelRouting_modalityLabel,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.label, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) {
              setState(() {});
              _notifyChanged();
            },
          ),
          const SizedBox(height: 8),

          // Description field
          TextFormField(
            controller: state.descriptionController,
            decoration: InputDecoration(
              hintText: l10n.modelRouting_modalityDescriptionHint,
              labelText: l10n.modelRouting_modalityDescription,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.description, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(fontSize: 13),
            maxLines: 2,
            onChanged: (_) => _notifyChanged(),
          ),
          const SizedBox(height: 8),

          // Quick-select from ModelRegistry
          _buildModelQuickSelect(
            modelDefs: ModelRegistry.instance.definitions,
            colorScheme: colorScheme,
            l10n: l10n,
            onSelected: (def) {
              setState(() {
                state.modelController.text = def.route.model ?? '';
                if (def.route.provider != null) {
                  state.providerController.text = def.route.provider!;
                }
                if (def.route.apiBase != null) {
                  state.apiBaseController.text = def.route.apiBase!;
                }
                if (def.route.apiKey != null) {
                  state.apiKeyController.text = def.route.apiKey!;
                }
                state.showAdvanced = true;
              });
              _notifyChanged();
            },
          ),

          // Model field
          TextFormField(
            controller: state.modelController,
            decoration: InputDecoration(
              hintText: l10n.modelRouting_modelHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.memory, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) => _notifyChanged(),
          ),

          // Advanced toggle
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              setState(() {
                state.showAdvanced = !state.showAdvanced;
              });
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    state.showAdvanced ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    l10n.modelRouting_advanced,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (state.showAdvanced) ...[
            const SizedBox(height: 4),
            // Provider
            TextFormField(
              controller: state.providerController,
              decoration: InputDecoration(
                hintText: l10n.modelRouting_providerHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.cloud, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // API Base
            TextFormField(
              controller: state.apiBaseController,
              decoration: InputDecoration(
                hintText: l10n.modelRouting_apiBaseHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.language, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // API Key
            TextFormField(
              controller: state.apiKeyController,
              decoration: InputDecoration(
                hintText: l10n.modelRouting_apiKeyHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key, size: 18),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                suffixIcon: IconButton(
                  icon: Icon(
                    state.obscureApiKey
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 18,
                  ),
                  onPressed: () {
                    setState(() {
                      state.obscureApiKey = !state.obscureApiKey;
                    });
                  },
                ),
              ),
              style: const TextStyle(fontSize: 13),
              obscureText: state.obscureApiKey,
              onChanged: (_) => _notifyChanged(),
            ),
            const SizedBox(height: 8),
            // Stream toggle
            SwitchListTile(
              title: Text(
                l10n.modelRouting_enableStreaming,
                style: const TextStyle(fontSize: 13),
              ),
              value: state.streamEnabled,
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (val) {
                setState(() {
                  state.streamEnabled = val;
                });
                _notifyChanged();
              },
            ),
            // Non-SSE fields
            if (!state.streamEnabled) ...[
              const SizedBox(height: 4),
              TextFormField(
                controller: state.apiPathController,
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_apiPathHint,
                  labelText: l10n.modelRouting_apiPath,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.link, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: state.requestBodyTemplateController,
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_requestBodyTemplateHint,
                  labelText: l10n.modelRouting_requestBodyTemplate,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.code, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                maxLines: 3,
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: state.responseBodyPathController,
                decoration: InputDecoration(
                  hintText: l10n.modelRouting_responseBodyPathHint,
                  labelText: l10n.modelRouting_responseBodyPath,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.output, size: 18),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => _notifyChanged(),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
