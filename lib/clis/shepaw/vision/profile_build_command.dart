import '../../cli_base.dart';
import 'vision_namespace.dart';

/// `vision profile.build` — 从参考照构建/刷新一位家人的结构化视觉档案。
class ProfileBuildCommand extends CliCommand {
  @override
  String get name => 'build';

  @override
  String get description =>
      'Build or refresh a person\'s structured visual profile (LLM vision)';

  @override
  String get usage =>
      'shepaw vision profile.build --person <name|id> [--refresh]';

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
      final profile = await service.buildProfile(found.id);
      return {
        'ok': true,
        'person_id': found.id,
        'person_name': found.name,
        'profile': profile.toJson(),
        'summary': profile.summarize(),
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
