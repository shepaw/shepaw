
import '../../cli_base.dart';
import 'command/command_namespace.dart';
import 'file/file_namespace.dart';
import 'app/app_namespace.dart';
import 'clipboard/clipboard_namespace.dart';
import 'macos/macos_namespace.dart';
import 'process/process_namespace.dart';

/// [TOOLING 层] os 命名空间 — 本地操作系统工具
///
/// 将 OsToolRegistry 中定义的所有 OS 工具暴露为 CLI 命令。
/// 按 category 分组为 sub-namespace，使用分层路由：
///
///   shepaw os command.exec --command "ls -la"
///   shepaw os command.sysinfo --category overview
///   shepaw os file.read --path /tmp/test.txt
///   shepaw os file.write --path /tmp/test.txt --content "hello"
///   shepaw os file.list --path /tmp --detail true
///   shepaw os app.open --app_name Safari
///   shepaw os app.url --url https://dart.dev
///   shepaw os app.screenshot
///   shepaw os clipboard.read
///   shepaw os clipboard.write --text "copied text"
///   shepaw os process.list --sort_by cpu --limit 10
///   shepaw os process.kill --pid 1234
///   shepaw os macos.exec --script 'display dialog "Hello"'
///
/// 所有命令执行委托给 os_executor.runTool()，复用现有的风险分类和配置注入。
class OsCliNamespace extends CliNamespace {
  static final instance = OsCliNamespace._();
  OsCliNamespace._();

  @override
  String get namespace => 'os';

  @override
  String get description =>
      'Local OS tools — command, file, app, clipboard, process, system';

  @override
  String get usage => 'shepaw os <category>.<command> [flags]';

  /// OS 命名空间支持所有平台（具体工具的平台限制在子命名空间和命令中声明）
  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android', 'ios'};

  @override
  Map<String, CliNamespace> get subNamespaces {
    final namespaces = [
      CommandNamespace.instance,
      FileNamespace.instance,
      AppNamespace.instance,
      ClipboardNamespace.instance,
      MacosNamespace.instance,
      ProcessNamespace.instance,
    ];
    return {
      for (final ns in namespaces)
        if (ns.supportedPlatforms.contains(currentPlatformName)) ns.namespace: ns,
    };
  }
}
