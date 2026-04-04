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
}
