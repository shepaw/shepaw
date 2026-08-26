import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/vision/veda_face_store.dart';

List<double> unit(int dim, int hotIndex) => [
      for (var i = 0; i < dim; i++)
        i == hotIndex ? 1.0 : 0.0,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VedaFaceStore store;

  setUp(() async {
    store = await VedaFaceStore.open(dimension: 4);
  });

  tearDown(() async {
    await store.close();
  });

  group('VedaFaceStore (memory)', () {
    test('upsert then search returns top hit', () async {
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

    test('upsert with same id replaces the vector', () async {
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

    test('removePhoto deletes only that vector', () async {
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.upsert(
          photoId: 'ph2', personId: 'p1', embedding: unit(4, 1));

      await store.removePhoto('ph1');
      final hits = await store.search(unit(4, 0), topK: 3);
      expect(hits.map((h) => h.photoId), isNot(contains('ph1')));
      expect(hits, hasLength(1));
    });

    test('removePhotos deletes multiple', () async {
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
      await store.upsert(
          photoId: 'ph1', personId: 'p1', embedding: unit(4, 0));
      await store.clear();
      final hits = await store.search(unit(4, 0), topK: 5);
      expect(hits, isEmpty);
    });
  });
}
