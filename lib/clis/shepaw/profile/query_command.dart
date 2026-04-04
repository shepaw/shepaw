import '../../cli_base.dart';
import '../../../services/cognition_service.dart';

/// 查询主人档案
class QueryCommand extends CliCommand {
  @override
  String get name => 'query';

  @override
  String get description => 'Query profile, optional --fields name,age,...';

  @override
  String get usage => 'shepaw context profile.query [--fields name,age,...]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'fields': {
        'description': 'Comma-separated field names to retrieve (omit for all fields)',
        'required': false,
        'type': 'string',
        'example': 'name,age,occupation',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final allProfile = await CognitionService.instance.getAllUserProfile();
    // 过滤内部标志字段
    final visible = Map.fromEntries(
      allProfile.entries.where((e) => !e.key.startsWith('_')),
    );
    final fieldsArg = flags['fields'];
    if (fieldsArg != null && fieldsArg.isNotEmpty) {
      final requested = fieldsArg.split(',').map((s) => s.trim()).toSet();
      final filtered = Map.fromEntries(
        visible.entries.where((e) => requested.contains(e.key)),
      );
      return {'profile': filtered, 'count': filtered.length};
    }
    return {'profile': visible, 'count': visible.length};
  }
}
