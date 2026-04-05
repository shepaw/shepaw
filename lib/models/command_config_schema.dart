import 'cli_config_field.dart';

/// 命令的完整配置 Schema 定义
///
/// 每个 CLI 命令（如 BraveSearchCommand）可定义一个 [CommandConfigSchema]，
/// 描述该命令需要哪些配置项、每项的类型、必填性、验证规则等。
///
/// Schema 存在命令类内部，独立管理。CLI 框架和 UI 会根据此 schema
/// 自动渲染表单、执行验证、注入配置值。
///
/// 使用示例：
/// ```dart
/// class BraveSearchCommand extends CliCommand {
///   @override
///   CommandConfigSchema? get configSchema => _braveSearchSchema;
///
///   static final _braveSearchSchema = CommandConfigSchema(
///     toolName: 'brave_search',
///     displayName: 'Brave Search',
///     description: 'Search the web using Brave Search API',
///     fields: [
///       CliConfigField(
///         key: 'api_key',
///         label: 'API Key',
///         type: CliConfigFieldType.secret,
///         required: true,
///         description: 'Your Brave Search API key (starts with BSA-)',
///       ),
///       CliConfigField(
///         key: 'timeout',
///         label: 'Timeout',
///         type: CliConfigFieldType.integer,
///         description: 'Request timeout in seconds',
///         defaultValue: 30,
///       ),
///     ],
///   );
/// }
/// ```
class CommandConfigSchema {
  /// 工具唯一标识符
  ///
  /// 用于在 SecureKeyManager 和 SQLite 中查询/存储配置。
  /// 示例: 'brave_search', 'tavily_search', 'web_fetch', 'email_sender'
  final String toolName;

  /// 工具的显示名称（用于 UI）
  ///
  /// 示例: 'Brave Search', 'Tavily Search', 'Web Fetch'
  final String displayName;

  /// 工具的详细描述
  final String? description;

  /// 该工具需要配置的所有字段列表
  ///
  /// 每个字段定义了其类型、必填性、验证规则等。
  /// 框架会按此列表顺序在 UI 中渲染表单项。
  final List<CliConfigField> fields;

  const CommandConfigSchema({
    required this.toolName,
    required this.displayName,
    required this.fields,
    this.description,
  });

  /// 获取所有必填字段
  List<CliConfigField> get requiredFields =>
      fields.where((f) => f.required).toList();

  /// 获取所有 secret 类型的字段
  List<CliConfigField> get secretFields =>
      fields.where((f) => f.type == CliConfigFieldType.secret).toList();

  /// 根据字段 key 查找字段定义
  CliConfigField? findField(String key) {
    try {
      return fields.firstWhere((f) => f.key == key);
    } catch (_) {
      return null;
    }
  }

  /// 验证完整的配置数据
  ///
  /// 返回: Map<字段key, List<错误信息>>
  /// 如果返回 empty map，则表示验证通过。
  Map<String, List<String>> validateConfig(Map<String, dynamic> config) {
    final errors = <String, List<String>>{};

    for (final field in fields) {
      final fieldErrors = _validateField(field, config[field.key]);
      if (fieldErrors.isNotEmpty) {
        errors[field.key] = fieldErrors;
      }
    }

    return errors;
  }

  /// 验证单个字段
  List<String> _validateField(
    CliConfigField field,
    dynamic value,
  ) {
    final errors = <String>[];

    // 必填检查
    if (field.required && (value == null || value.toString().isEmpty)) {
      errors.add('${field.label} is required');
      return errors;
    }

    // 如果非必填且值为空，直接返回
    if (!field.required && (value == null || value.toString().isEmpty)) {
      return errors;
    }

    // 类型特定验证
    switch (field.type) {
      case CliConfigFieldType.secret:
      case CliConfigFieldType.string:
        errors.addAll(_validateString(field, value));
        break;

      case CliConfigFieldType.integer:
        errors.addAll(_validateInteger(field, value));
        break;

      case CliConfigFieldType.doubleNum:
        errors.addAll(_validateDouble(field, value));
        break;

      case CliConfigFieldType.boolean:
        errors.addAll(_validateBoolean(field, value));
        break;

      case CliConfigFieldType.select:
        errors.addAll(_validateSelect(field, value));
        break;
    }

    return errors;
  }

  /// 验证字符串字段
  List<String> _validateString(CliConfigField field, dynamic value) {
    // 长度验证和正则验证可在 CliConfigField 中扩展后在此添加
    return [];
  }

