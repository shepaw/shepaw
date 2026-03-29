import '../../cli_base.dart';
import '../system/system_namespace.dart';
import 'datetime_command.dart';

/// [META 层] meta 命名空间 - 系统元信息和诊断
///
/// 统一管理系统信息查询和时间服务。
///
/// 支持两种子命令格式：
///
/// 1. 扁平命令（直接执行）：
///    `shepaw meta datetime`
///
/// 2. 分层路由（system 子命名空间）：
///    `shepaw meta system.<action>`
///    Actions: info | tools-list | tools-detail | capabilities
///
/// 示例：
/// ```
/// shepaw meta datetime
/// shepaw meta system.info
/// shepaw meta system.tools-list
/// shepaw meta system.tools-detail --name file_read
/// shepaw meta system.capabilities
/// ```
class MetaNamespace extends CliNamespace {
  static final instance = MetaNamespace._();
  MetaNamespace._();

  @override
  String get namespace => 'meta';

  @override
  String get description => 'System meta-info — datetime and system diagnostics';

  /// 扁平命令：datetime
  @override
  Map<String, CliCommand> get commands => {
        'datetime': MetaDatetimeCommand(),
      };

  /// 分层 sub-namespace：system
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'system': SystemNamespace.instance,
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'datetime': 'Return current date, time and timezone info',
          'system.info': 'Display basic app information',
          'system.tools-list': 'List all available tools (UI, OS, skills, models)',
          'system.tools-detail': 'Full docs for a specific tool (--name <tool_name>)',
          'system.capabilities': 'Summary of system capabilities',
        },
        'examples': [
          'shepaw meta datetime',
          'shepaw meta system.info',
          'shepaw meta system.tools-list',
          'shepaw meta system.tools-detail --name file_read',
          'shepaw meta system.capabilities',
        ],
      };
}
