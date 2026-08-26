import '../../cli_base.dart';
import 'vision_namespace.dart';

/// `vision album.remove` — 删除一位家人及其全部参考照。
class AlbumRemoveCommand extends CliCommand {
  @override
  String get name => 'remove';

  @override
  String get description =>
      'Remove a person and all their reference photos';

  @override
  String get usage => 'shepaw vision album.remove --person <name|id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final person = (flags['person'] ?? flags['name'] ?? '').trim();
    if (person.isEmpty) {
      return {
        'ok': false,
        'error': 'Missing required --person <name|id>.\nUsage: $usage',
      };
    }
    final service = VisionNamespace.instance.albumService;
    try {
      final found = await service.findPerson(person);
      if (found == null) {
        return {'ok': false, 'error': 'Person not found: $person'};
      }
      await service.removePerson(found.id);
      return {
        'ok': true,
        'removed': {'id': found.id, 'name': found.name},
        'message': '已删除 ${found.name} 及其全部参考照',
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
