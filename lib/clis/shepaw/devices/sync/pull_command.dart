import '../../../cli_base.dart';
import '../../../../identity/services/sync_client_service.dart';

/// 从 Primary 设备拉取同步数据（消息索引等）。
class DevicesSyncPullCommand extends CliCommand {
  @override
  String get name => 'pull';

  @override
  String get description => 'Pull sync events from Primary storage device';

  @override
  String get usage => 'shepaw devices sync.pull';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    try {
      await SyncClientService.instance.pullFromPrimary();
      return {'ok': true, 'message': 'Sync pull completed'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
