import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../widgets/model_icon.dart';
import '../models/llm_provider_config.dart';
import '../models/model_definition.dart';
import '../models/model_routing_config.dart';
import '../models/remote_agent.dart' show repairUtf16Garbled;
import '../services/model_registry.dart';
import '../services/openrouter_service.dart';
import '../services/logger_service.dart';

/// Dedicated management screen for global model definitions.
class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({super.key});

  @override
  State<ModelManagementScreen> createState() =>
      _ModelManagementScreenState();
}

class _ModelManagementScreenState
    extends State<ModelManagementScreen> {
  // ---------------------------------------------------------------------------
  // Add / Edit
  // ---------------------------------------------------------------------------

  Future<void> _addOrEdit({ModelDefinition? existing}) async {
    final result = await Navigator.push<ModelDefinition>(
      context,
      MaterialPageRoute(
        builder: (_) => ModelEditScreen(existing: existing),
      ),
    );
    if (result != null && mounted) {
      if (existing != null) {
        await ModelRegistry.instance.update(result);
      } else {
        await ModelRegistry.instance.add(
          displayName: result.displayName,
          description: result.description,
          route: result.route,
          modelTypes: result.modelTypes,
        );
      }
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  Future<void> _delete(ModelDefinition def) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.toolModel_deleteTitle),
        content: Text(l10n.toolModel_deleteContent(def.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.common_delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ModelRegistry.instance.delete(def.id);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.toolModel_deleted(def.displayName)),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final defs = ModelRegistry.instance.definitions;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.toolModel_managementTitle),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addOrEdit(),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (defs.isEmpty)
            _buildEmptyState(colorScheme, l10n)
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.toolModel_count(defs.length),
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.outline,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ...defs.map((def) => _buildCard(def, colorScheme, l10n)),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          ModelIcon(
              size: 64,
              color: colorScheme.outline.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            l10n.toolModel_noModels,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.toolModel_noModelsHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.outline.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    ModelDefinition def,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _addOrEdit(existing: def),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ModelIcon(size: 20, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      def.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 20, color: colorScheme.error),
                    tooltip: l10n.common_delete,
                    onPressed: () => _delete(def),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                  ),
                ],
              ),
              if (def.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  def.description,
                  style: TextStyle(fontSize: 13, color: colorScheme.outline),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  if (def.route.model != null && def.route.model!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.tertiaryContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        def.route.model!,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                ],
              ),
              if (def.modelTypes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: def.modelTypes.map((t) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _modelTypeLabel(t, l10n),
                        style: TextStyle(
                          fontSize: 10,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _modelTypeLabel(ModelType type, AppLocalizations l10n) {
    switch (type) {
      case ModelType.text:
        return l10n.modelType_text;
      case ModelType.imageUnderstanding:
        return l10n.modelType_imageUnderstanding;
      case ModelType.audioUnderstanding:
        return l10n.modelType_audioUnderstanding;
      case ModelType.videoUnderstanding:
        return l10n.modelType_videoUnderstanding;
      case ModelType.imageGeneration:
        return l10n.modelType_imageGeneration;
      case ModelType.tts:
        return l10n.modelType_tts;
      case ModelType.videoGeneration:
        return l10n.modelType_videoGeneration;
    }
  }
}

// =============================================================================
// Edit screen for a single model definition (public for reuse)
// =============================================================================

class ModelEditScreen extends StatefulWidget {
  final ModelDefinition? existing;

  const ModelEditScreen({super.key, this.existing});

  @override
  State<ModelEditScreen> createState() => _ModelEditScreenState();
}

class _ModelEditScreenState extends State<ModelEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _displayNameController;
  late TextEditingController _descriptionController;
  late TextEditingController _providerController;
  late TextEditingController _modelController;
  late TextEditingController _apiBaseController;
  late TextEditingController _apiKeyController;
  late TextEditingController _requestBodyTemplateController;
  late TextEditingController _responseBodyPathController;
  bool _streamEnabled = true;
  bool _obscureApiKey = true;

  /// Index into [llmProviders], or -1 for "custom" (no preset selected).
  int _selectedProviderIndex = -1;

  /// Model types selected for this definition (multi-select).
  late Set<ModelType> _selectedModelTypes;

  // ── OpenRouter 模型列表相关 ──────────────────────────
  late OpenRouterService _openRouterService;
  bool _loadingModels = false;
  String? _modelsError;

  // ── Provider API Key 缓存 ─────────────────────────────
  /// SharedPreferences key 前缀，按 apiBase 存储 API Key
  static const String _apiKeyCachePrefix = 'provider_api_key_';

  @override
  void initState() {
    super.initState();
    _openRouterService = OpenRouterService();

    final e = widget.existing;
    _displayNameController = TextEditingController(text: e?.displayName ?? '');
    _descriptionController = TextEditingController(text: e?.description ?? '');
    _providerController =
        TextEditingController(text: e?.route.provider ?? '');
    _modelController = TextEditingController(text: e?.route.model ?? '');
    _apiBaseController = TextEditingController(text: e?.route.apiBase ?? '');
    _apiKeyController = TextEditingController(text: e?.route.apiKey ?? '');
    _requestBodyTemplateController =
        TextEditingController(text: e?.route.requestBodyTemplate ?? '');
    _responseBodyPathController =
        TextEditingController(text: e?.route.responseBodyPath ?? '');
    _streamEnabled = e?.route.stream ?? true;
    _selectedModelTypes = Set<ModelType>.from(e?.modelTypes ?? {});
    _apiKeyController.addListener(_repairApiKeyIfGarbled);

    // Pre-select provider chip if editing an existing model.
    // Priority: match by apiBase first (exact), then fall back to providerType.
    // This avoids mismatching providers that share the same providerType (e.g.
    // Kimi and OpenAI both use providerType="openai").
    if (e != null) {
      final providerType = e.route.provider;
      final apiBase = e.route.apiBase;
      if (providerType != null || apiBase != null) {
        // 1st pass: exact apiBase match
        if (apiBase != null) {
          for (int i = 0; i < llmProviders.length; i++) {
            if (llmProviders[i].defaultApiBase == apiBase) {
              _selectedProviderIndex = i;
              break;
            }
          }
        }
        // 2nd pass: providerType match (only if no apiBase match found)
        if (_selectedProviderIndex == -1 && providerType != null) {
          for (int i = 0; i < llmProviders.length; i++) {
            if (llmProviders[i].providerType == providerType) {
              _selectedProviderIndex = i;
              break;
            }
          }
        }
      }
    }
  }

  void _repairApiKeyIfGarbled() {
    final text = _apiKeyController.text;
    final repaired = repairUtf16Garbled(text);
    if (repaired != text) {
      _apiKeyController.value = TextEditingValue(
        text: repaired,
        selection: TextSelection.collapsed(offset: repaired.length),
      );
    }
  }

  void _selectProvider(int index) {
    setState(() {
      _selectedProviderIndex = index;
      final provider = llmProviders[index];
      _apiBaseController.text = provider.defaultApiBase;
      _providerController.text = provider.providerType;
      if (!provider.requiresApiKey) {
        _apiKeyController.clear();
      }
      // 清除之前的 OpenRouter 错误信息
      _modelsError = null;
      _loadingModels = false;
    });

    // 如果当前没有 API Key，尝试从缓存回填
    if (_apiKeyController.text.trim().isEmpty) {
      _loadCachedApiKey(llmProviders[index].defaultApiBase);
    }
  }

  /// 从 SharedPreferences 读取该 provider 缓存的 API Key 并回填
  Future<void> _loadCachedApiKey(String apiBase) async {
    // 优先从已有的 ModelDefinition 中找同 apiBase 的 Key
    for (final def in ModelRegistry.instance.definitions) {
      final key = def.route.apiKey ?? '';
      if (def.route.apiBase == apiBase && key.isNotEmpty) {
        if (mounted) setState(() => _apiKeyController.text = key);
        return;
      }
    }

    // 降级：查 SharedPreferences 缓存
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('$_apiKeyCachePrefix$apiBase') ?? '';
      if (cached.isNotEmpty && mounted) {
        setState(() => _apiKeyController.text = cached);
      }
    } catch (_) {}
  }

  /// 将当前 API Key 缓存到 SharedPreferences
  Future<void> _saveApiKeyCache(String apiBase, String apiKey) async {
    if (apiKey.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_apiKeyCachePrefix$apiBase', apiKey.trim());
    } catch (_) {}
  }

  /// 获取 OpenRouter 模型列表
  Future<void> _fetchOpenRouterModels() async {
    if (_apiKeyController.text.trim().isEmpty) {
      setState(() {
        _modelsError = '请先填写 OpenRouter API Key';
      });
      return;
    }

    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final models = await _openRouterService.getModels(
        forceRefresh: true,
        apiKey: _apiKeyController.text.trim(),
      );

      setState(() {
        _loadingModels = false;
      });

      if (mounted) {
        _showModelSelectionDialog(models);
      }
    } catch (e) {
      setState(() {
        _modelsError = e is FormatException
            ? e.message
            : '获取模型失败: ${e.toString()}';
        _loadingModels = false;
      });
      LoggerService().error('获取 OpenRouter 模型失败', tag: 'ModelEdit', error: e);
    }
  }

  /// 显示模型选择对话框
  void _showModelSelectionDialog(List<OpenRouterModel> models) {
    showDialog(
      context: context,
      builder: (context) => _ModelPickerDialog(
        models: models,
        onSelected: (model) {
          _modelController.text = model.id;
          if (_displayNameController.text.trim().isEmpty) {
            _displayNameController.text = model.name;
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.removeListener(_repairApiKeyIfGarbled);
    _displayNameController.dispose();
    _descriptionController.dispose();
    _providerController.dispose();
    _modelController.dispose();
    _apiBaseController.dispose();
    _apiKeyController.dispose();
    _requestBodyTemplateController.dispose();
    _responseBodyPathController.dispose();
    _openRouterService.close();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final apiBase = _apiBaseController.text.trim();
    final apiKey = repairUtf16Garbled(_apiKeyController.text.trim());

    // 有 apiBase + apiKey 时，缓存该 provider 的 API Key
    if (apiBase.isNotEmpty && apiKey.isNotEmpty) {
      _saveApiKeyCache(apiBase, apiKey);
    }

    final route = ModelRouteConfig(
      provider: _providerController.text.trim().isEmpty
          ? null
          : _providerController.text.trim(),
      model: _modelController.text.trim().isEmpty
          ? null
          : _modelController.text.trim(),
      apiBase: apiBase.isEmpty ? null : apiBase,
      apiKey: apiKey.isEmpty ? null : apiKey,
      stream: _streamEnabled ? null : false,
      apiPath: null,
      requestBodyTemplate:
          _requestBodyTemplateController.text.trim().isEmpty
              ? null
              : _requestBodyTemplateController.text.trim(),
      responseBodyPath: _responseBodyPathController.text.trim().isEmpty
          ? null
          : _responseBodyPathController.text.trim(),
    );

    final displayName = _displayNameController.text.trim();
    final toolName = widget.existing?.toolName ??
        ModelDefinition.deriveToolName(displayName);

    final result = ModelDefinition(
      id: widget.existing?.id ?? const Uuid().v4(),
      toolName: toolName,
      displayName: displayName,
      description: _descriptionController.text.trim(),
      route: route,
      modelTypes: _selectedModelTypes,
    );

    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final isEditing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing
            ? l10n.toolModel_editTitle
            : l10n.toolModel_addTitle),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Provider selection ───────────────────────────────────
              Text(
                l10n.toolModel_selectProvider,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.outline,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(llmProviders.length, (index) {
                  final provider = llmProviders[index];
                  final isSelected = _selectedProviderIndex == index;
                  return ChoiceChip(
                    label: Text('${provider.icon} ${provider.name}'),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        _selectProvider(index);
                      } else {
                        setState(() {
                          _selectedProviderIndex = -1;
                        });
                      }
                    },
                    selectedColor: colorScheme.primaryContainer,
                    showCheckmark: false,
                    avatar: isSelected
                        ? Icon(Icons.check_circle,
                            size: 16, color: colorScheme.primary)
                        : null,
                  );
                }),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // ── Display Name ─────────────────────────────────────────
              TextFormField(
                controller: _displayNameController,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_displayName,
                  hintText: l10n.toolModel_displayNameHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.label),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l10n.toolModel_displayNameRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),

              // ── Description ──────────────────────────────────────────
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_description,
                  hintText: l10n.toolModel_descriptionHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.description),
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
                minLines: 2,
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // ── Model Types ──────────────────────────────────────────
              Text(
                l10n.modelType_sectionLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.outline,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.modelType_sectionHint,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.outline.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ModelType.values.map((type) {
                  final selected = _selectedModelTypes.contains(type);
                  return FilterChip(
                    label: Text(_modelTypeLabel(type, l10n)),
                    selected: selected,
                    showCheckmark: true,
                    onSelected: (val) {
                      setState(() {
                        if (val) {
                          _selectedModelTypes.add(type);
                        } else {
                          _selectedModelTypes.remove(type);
                        }
                      });
                    },
                    selectedColor: colorScheme.primaryContainer,
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // ── Model ────────────────────────────────────────────────
              TextFormField(
                controller: _modelController,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_model,
                  hintText: l10n.toolModel_modelHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.memory),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l10n.toolModel_modelRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),

              // ── OpenRouter 模型列表获取按钮 ──────────────────────
              if (_selectedProviderIndex >= 0 &&
                  llmProviders[_selectedProviderIndex].name == 'OpenRouter')
                Column(
                  children: [
                    if (_modelsError != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer.withValues(alpha: 0.3),
                          border: Border.all(
                            color: colorScheme.error,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                size: 16, color: colorScheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _modelsError!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.error,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_modelsError != null)
                      const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loadingModels ? null : _fetchOpenRouterModels,
                        icon: _loadingModels
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation(colorScheme.primary),
                                ),
                              )
                            : const Icon(Icons.cloud_download),
                        label: Text(_loadingModels ? '获取中...' : '获取 OpenRouter 模型列表'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),

              // ── API Base ─────────────────────────────────────────────
              TextFormField(
                controller: _apiBaseController,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_apiBase,
                  hintText: l10n.toolModel_apiBaseHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.language),
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l10n.toolModel_apiBaseRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),

              // ── API Key ──────────────────────────────────────────────
              TextFormField(
                controller: _apiKeyController,
                decoration: InputDecoration(
                  labelText: l10n.toolModel_apiKey,
                  hintText: l10n.toolModel_apiKeyHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureApiKey
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureApiKey = !_obscureApiKey;
                      });
                    },
                  ),
                ),
                obscureText: _obscureApiKey,
                enableSuggestions: false,
                autocorrect: false,
              ),
              const SizedBox(height: 12),

              // ── Stream toggle ────────────────────────────────────────
              SwitchListTile(
                title: Text(l10n.modelRouting_enableStreaming),
                value: _streamEnabled,
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (val) => setState(() => _streamEnabled = val),
              ),

              // ── Non-SSE fields (shown when stream is disabled) ───────
              if (!_streamEnabled) ...[
                const SizedBox(height: 12),

                // Request Body Template
                TextFormField(
                  controller: _requestBodyTemplateController,
                  decoration: InputDecoration(
                    labelText: l10n.modelRouting_requestBodyTemplate,
                    hintText: l10n.modelRouting_requestBodyTemplateHint,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.code),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  minLines: 2,
                ),
                const SizedBox(height: 12),

                // Response Body Path
                TextFormField(
                  controller: _responseBodyPathController,
                  decoration: InputDecoration(
                    labelText: l10n.modelRouting_responseBodyPath,
                    hintText: l10n.modelRouting_responseBodyPathHint,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.output),
                  ),
                ),
              ],

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  String _modelTypeLabel(ModelType type, AppLocalizations l10n) {
    switch (type) {
      case ModelType.text:
        return l10n.modelType_text;
      case ModelType.imageUnderstanding:
        return l10n.modelType_imageUnderstanding;
      case ModelType.audioUnderstanding:
        return l10n.modelType_audioUnderstanding;
      case ModelType.videoUnderstanding:
        return l10n.modelType_videoUnderstanding;
      case ModelType.imageGeneration:
        return l10n.modelType_imageGeneration;
      case ModelType.tts:
        return l10n.modelType_tts;
      case ModelType.videoGeneration:
        return l10n.modelType_videoGeneration;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OpenRouter 模型选择对话框（带搜索）
// ─────────────────────────────────────────────────────────────────────────────

class _ModelPickerDialog extends StatefulWidget {
  final List<OpenRouterModel> models;
  final void Function(OpenRouterModel) onSelected;

  const _ModelPickerDialog({
    required this.models,
    required this.onSelected,
  });

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  late List<OpenRouterModel> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.models;
    _searchController.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearch);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = widget.models;
      } else {
        _filtered = widget.models.where((m) {
          return m.id.toLowerCase().contains(query) ||
              m.name.toLowerCase().contains(query) ||
              (m.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('选择 OpenRouter 模型'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 搜索框 ────────────────────────────────────────────
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '搜索模型名称或 ID...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _searchController.clear(),
                      )
                    : null,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${_filtered.length} / ${widget.models.length} 个模型',
                style: TextStyle(fontSize: 11, color: colorScheme.outline),
              ),
            ),
            const SizedBox(height: 4),
            // ── 模型列表 ──────────────────────────────────────────
            Flexible(
              child: _filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '无匹配模型',
                        style: TextStyle(color: colorScheme.outline),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final model = _filtered[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            model.name,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            model.description ?? model.id,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: model.modality != null
                              ? Chip(
                                  label: Text(
                                    model.modality!,
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: EdgeInsets.zero,
                                  labelPadding: const EdgeInsets.symmetric(
                                      horizontal: 6),
                                )
                              : null,
                          onTap: () {
                            widget.onSelected(model);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
