import '../cli_base.dart';

/// help 命名空间 - 返回完整帮助信息
/// 实际的 help 内容由 ShepawCLI 动态聚合所有命名空间生成
class HelpNamespace extends CliNamespace {
  static final instance = HelpNamespace._();
  HelpNamespace._();

  @override
  String get namespace => 'help';

  @override
  String get description => 'Display complete help information';

  @override
  Map<String, CliCommand> get commands => {};

  /// 由 ShepawCLI 覆盖此方法以返回动态聚合的帮助
  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    return getHelp();
  }

  @override
  Map<String, dynamic> getHelp() => {
    'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
    'note': 'Run "shepaw help" to see all available namespaces',
  };
}
