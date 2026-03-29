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

  /// 返回命令帮助信息
  /// 子类可覆盖以提供详细的 flags 文档
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
      };

  /// i18n 支持预留（当前返回 key，便于后续扩展）
  String getMessage(String key, {Map<String, String>? args}) => key;
}

/// 命名空间的抽象基类，管理一组子命令
///
/// 支持两种模式：
///
/// 1. **扁平模式**（单层命名空间）
///    shepaw <namespace> <subcommand> [flags]
///    — 实现 [commands]，[subNamespaces] 返回空 map（默认）
///
/// 2. **分层模式**（嵌套 sub-namespace）
///    shepaw <namespace> <sub-namespace>.<action> [flags]
///    — 实现 [subNamespaces]，[commands] 返回空 map（默认）
///    — subcommand 格式：`profile.query`、`memory.write`
///
/// 分层模式示例：
/// ```
/// shepaw context profile.query
/// shepaw context memory.write --key soul --value "..."
/// shepaw context agents.list --status online
/// ```
abstract class CliNamespace {
  /// 命名空间名（如 "profile", "memory", "context"）
  String get namespace;

  /// 命名空间描述
  String get description;

  /// 所有扁平子命令（单层模式）；分层模式返回空 map
  Map<String, CliCommand> get commands => {};

  /// 嵌套的 sub-namespace（分层模式）；扁平模式返回空 map
  Map<String, CliNamespace> get subNamespaces => {};

  /// 执行子命令
  ///
  /// - 直接匹配 sub-namespace 名（如 "profile"）→ 返回该 sub-namespace 帮助
  /// - 空字符串或 "help" → 返回当前命名空间帮助
  /// - 含 "." 的字符串（如 "profile.query"）→ 路由到 sub-namespace
  /// - 其他 → 在 [commands] 中查找，找到后检查 --help 并返回命令的帮助，否则执行
  Future<Map<String, dynamic>> execute(
      String subcommand, Map<String, String> flags) async {
    // 直接访问 sub-namespace（如 "profile"）→ 返回该 sub-namespace 帮助
    final directNs = subNamespaces[subcommand];
    if (directNs != null) {
      return directNs.getHelp();
    }

    if (subcommand.isEmpty || subcommand == 'help') {
      return getHelp();
    }

    // 分层路由：格式 "<sub-namespace>.<action>"
    if (subcommand.contains('.')) {
      final dot = subcommand.indexOf('.');
      final subNs = subcommand.substring(0, dot);
      final action = subcommand.substring(dot + 1);
      final ns = subNamespaces[subNs];
      if (ns == null) {
        return {
          'error': 'Unknown sub-namespace: $subNs',
          'usage': 'shepaw $namespace <sub-namespace>.<action> [flags]',
          'available_sub_namespaces': subNamespaces.keys.toList(),
        };
      }
      return ns.execute(action, flags);
    }

    // 扁平路由：直接查 commands
    final cmd = commands[subcommand];
    if (cmd == null) {
      // 命令不存在，检查 --help flag
      if (flags.containsKey('help') || flags.containsKey('h')) {
        return getHelp();
      }
      return _unknownSubcommand(subcommand);
    }

    // 找到命令，检查 --help / -h flag
    if (flags.containsKey('help') || flags.containsKey('h')) {
      return cmd.getHelp();
    }

    return cmd.execute(flags);
  }

  /// 生成帮助信息（子类必须实现）
  Map<String, dynamic> getHelp();

  /// 未知子命令错误
  Map<String, dynamic> _unknownSubcommand(String sub) {
    if (subNamespaces.isNotEmpty) {
      return {
        'error': 'Unknown subcommand: $sub',
        'usage': 'shepaw $namespace <sub-namespace>.<action> [flags]',
        'available_sub_namespaces': subNamespaces.keys.toList(),
      };
    }
    return {
      'error': 'Unknown subcommand: $sub',
      'usage': 'shepaw $namespace <${commands.keys.join("|")}>',
      'available_subcommands': commands.keys.toList(),
    };
  }
}
