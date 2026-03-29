import 'dart:convert';

/// 工具全局配置 - 存储单个工具的配置元数据（API Key 单独存于 SecureKeyManager）
class ToolConfig {
  /// 工具名称（如 'web_search', 'web_fetch'），同时作为主键
  final String toolName;

  /// 是否已配置 API Key（实际 Key 存于 SecureKeyManager，此处仅标记状态）
  final bool hasApiKey;

  /// 工具参数覆盖（JSON 对象，覆盖 LLM 调用时传入的默认值）
  /// 例如: { "timeout": 60, "max_results": 20 }
  final Map<String, dynamic>? parameterOverrides;

  /// 全局启用/禁用开关
  final bool enabled;

  /// 备注说明
  final String? note;

  /// 创建时间（毫秒时间戳）
  final int createdAt;

  /// 更新时间（毫秒时间戳）
  final int updatedAt;

  const ToolConfig({
    required this.toolName,
    this.hasApiKey = false,
    this.parameterOverrides,
    this.enabled = true,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 拷贝并修改部分字段
  ToolConfig copyWith({
    bool? hasApiKey,
    Map<String, dynamic>? parameterOverrides,
    bool? enabled,
    String? note,
    int? updatedAt,
    // 使用 sentinel 表示显式清空
    bool clearParameterOverrides = false,
    bool clearNote = false,
  }) {
    return ToolConfig(
      toolName: toolName,
      hasApiKey: hasApiKey ?? this.hasApiKey,
      parameterOverrides: clearParameterOverrides
          ? null
          : (parameterOverrides ?? this.parameterOverrides),
      enabled: enabled ?? this.enabled,
      note: clearNote ? null : (note ?? this.note),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // ── 序列化 ──────────────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'tool_name': toolName,
        'has_api_key': hasApiKey ? 1 : 0,
        'parameter_overrides': parameterOverrides != null
            ? jsonEncode(parameterOverrides)
            : null,
        'enabled': enabled ? 1 : 0,
        'note': note,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ToolConfig.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? overrides;
    final raw = json['parameter_overrides'];
    if (raw != null && raw is String && raw.isNotEmpty) {
      try {
        overrides = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }

    return ToolConfig(
      toolName: json['tool_name'] as String,
      hasApiKey: (json['has_api_key'] as int? ?? 0) == 1,
      parameterOverrides: overrides,
      enabled: (json['enabled'] as int? ?? 1) == 1,
      note: json['note'] as String?,
      createdAt: json['created_at'] as int,
      updatedAt: json['updated_at'] as int,
    );
  }

  @override
  String toString() =>
      'ToolConfig(toolName: $toolName, hasApiKey: $hasApiKey, '
      'enabled: $enabled)';
}
