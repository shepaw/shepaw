import '../../../cli_base.dart';
import 'session_create_command.dart';

/// chat.session — create a new 1:1 session with a handoff summary.
class ChatSessionNamespace extends CliNamespace {
  @override
  String get namespace => 'session';

  @override
  String get description =>
      '1:1 session management (create with handoff summary)';

  @override
  String get usage => 'shepaw chat session create [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'create': ChatSessionCreateCommand(),
      };
}
