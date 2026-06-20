import '../../../cli_base.dart';
import 'pull_command.dart';

/// devices.sync 子命名空间 — 跨设备同步操作。
class DevicesSyncNamespace extends CliNamespace {
  static final instance = DevicesSyncNamespace._();
  DevicesSyncNamespace._();

  @override
  String get namespace => 'sync';

  @override
  String get description => 'Sync operations (pull from Primary)';

  @override
  Map<String, CliCommand> get commands => {
        'pull': DevicesSyncPullCommand(),
      };
}
