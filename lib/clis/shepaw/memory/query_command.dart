import '../../cli_base.dart';
import '../../../services/she_profile_database_service.dart';

/// 查询 She 的记忆
class QueryCommand extends CliCommand {
  final _profileDb = SheProfileDatabaseService();

  @override
  String get name => 'query';

  @override
  String get description => 'Query memory, optional --keys soul,heartbeat,...';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final allMemory = await _profileDb.getAllSheMemory();
    final keysArg = flags['keys'];
    if (keysArg != null && keysArg.isNotEmpty) {
      final requested = keysArg.split(',').map((s) => s.trim()).toSet();
      final filtered =
          Map.fromEntries(allMemory.entries.where((e) => requested.contains(e.key)));
      return {'memory': filtered};
    }
    return {'memory': allMemory};
  }
}
