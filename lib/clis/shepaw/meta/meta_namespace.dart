import '../../cli_base.dart';
import '../system/system_namespace.dart';
import 'datetime_command.dart';
import 'cli_tools_namespace.dart';

/// [META 层] meta 命名空间 - 系统元信息和诊断
///
/// 统一管理系统信息查询和时间服务。
///
/// 支持两种子命令格式：
///
/// 1. 扁平命令（直接执行）：
///    `shepaw meta datetime`
///
/// 2. 分层路由（sub-namespace）：
///    `shepaw meta system.<action>`
///    Actions: info | tools-list | tools-detail | capabilities
///
///    `shepaw meta cli-tools.<action>`
///    Actions: list | install | uninstall | rescan
///
/// 示例：
/// ```
/// shepaw meta datetime
/// shepaw meta system.info
/// shepaw meta system.tools-list
/// shepaw meta system.tools-detail --name file_read
/// shepaw meta system.capabilities
/// shepaw meta cli-tools.list
/// shepaw meta cli-tools.install --file /path/to/tool.zip
/// shepaw meta cli-tools.uninstall --namespace weather
/// shepaw meta cli-tools.rescan
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

  /// 分层 sub-namespace：system + cli-tools
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'system': SystemNamespace.instance,
        'cli-tools': CliToolsSubNamespace.instance,
      };
}
