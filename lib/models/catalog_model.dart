import 'model_definition.dart';

/// 官方模型目录条目（channel 服务 `GET /api/v1/models` 返回）。
///
/// 字段与后端 `LLMModel` 对齐：
/// - [provider] 为运行时 providerType（openai/claude/glm/...）
/// - [providerLabel] 为服务商展示名（OpenAI/DeepSeek/...），用于匹配
///   `llmProviders[].name` 自动带出服务商预设
/// - [modelTypes] 为该模型支持的能力类型
class CatalogModel {
  final String id;
  final String provider;
  final String providerLabel;
  final String name;
  final String displayName;
  final String description;
  final String apiBase;
  final bool requiresApiKey;
  final Set<ModelType> modelTypes;
  final bool stream;
  final String? apiPath;
  final String? requestBodyTemplate;
  final String? responseBodyPath;

  const CatalogModel({
    required this.id,
    required this.provider,
    required this.providerLabel,
    required this.name,
    required this.displayName,
    required this.description,
    required this.apiBase,
    required this.requiresApiKey,
    this.modelTypes = const {},
    this.stream = true,
    this.apiPath,
    this.requestBodyTemplate,
    this.responseBodyPath,
  });

  factory CatalogModel.fromJson(Map<String, dynamic> json) {
    final rawTypes = json['modelTypes'] as List<dynamic>? ?? const [];
    final types = rawTypes
        .map((e) => ModelType.fromJson(e as String?))
        .whereType<ModelType>()
        .toSet();

    String? nullableString(dynamic v) {
      final s = v as String?;
      return (s == null || s.isEmpty) ? null : s;
    }

    return CatalogModel(
      id: json['id'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      providerLabel: json['providerLabel'] as String? ?? '',
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      description: json['description'] as String? ?? '',
      apiBase: json['apiBase'] as String? ?? '',
      requiresApiKey: json['requiresApiKey'] as bool? ?? true,
      modelTypes: types,
      stream: json['stream'] as bool? ?? true,
      apiPath: nullableString(json['apiPath']),
      requestBodyTemplate: nullableString(json['requestBodyTemplate']),
      responseBodyPath: nullableString(json['responseBodyPath']),
    );
  }
}
