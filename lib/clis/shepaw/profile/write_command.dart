import '../../cli_base.dart';
import '../../../services/cognition_service.dart';

/// 写入主人档案字段
class WriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description => 'Write field, --field <key> --value <val>';

  @override
  String get usage => 'shepaw context profile.write --field <key> --value <val>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'field': {
        'description': 'Profile field key to write (e.g., name, age, occupation, or any custom key)',
        'required': true,
        'type': 'string',
        'example': 'name',
      },
      'value': {
        'description': 'Value to set for the field',
        'required': true,
        'type': 'string',
        'example': 'John',
      },
    };
    base['note'] = 'Use "shepaw context profile.fields" to see predefined fields';
    return base;
  }

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
    await CognitionService.instance.updateUserProfileField(field, value);
    return {'ok': true, 'field': field, 'value': value};
  }
}
