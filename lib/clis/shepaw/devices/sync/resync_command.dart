import '../../../cli_base.dart';
import '../../../../identity/services/sync_client_service.dart';

/// 从 Primary 全量 resync（重置游标后重新拉取）。
class DevicesSyncResyncCommand extends CliCommand {
  @override
  String get name => 'resync';

  @override
  String get description => 'Full resync from Primary (reset cursors, pull all domains)';

  @override
  String get usage => 'shepaw devices sync.resync';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    try {
      await SyncClientService.instance.fullResyncFromPrimary();
      return {'ok': true, 'message': 'Full resync from Primary completed.'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
