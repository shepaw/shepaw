import '../models/remote_agent.dart';

/// Minimal interface for sending messages as She.
/// Implemented by ChatService to avoid circular imports.
abstract class IPawChatSender {
  Future<void> sendAsSheTo({
    required RemoteAgent targetAgent,
    required String channelId,
    required String message,
  });
}

/// 单个叶子命令的抽象基类
abstract class CliCommand {
  /// 命令名（如 "fields", "query", "write"）
  String get name;

  /// 命令简短描述
  String get description;

  /// 执行命令
  /// flags: 从 CLI 解析的键值对（如 {field: "name", value: "小明"}）
  Future<Map<String, dynamic>> execute(Map<String, String> flags);

  /// i18n 支持预留（当前返回 key，便于后续扩展）
  String getMessage(String key, {Map<String, String>? args}) => key;
}

/// 命名空间的抽象基类，管理一组子命令
abstract class CliNamespace {
  /// 命名空间名（如 "profile", "memory", "agents"）
  String get namespace;

  /// 命名空间描述
  String get description;

  /// 所有子命令映射（无子命令的 namespace 返回空 map）
  Map<String, CliCommand> get commands;

  /// 执行子命令（可被 namespace 覆盖以支持无子命令的直接执行）
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    // 空字符串或 "help" -> 返回帮助
    if (subcommand.isEmpty || subcommand == 'help') {
      return getHelp();
    }

    final cmd = commands[subcommand];
    if (cmd == null) {
      return _unknownSubcommand(subcommand);
    }
    return cmd.execute(flags);
  }

  /// 生成帮助信息（子类必须实现）
  Map<String, dynamic> getHelp();

  /// 转换为 LLM help entry（默认从 commands 生成，可覆盖）
  Map<String, dynamic> toHelpEntry() => {
    'subcommands': {
      for (final entry in commands.entries) entry.key: entry.value.description,
    },
  };

  /// 未知子命令错误
  Map<String, dynamic> _unknownSubcommand(String sub) => {
    'error': 'Unknown subcommand: $sub',
    'usage': 'shepaw $namespace <${commands.keys.join("|")}>',
    'available_subcommands': commands.keys.toList(),
  };
}
