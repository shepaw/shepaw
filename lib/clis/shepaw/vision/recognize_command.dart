import '../../cli_base.dart';
import 'vision_namespace.dart';

/// `vision recognize` — 识别一张图中所有人脸（embedding 比对）。
///
/// 图片输入二选一：
/// - `--image <本地路径>`（兼容 `--path`）
/// - `--message_id <id>`（走聊天消息附件）
class VisionRecognizeCommand extends CliCommand {
  @override
  String get name => 'recognize';

  @override
  String get description =>
      'Detect & recognize faces in an image (--image <path> or --message_id <id>)';

  @override
  String get usage =>
      'shepaw vision recognize --image <path>|--message_id <id> [--top 3]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final service = VisionNamespace.instance.albumService;
    try {
      final bytes = await service.resolveImageBytes(
        path: flags['image'] ?? flags['path'],
        messageId: flags['message_id'],
      );
      final topK = int.tryParse(flags['top'] ?? '') ?? 3;
      final results = await service.recognizeImage(bytes, topK: topK);
      return {
        'ok': true,
        'face_count': results.length,
        'faces': results.map((r) => r.toJson()).toList(),
        'hint':
            'A person is only "recognized" above the high threshold; '
            'unknown/ambiguous → say you are not sure, do not guess a name.',
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }
}
