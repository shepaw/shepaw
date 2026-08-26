import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/vision/face_models.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/vision/debug_face_embedding_engine.dart';
import 'package:shepaw/services/vision/reference_album_service.dart';
import 'package:shepaw/services/vision/store_face_vector_store.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

/// 维度 [dim]、只在 [hotIndex] 位为 1 的单位向量。
List<double> unit(int dim, int hotIndex) => [
      for (var i = 0; i < dim; i++) i == hotIndex ? 1.0 : 0.0,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const agentId = 'face-vec-test';

  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
    await LocalDatabaseService().database;
  });

  setUp(() async {
    await LocalDatabaseService().clearFaceAlbum();
    // 每个用例独立的 store 子树，避免跨用例残留
    await StoreFaceVectorStore.open(agentId: agentId).then((s) => s.clear());
  });

  Future<StoreFaceVectorStore> open() =>
      StoreFaceVectorStore.open(agentId: agentId);

  group('StoreFaceVectorStore (cognition 逐向量 JSON)', () {
    test('upsert then search returns top hit, cosine ordering', () async {
      final store = await open();
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.upsert(
          photoId: 'ph2', personId: 'p2', embedding: unit(4, 1));

      final hits = await store.search(unit(4, 0), topK: 3);
      expect(hits, hasLength(2));
      expect(hits.first.photoId, 'ph1');
      expect(hits.first.personId, 'p1');
      expect(hits.first.similarity, greaterThan(0.99));
      expect(hits.last.similarity, closeTo(0.0, 1e-6));
    });

    test('topK limits result count', () async {
      final store = await open();
      for (var i = 0; i < 5; i++) {
        await store.upsert(
            photoId: 'ph$i', personId: 'p$i', embedding: unit(8, i));
      }
      final hits = await store.search(unit(8, 0), topK: 2);
      expect(hits, hasLength(2));
      expect(hits.first.photoId, 'ph0');
      expect(hits.last.photoId, 'ph1');
    });

    test('upsert with same photoId replaces the vector', () async {
      final store = await open();
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 2));

      final hits = await store.search(unit(4, 2), topK: 3);
      expect(hits.first.photoId, 'ph1');
      expect(hits.first.similarity, greaterThan(0.99));

      // 旧向量（index 0）已被替换
      final old = await store.search(unit(4, 0), topK: 3);
      expect(old.first.similarity, closeTo(0.0, 1e-6));
    });

    test('persists across reopen (从 store 重新加载)', () async {
      var store = await open();
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(192, 5));
      await store.close();

      // 新实例从 cognition 重新读回
      store = await open();
      final hits = await store.search(unit(192, 5), topK: 3);
      expect(hits, hasLength(1));
      expect(hits.first.photoId, 'ph1');
      expect(hits.first.personId, 'p1');
      expect(hits.first.similarity, greaterThan(0.99));
    });

    test('removePhoto is idempotent for missing id', () async {
      final store = await open();
      await store.removePhoto('missing'); // 不应抛异常
    });

    test('removePhotos deletes multiple', () async {
      final store = await open();
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.upsert(
          photoId: 'ph2', personId: 'p1', embedding: unit(4, 1));
      await store.upsert(
          photoId: 'ph3', personId: 'p2', embedding: unit(4, 2));

      await store.removePhotos(['ph1', 'ph2']);
      final hits = await store.search(unit(4, 0), topK: 5);
      expect(hits.map((h) => h.photoId), ['ph3']);
    });

    test('clear removes all vectors', () async {
      final store = await open();
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.clear();
      final hits = await store.search(unit(4, 0), topK: 5);
      expect(hits, isEmpty);
    });
  });

  group('ReferenceAlbumService（store 向量后端 round-trip）', () {
    test('enroll → list → recognize → remove', () async {
      final store = await open();
      final service = ReferenceAlbumService(
        vectors: store,
        engine: const DebugFaceEmbeddingEngine(),
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      final result = await service.enroll(
        name: '妈妈',
        imageBytes: bytes,
        relationship: '妈妈',
        caption: '客厅基准照',
      );
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

      // 删除后向量已清理 → 同图不再命中
      await service.removePerson(result.personId);
      expect(await service.listPersons(), isEmpty);
      final after = await service.recognizeImage(bytes);
      expect(after.first.decision, FaceDecision.unknown);
    });

    test('unknown face (empty album) → unknown decision', () async {
      final store = await open();
      final service = ReferenceAlbumService(
        vectors: store,
        engine: const DebugFaceEmbeddingEngine(),
      );
      final matches = await service.recognizeImage(
          Uint8List.fromList([7, 8, 9, 10]));
      expect(matches, hasLength(1));
      expect(matches.first.decision, FaceDecision.unknown);
      expect(matches.first.candidates, isEmpty);
    });
  });
}
