import '../../cli_base.dart';
import 'fields_command.dart';
import 'query_command.dart';
import 'write_command.dart';
import 'delete_command.dart';

/// profile namespace - user profile management
class ProfileNamespace extends CliNamespace {
  static final instance = ProfileNamespace._();
  ProfileNamespace._();

  @override
  String get namespace => 'profile';

  @override
  String get description => 'User profile (user_profile table)';

  @override
  Map<String, CliCommand> get commands => {
    'fields': FieldsCommand(),
    'query': QueryCommand(),
    'write': WriteCommand(),
    'delete': DeleteCommand(),
  };

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {
      'fields': 'List all predefined fields and descriptions',
      'query': 'Query profile, optional --fields name,age,...',
      'write': 'Write field, --field <key> --value <val>',
      'delete': 'Delete field, --field <key>',
    },
    'examples': [
      'shepaw profile fields',
      'shepaw profile query',
      'shepaw profile query --fields name,age,occupation',
      'shepaw profile write --field name --value John',
      'shepaw profile delete --field notes',
    ],
  };
}
