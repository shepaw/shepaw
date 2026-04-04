import '../../cli_base.dart';
import '../../../services/she_memory_db_service.dart';

/// 查询 She 的记忆
class QueryCommand extends CliCommand {
  final _sheMemoryDb = SheMemoryDbService.instance;

  @override
  String get name => 'query';

  @override
  String get description => 'Query memory, optional --keys soul,heartbeat,...';

  @override
  String get usage => 'shepaw context memory.query [--keys soul,user_info,...]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'keys': {
        'description': 'Comma-separated memory keys to retrieve (omit for all)',
        'required': false,
        'type': 'string',
        'example': 'soul,user_info',
        'available_keys': [
          'soul (self-awareness, replace entire entry)',
          'self_notes (personal notes)',
          'long_term_memory (long-term memory)',
          'heartbeat (last conversation summary)',
          'user_info (overall impression of the user)',
          'capabilities (capability index)',
        ],
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final allMemory = await _sheMemoryDb.getAllSheMemory();
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
