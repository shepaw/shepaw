import '../../cli_base.dart';
import 'vision_namespace.dart';

/// `vision album.enroll` — 为一位家人登记一张基准照。
class AlbumEnrollCommand extends CliCommand {
  @override
  String get name => 'enroll';

  @override
  String get description =>
      'Enroll a person\'s baseline photo into the reference album';

  @override
  String get usage =>
      'shepaw vision album.enroll --person <name> '
      '--image <path>|--message_id <id> '
      '[--relationship <关系>] [--caption <备注>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = (flags['person'] ?? flags['name'] ?? '').trim();
    if (name.isEmpty) {
      return {
        'ok': false,
        'error': 'Missing required --person <name>.\nUsage: $usage',
      };
    }
    final service = VisionNamespace.instance.albumService;
    try {
      final bytes = await service.resolveImageBytes(
        path: flags['image'] ?? flags['path'],
        messageId: flags['message_id'],
      );
      final result = await service.enroll(
        name: name,
        imageBytes: bytes,
        relationship: _emptyToNull(flags['relationship']),
        caption: _emptyToNull(flags['caption']),
      );
      return {
        'ok': true,
        'person_id': result.personId,
        'person_name': result.personName,
        'photo_id': result.photoId,
        'faces_detected': result.facesDetected,
        'total_photos_for_person': result.totalPhotosForPerson,
        'engine': result.engine,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static String? _emptyToNull(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}
