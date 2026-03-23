import '../cli_base.dart';
import '../../services/local_database_service.dart';

/// channels 命名空间 - 列出所有对话频道
class ChannelsNamespace extends CliNamespace {
  static final instance = ChannelsNamespace._();
  ChannelsNamespace._();

  final _db = LocalDatabaseService();

  @override
  String get namespace => 'channels';

  @override
  String get description => 'Conversation channel list';

  @override
  Map<String, CliCommand> get commands => {};

  /// channels 没有子命令，直接执行
  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    final channels = await _db.getAllChannels();
    final list = channels.map((c) => {
          'id': c.id,
          'name': c.name,
          'type': c.type,
          'description': c.description,
        }).toList();
    return {'channels': list, 'count': list.length};
  }

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {'list': 'List all channels'},
    'examples': ['shepaw channels'],
  };
}
