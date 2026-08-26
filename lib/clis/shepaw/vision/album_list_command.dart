import '../../cli_base.dart';
import '../../../models/vision/person_visual_profile.dart';
import 'vision_namespace.dart';

/// `vision album.list` — 列出已登记家人（含照片数与档案摘要）。
class AlbumListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List registered family members with photo counts';

  @override
  String get usage => 'shepaw vision album.list [--json]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final service = VisionNamespace.instance.albumService;
    final persons = await service.listPersonsWithStats();
    return {
      'ok': true,
      'person_count': persons.length,
      'persons': [
        for (final p in persons)
          {
            'id': p.person.id,
            'name': p.person.name,
            'relationship': p.person.relationship,
            'photo_count': p.photoCount,
            'profile_summary':
                parseVisualProfile(p.person.profileJson ?? '').summarize(),
          },
      ],
    };
  }
}
