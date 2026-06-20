import '../../cli_base.dart';
import 'list_command.dart';
import 'exec_command.dart';
import 'sync/sync_namespace.dart';

/// [TOOLING 层] devices 命名空间 — 跨自有设备管理与 RPC。
///
///   shepaw devices list
///   shepaw devices exec --device <id> --command "shepaw context agents.list"
///   shepaw devices sync.pull
class DevicesNamespace extends CliNamespace {
  static final instance = DevicesNamespace._();
  DevicesNamespace._();

  @override
  String get namespace => 'devices';

  @override
  String get description => 'Owned devices — list, remote exec, sync from Primary';

  @override
  Map<String, CliCommand> get commands => {
        'list': DevicesListCommand(),
        'exec': DevicesExecCommand(),
      };

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'sync': DevicesSyncNamespace.instance,
      };
}
