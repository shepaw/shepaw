import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 列出所有对话频道
class ChatChannelsCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'channels';

  @override
  String get description => 'List all conversation channels';

  @override
  String get usage => 'shepaw chat channels';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final channels = await _db.getAllChannels();
    final list = channels
        .map((c) => {
              'id': c.id,
              'name': c.name,
              'type': c.type,
              'description': c.description,
            })
        .toList();
    return {'channels': list, 'count': list.length};
  }
}
