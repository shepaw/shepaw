import '../../cli_base.dart';
import '../../../services/vision/face_embedding_engine.dart';
import 'vision_namespace.dart';

/// `vision status` — 引擎可用性 + 相册规模。
class VisionStatusCommand extends CliCommand {
  @override
  String get name => 'status';

  @override
  String get description => 'Face recognition engine & reference album status';

  @override
  String get usage => 'shepaw vision status';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final engine = await FaceEmbeddingEngineRegistry.instance.resolve();
    final service = VisionNamespace.instance.albumService;
    final persons = await service.listPersonsWithStats();
    return {
      'ok': true,
      'engine': {
        'id': engine.id,
        'label': engine.label,
        'is_debug': engine.isDebug,
        'available': await engine.isAvailable,
        'embedding_dim': FaceEmbeddingEngine.embeddingDim,
        'thresholds': {
          'high': engine.highThreshold,
          'low': engine.lowThreshold,
        },
      },
      'album': {
        'person_count': persons.length,
        'photo_count':
            persons.fold<int>(0, (sum, p) => sum + p.photoCount),
        'persons': [
          for (final p in persons)
            {
              'id': p.person.id,
              'name': p.person.name,
              'relationship': p.person.relationship,
              'photo_count': p.photoCount,
            },
        ],
      },
    };
  }
}
