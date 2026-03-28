import '../../cli_base.dart';
import '../../../services/she_service.dart';
import '../../../services/she_memory_db_service.dart';

/// 写入 She 的记忆
class WriteCommand extends CliCommand {
  final _sheMemoryDb = SheMemoryDbService.instance;

  @override
  String get name => 'write';

  @override
  String get description => 'Write memory, --key <key> --value <val>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final key = flags['key'];
    final value = flags['value'];
    if (key == null || key.isEmpty) {
      return {'error': 'Missing --key. Usage: shepaw memory write --key soul --value "..."'};
    }
    if (value == null) {
      return {'error': 'Missing --value parameter'};
    }
    // 路由到 SheService 的专用方法
    if (key == 'soul') {
      await SheService.instance.updateSoul(value);
    } else {
      await _sheMemoryDb.setSheMemory(key, value);
    }
    return {'ok': true, 'key': key};
  }
}
