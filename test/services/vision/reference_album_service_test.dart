import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/vision/face_models.dart';
import 'package:shepaw/models/vision/person_visual_profile.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/vision/debug_face_embedding_engine.dart';
import 'package:shepaw/services/vision/reference_album_service.dart';
import 'package:shepaw/services/vision/veda_face_store.dart';
import 'package:shepaw/services/vision/visual_profile_extractor.dart';

import '../../storage/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int run;

  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  setUp(() async {
    run = DateTime.now().microsecondsSinceEpoch;
    // 单例 DB 跨测试复用 → 清空相册保证用例隔离
    await LocalDatabaseService().clearFaceAlbum();
  });

  Future<ReferenceAlbumService> makeService() async {
    final vectors = await VedaFaceStore.open(dimension: 192);
    return ReferenceAlbumService(
      vectors: vectors,
      engine: const DebugFaceEmbeddingEngine(),
    );
  }

  Uint8List photoBytes(int seed) =>
      Uint8List.fromList([seed, seed + 1, seed + 2, seed + 3, seed + 4]);

  group('ReferenceAlbumService (Debug engine + memory veda)', () {
    test('enroll → list → recognize round-trip', () async {
      final service = await makeService();
      final bytes = photoBytes(1);

      final result = await service.enroll(
        name: '妈妈',
        imageBytes: bytes,
        relationship: '妈妈',
        caption: '客厅基准照',
      );
      expect(result.personId, isNotEmpty);
      expect(result.personName, '妈妈');
      expect(result.facesDetected, 1);
      expect(result.engine, 'debug');

      final persons = await service.listPersonsWithStats();
      expect(persons, hasLength(1));
      expect(persons.first.person.name, '妈妈');
      expect(persons.first.photoCount, 1);

      // 同图识别 → 命中自己
      final matches = await service.recognizeImage(bytes);
      expect(matches, hasLength(1));
      expect(matches.first.decision, FaceDecision.recognized);
      expect(matches.first.candidates.first.personName, '妈妈');
    });

    test('enrolling same name appends photos (multi-photo aggregation)',
        () async {
      final service = await makeService();
      final name = '宝宝$run';
      await service.enroll(name: name, imageBytes: photoBytes(11));
      final second = await service.enroll(
          name: name, imageBytes: photoBytes(12));

      expect(second.totalPhotosForPerson, 2);
      final persons = await service.listPersonsWithStats();
      expect(persons, hasLength(1));
      expect(persons.first.photoCount, 2);
    });

    test('unknown face → unknown decision', () async {
      final service = await makeService();
      // 空相册
      final matches = await service.recognizeImage(photoBytes(3));
      // Debug 引擎总能检测出人脸 → decision unknown，无候选
      expect(matches, hasLength(1));
      expect(matches.first.decision, FaceDecision.unknown);
      expect(matches.first.candidates, isEmpty);
    });

    test('removePerson cleans person, photos and vectors', () async {
      final service = await makeService();
      final name = '丁丹$run';
      final result = await service.enroll(
          name: name, imageBytes: photoBytes(21));

      // 删除前能命中
      expect((await service.recognizeImage(photoBytes(21))).first.decision,
          FaceDecision.recognized);

      await service.removePerson(result.personId);

      expect(await service.listPersons(), isEmpty);
      expect(await service.listPhotos(result.personId), isEmpty);
      // 向量已清理 → 同图不再命中
      final after = await service.recognizeImage(photoBytes(21));
      expect(after.first.decision, FaceDecision.unknown);
    });

    test('resolveImageBytes rejects missing local path', () async {
      final service = await makeService();
      await expectLater(
        service.resolveImageBytes(path: '/no/such/face_$run.jpg'),
        throwsA(isA<AlbumException>()),
      );
      await expectLater(
        service.resolveImageBytes(),
        throwsA(isA<AlbumException>()),
      );
    });

    test('buildProfile requires photos or throws clear error', () async {
      final service = await makeService();
      final result = await service.enroll(
          name: '孴宝$run', imageBytes: photoBytes(31));
      await expectLater(
        service.buildProfile(result.personId,
            builder: _stubProfileBuilder()),
        completes,
      );
    });
  });
}

/// 测试用档案 stub：直接返回固定档案，不调用 LLM。
class _StubProfileBuilder implements VisualProfileBuilder {
  @override
  Future<PersonVisualProfile> extract({
    required String personName,
    required List<AttachmentData> photos,
  }) async {
    return PersonVisualProfile(
      ageGroup: '儿童',
      hairStyle: '齐刘海',
      notes: 'stub：$personName（${photos.length} 张参考照）',
    );
  }
}

_StubProfileBuilder _stubProfileBuilder() => _StubProfileBuilder();
