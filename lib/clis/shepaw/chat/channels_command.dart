import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 列出对话频道，支持 --type 过滤；群聊附带成员与管理员
class ChatChannelsCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'channels';

  @override
  String get description =>
      'List conversation channels, optional --type <group|dm|public|all>; '
      'group channels include members and admin';

  @override
  String get usage => 'shepaw chat channels [--type group|dm|public|all]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'type': {
        'description': 'Filter channels by type',
        'required': false,
        'type': 'string',
        'enum': ['group', 'dm', 'public', 'all'],
        'default': 'all',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final typeFilter = flags['type'];
    var channels = await _db.getAllChannels();
    if (typeFilter != null && typeFilter.isNotEmpty && typeFilter != 'all') {
      channels = channels.where((c) => c.type == typeFilter).toList();
    }
    // 群聊只看根群（parent_group_id 为空）；带 parent_group_id 的是群会话
    if (typeFilter == 'group') {
      channels = channels.where((c) => c.parentGroupId == null).toList();
    }

    final agents = await _db.getAllRemoteAgents();
    final nameOf = {for (final a in agents) a.id: a.name};

    final list = <Map<String, dynamic>>[];
    for (final c in channels) {
      final entry = <String, dynamic>{
        'id': c.id,
        'name': c.name,
        'type': c.type,
        'description': c.description,
      };
      if (c.isGroup) {
        final members = (await _db.getChannelMembers(c.id))
            .where((m) => m.type == 'agent')
            .toList();
        entry['members'] =
            members.map((m) => nameOf[m.id] ?? m.id).toList();
        for (final m in members) {
          if (m.role == 'admin') {
            entry['admin'] = nameOf[m.id] ?? m.id;
            break;
          }
        }
      }
      list.add(entry);
    }
    return {'channels': list, 'count': list.length};
  }
}
