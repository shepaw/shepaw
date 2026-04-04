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
  String get usage => 'shepaw context memory.write --key <key> --value "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'key': {
        'description': 'Memory key to write (replaces existing value)',
        'required': true,
        'type': 'string',
        'available_keys': [
          'soul (self-awareness — use write to replace entire entry)',
          'heartbeat (last conversation summary)',
          'user_info (overall impression of the user)',
          'capabilities (capability index)',
          'self_notes (prefer append command for incremental updates)',
          'long_term_memory (prefer append command for incremental updates)',
        ],
      },
      'value': {
        'description': 'Value to set (replaces existing content)',
        'required': true,
        'type': 'string',
      },
    };
    base['note'] = 'For incremental updates to self_notes or long_term_memory, use the append command instead';
    return base;
  }

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
