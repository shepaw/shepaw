import '../../cli_base.dart';
import '../../../services/she_service.dart';

/// 写入主人档案字段
class WriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description => 'Write field, --field <key> --value <val>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final field = flags['field'];
    final value = flags['value'];
    if (field == null || field.isEmpty) {
      return {'error': 'Missing --field. Usage: shepaw profile write --field name --value John'};
    }
    if (value == null) {
      return {'error': 'Missing --value. Usage: shepaw profile write --field name --value John'};
    }
    await SheService.instance.updateUserProfileField(field, value);
    return {'ok': true, 'field': field, 'value': value};
  }
}
