import '../../../cli_base.dart';
import 'group_session_commands.dart';

/// chat.group.session — create a new group session with handoff (admin only).
class GroupSessionNamespace extends CliNamespace {
  @override
  String get namespace => 'session';

  @override
  String get description =>
      'Group session management (create with handoff; admin only)';

  @override
  String get usage => 'shepaw chat group session create [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'create': GroupSessionCreateCommand(),
      };
}
