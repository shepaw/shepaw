/// CLI 工具配置字段规格
///
/// 每个需要用户配置的工具（如 web_search）在 [OsToolDefinition.configSpec] 中
/// 声明一组 [CliConfigField]，UI 根据这些声明自动渲染对应的表单控件。
///
/// 使用示例：
/// ```dart
/// const CliConfigField(
///   key: 'api_key',
///   label: 'API Key',
///   description: 'Your Brave Search or Tavily API key.',
///   type: CliConfigFieldType.secret,
///   required: true,
/// )
/// ```

/// 配置字段类型，决定 UI 渲染方式
enum CliConfigFieldType {
  /// 敏感字段类型：使用遮掩输入框，存入 SecureStorage（不存 parameterOverrides）
  /// 支持在同一个工具中声明多个 secret 字段（如 api_key、api_secret），各自独立存储。
  secret,

  /// 普通字符串：普通文本输入框
  string,

  /// 整数：数字键盘输入框
  integer,

  /// 浮点数：带小数点的数字键盘输入框
  doubleNum,

  /// 布尔：SwitchListTile
  boolean,

  /// 枚举选择：DropdownButtonFormField，需配合 [CliConfigField.options] 使用
  select,
}

/// 单个配置字段的规格声明（不可变）
class CliConfigField {
  /// 字段标识符
  ///
  /// - `secret` 类型：此 key 同时作为 SecureStorage 的子键，格式为 `tool_secret_<toolName>_<fieldKey>`
  /// - 其余类型：存入 [ToolConfig.parameterOverrides] 的 map key
  final String key;

  /// UI 显示名（如 "API Key", "Max Results"）
  final String label;

  /// 字段用途描述，在 UI 中以 hint 或副标题形式展示
  final String description;

  /// 字段类型，决定 UI 渲染控件和存储方式
  final CliConfigFieldType type;

  /// 是否必填
  ///
  /// 必填字段在保存时会做非空校验
  final bool required;

  /// 默认值（可选）
  ///
  /// UI 初始化时若尚无配置值，使用此值填充；类型与 [type] 对应
  final dynamic defaultValue;

  /// 选项列表，仅 [CliConfigFieldType.select] 类型使用
  final List<String>? options;

  const CliConfigField({
    required this.key,
    required this.label,
    required this.description,
    required this.type,
    this.required = false,
    this.defaultValue,
    this.options,
  }) : assert(
          type != CliConfigFieldType.select || options != null,
          'CliConfigField: options must be provided for select type',
        );
}
