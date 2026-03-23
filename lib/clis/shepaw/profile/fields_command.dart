import '../../cli_base.dart';

/// List all predefined profile fields
class FieldsCommand extends CliCommand {
  @override
  String get name => 'fields';

  @override
  String get description => 'List all predefined fields and descriptions';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return {
      'fields': {
        'name': 'Name',
        'age': 'Age',
        'gender': 'Gender',
        'occupation': 'Occupation',
        'city': 'City',
        'interests': 'Interests',
        'values': 'Values',
        'goals': 'Goals & Needs',
        'communication_style': 'Communication Style',
        'work_style': 'Work Habits',
        'life_stage': 'Life Stage',
        'important_people': 'Important People',
        'health': 'Health',
        'language': 'Language Preference',
        'timezone': 'Timezone',
        'notes': 'Other Notes',
      },
      'note': 'These are predefined fields. You can also write any custom fields (e.g., pet_name, hobby_music).',
    };
  }
}
