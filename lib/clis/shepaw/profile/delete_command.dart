import '../../cli_base.dart';
import '../../../services/cognition_service.dart';

/// 删除主人档案字段
class DeleteCommand extends CliCommand {
  @override
  String get name => 'delete';

  @override
  String get description => 'Delete field, --field <key>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final field = flags['field'];
    if (field == null || field.isEmpty) {
      return {'error': 'Missing --field. Usage: shepaw profile delete --field name'};
    }
    await CognitionService.instance.deleteUserProfileField(field);
    return {'ok': true, 'deleted': field};
  }
}
