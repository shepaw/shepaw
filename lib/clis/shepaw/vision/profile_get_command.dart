import '../../cli_base.dart';
import '../../../models/vision/person_visual_profile.dart';
import 'vision_namespace.dart';

/// `vision profile.get` — 读取已存的结构化视觉档案（无则返回空档案）。
class ProfileGetCommand extends CliCommand {
  @override
  String get name => 'get';

  @override
  String get description =>
      'Get a person\'s stored visual profile (empty if none)';

  @override
  String get usage => 'shepaw vision profile.get --person <name|id>';

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
      final profile = parseVisualProfile(found.profileJson ?? '');
      final hasProfile =
          found.profileJson != null && found.profileJson!.isNotEmpty;
      return {
        'ok': true,
        'person_id': found.id,
        'person_name': found.name,
        'has_profile': hasProfile,
        'profile': profile.toJson(),
        'summary': profile.summarize(),
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