  /// 验证整数字段
  List<String> _validateInteger(CliConfigField field, dynamic value) {
    final errors = <String>[];

    if (value is! int) {
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed == null) {
          errors.add('${field.label} must be an integer');
        }
      } else if (value is double) {
        // 允许浮点数自动转为整数
      } else {
        errors.add('${field.label} must be an integer');
      }
    }

    return errors;
  }

  /// 验证浮点数字段
  List<String> _validateDouble(CliConfigField field, dynamic value) {
    final errors = <String>[];

    if (value is! double && value is! int) {
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed == null) {
          errors.add('${field.label} must be a number');
        }
      } else {
        errors.add('${field.label} must be a number');
      }
    }

    return errors;
  }

  /// 验证布尔字段
  List<String> _validateBoolean(CliConfigField field, dynamic value) {
    final errors = <String>[];

    if (value is! bool) {
      if (value is String) {
        if (value.toLowerCase() != 'true' && value.toLowerCase() != 'false') {
          errors.add('${field.label} must be true or false');
        }
      } else if (value is! int) {
        errors.add('${field.label} must be boolean');
      }
    }

    return errors;
  }

  /// 验证选择字段
  List<String> _validateSelect(CliConfigField field, dynamic value) {
    final errors = <String>[];

    if (field.options != null && field.options!.isNotEmpty) {
      final strValue = value.toString();
      if (!field.options!.contains(strValue)) {
        errors.add(
          '${field.label} must be one of: ${field.options!.join(", ")}',
        );
      }
    }

    return errors;
  }

  /// 生成 CLI 帮助文本
  String generateHelpText() {
    final buf = StringBuffer();
    buf.writeln('Configuration Schema: $displayName\n');

    if (description != null && description!.isNotEmpty) {
      buf.writeln('Description: $description\n');
    }

    buf.writeln('Fields:');
    for (final field in fields) {
      final required = field.required ? ' [REQUIRED]' : ' [optional]';
      final typeStr = _fieldTypeString(field.type);

      buf.writeln('  ${field.key}$required');
      buf.writeln('    Type: $typeStr');
      buf.writeln('    Label: ${field.label}');

      if (field.description.isNotEmpty) {
        buf.writeln('    Description: ${field.description}');
      }

      if (field.defaultValue != null) {
        buf.writeln('    Default: ${field.defaultValue}');
      }

      if (field.options != null && field.options!.isNotEmpty) {
        buf.writeln('    Options: ${field.options!.join(", ")}');
      }

      buf.writeln();
    }

    return buf.toString();
  }

  /// 将字段类型转换为字符串表示
  String _fieldTypeString(CliConfigFieldType type) {
    switch (type) {
      case CliConfigFieldType.secret:
        return 'secret (stored securely in OS Keychain/Keystore)';
      case CliConfigFieldType.string:
        return 'string';
      case CliConfigFieldType.integer:
        return 'integer';
      case CliConfigFieldType.doubleNum:
        return 'double';
      case CliConfigFieldType.boolean:
        return 'boolean';
      case CliConfigFieldType.select:
        return 'select';
    }
  }

  /// 转换为 JSON（用于序列化、UI 表单生成等）
  Map<String, dynamic> toJson() => {
        'tool_name': toolName,
        'display_name': displayName,
        'description': description,
        'fields': [
          for (final field in fields)
            {
              'key': field.key,
              'label': field.label,
              'type': field.type.toString().split('.').last,
              'description': field.description,
              'required': field.required,
              'defaultValue': field.defaultValue,
              'options': field.options,
            }
        ],
      };

  /// 从 JSON 构建（可选，用于从数据源加载 schema）
  factory CommandConfigSchema.fromJson(Map<String, dynamic> json) {
    final fieldsList = (json['fields'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

    final fields = fieldsList.map((fieldJson) {
      // 将字符串类型转回枚举
      final typeStr = fieldJson['type'] as String?;
      final type = _parseFieldType(typeStr ?? 'string');

      return CliConfigField(
        key: fieldJson['key'] as String,
        label: fieldJson['label'] as String,
        description: fieldJson['description'] as String? ?? '',
        type: type,
        required: fieldJson['required'] as bool? ?? false,
        defaultValue: fieldJson['defaultValue'],
        options: (fieldJson['options'] as List<dynamic>?)?.cast<String>(),
      );
    }).toList();

    return CommandConfigSchema(
      toolName: json['tool_name'] as String,
      displayName: json['display_name'] as String,
      description: json['description'] as String?,
      fields: fields,
    );
  }

  /// 解析字符串为 CliConfigFieldType
  static CliConfigFieldType _parseFieldType(String typeStr) {
    return CliConfigFieldType.values.firstWhere(
      (e) => e.toString().split('.').last.toLowerCase() == typeStr.toLowerCase(),
      orElse: () => CliConfigFieldType.string,
    );
  }

  @override
  String toString() => 'CommandConfigSchema('
      'toolName: $toolName, '
      'displayName: $displayName, '
      'fields: ${fields.length})';
}
