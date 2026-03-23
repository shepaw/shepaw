import '../../cli_base.dart';
import '../../../services/she_service.dart';

/// 追加 She 的记忆
class AppendCommand extends CliCommand {
  @override
  String get name => 'append';

  @override
  String get description => 'Append content, --key long_term_memory|self_notes --value <val>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final key = flags['key'];
    final value = flags['value'];
    if (key == null || key.isEmpty) {
      return {'error': 'Missing --key. Usage: shepaw memory append --key long_term_memory --value "..."'};
    }
    if (value == null) {
      return {'error': 'Missing --value parameter'};
    }
    if (key == 'long_term_memory') {
      await SheService.instance.appendMemory(value);
    } else {
      await SheService.instance.appendSelfNote(value);
    }
    return {'ok': true, 'key': key, 'appended': value};
  }
}
