import '../../cli_base.dart';
import 'message_get_command.dart';

/// message 子命名空间 — 单条消息的按需读取
class MessageNamespace extends CliNamespace {
  @override
  String get namespace => 'message';

  @override
  String get description => 'Single message access (get full content / attachments)';

  @override
  String get usage => 'shepaw chat message get --id <message_id> [--analyze "..."]';

  @override
  Map<String, CliCommand> get commands => {
        'get': MessageGetCommand(),
      };
}
