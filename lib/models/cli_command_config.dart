/// CLI 命令全局配置 - 存储单个 CLI 命令的配置元数据
class CliCommandConfig {
  /// 命令的唯一标识符（namespace.subcommand 格式，如 'context.profile.query'）
  final String commandId;

  /// 是否全局启用（默认 true）
  /// true = 命令对所有 Agent 可用；false = 命令被全局禁用
  final bool globalEnabled;

  /// She 专属开关（默认 false）
  /// true = 仅 She 可调用此命令；false = 所有 Agent 均可调用（需满足 globalEnabled）
  final bool sheOnly;

  /// 备注说明
  final String? note;

  /// 创建时间（毫秒时间戳）
  final int createdAt;

  /// 更新时间（毫秒时间戳）
  final int updatedAt;

  const CliCommandConfig({
    required this.commandId,
    this.globalEnabled = true,
    this.sheOnly = false,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 拷贝并修改部分字段
  CliCommandConfig copyWith({
    bool? globalEnabled,
    bool? sheOnly,
    String? note,
    int? updatedAt,
    // 使用 sentinel 表示显式清空
    bool clearNote = false,
  }) {
    return CliCommandConfig(
      commandId: commandId,
      globalEnabled: globalEnabled ?? this.globalEnabled,
      sheOnly: sheOnly ?? this.sheOnly,
      note: clearNote ? null : (note ?? this.note),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  // ── 序列化 ──────────────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'command_id': commandId,
        'global_enabled': globalEnabled ? 1 : 0,
        'she_only': sheOnly ? 1 : 0,
        'note': note,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory CliCommandConfig.fromJson(Map<String, dynamic> json) {
    return CliCommandConfig(
      commandId: json['command_id'] as String,
      globalEnabled: (json['global_enabled'] as int? ?? 1) == 1,
      sheOnly: (json['she_only'] as int? ?? 0) == 1,
      note: json['note'] as String?,
      createdAt: json['created_at'] as int,
      updatedAt: json['updated_at'] as int,
    );
  }

  @override
  String toString() =>
      'CliCommandConfig(commandId: $commandId, globalEnabled: $globalEnabled, sheOnly: $sheOnly)';
}
