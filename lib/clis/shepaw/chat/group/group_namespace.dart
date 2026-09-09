import '../../../cli_base.dart';
import 'group_commands.dart';
import 'group_session_namespace.dart';

/// chat.group 子命名空间 — 群聊创建与管理（She 须为管理员）
///
/// Subcommands:
/// - `create`  创建群聊（默认 She 为管理员）
/// - `add`     添加成员
/// - `kick`    移除成员
/// - `rename`  修改群名
/// - `set-bio` 设置/清空成员的群内职责描述
/// - `set-description` 设置/清空群描述
/// - `set-config` 批量改群运行配置（system-prompt / mention-mode / max-loop-rounds /
///   flow-mode / enable-stage-gate）
/// - `send`    向绑定群会话发消息（外部触发编排，不影响群当前聊天）
/// - `session` 新建群会话并交接上下文（admin only）
class GroupNamespace extends CliNamespace {
  @override
  String get namespace => 'group';

  @override
  String get description =>
      'Create/manage groups (create=She-only; add/kick/rename/set-bio/'
      'set-description/set-config/send/session=admin only)';

  @override
  String get usage =>
      'shepaw chat group <create|add|kick|rename|set-bio|set-description|'
      'set-config|send|session.create> [flags]';

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'session': GroupSessionNamespace(),
      };

  @override
  Map<String, CliCommand> get commands => {
        'create': GroupCreateCommand(),
        'add': GroupAddCommand(),
        'kick': GroupKickCommand(),
        'rename': GroupRenameCommand(),
        'set-bio': GroupSetBioCommand(),
        'set-description': GroupSetDescriptionCommand(),
        'set-config': GroupSetConfigCommand(),
        'send': GroupSendCommand(),
      };
}
