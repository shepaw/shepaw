import '../../../cli_base.dart';
import 'group_commands.dart';

/// chat.group 子命名空间 — 群聊创建与管理（She 须为管理员）
///
/// Subcommands:
/// - `create`  创建群聊（默认 She 为管理员）
/// - `add`     添加成员
/// - `kick`    移除成员
/// - `rename`  修改群名
class GroupNamespace extends CliNamespace {
  @override
  String get namespace => 'group';

  @override
  String get description =>
      'Create and manage group chats (She must be admin for mutations)';

  @override
  String get usage =>
      'shepaw chat group <create|add|kick|rename> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'create': GroupCreateCommand(),
        'add': GroupAddCommand(),
        'kick': GroupKickCommand(),
        'rename': GroupRenameCommand(),
      };
}
