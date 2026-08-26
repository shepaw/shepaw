import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/vision/debug_face_embedding_engine.dart';
import 'package:shepaw/services/vision/face_embedding_engine.dart';
import 'package:shepaw/services/vision/face_matcher.dart';

void main() {
  const engine = DebugFaceEmbeddingEngine();

  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('DebugFaceEmbeddingEngine', () {
    test('is available and reports debug', () async {
      expect(engine.isDebug, isTrue);
      expect(await engine.isAvailable, isTrue);
      expect(engine.id, 'debug');
    });

    test('empty input → no faces', () async {
      expect(await engine.detectAndEmbed(Uint8List(0)), isEmpty);
    });

    test('embedding has fixed dimension and is L2-normalized', () async {
      final faces = await engine.detectAndEmbed(bytes([1, 2, 3, 4, 5]));
      expect(faces, hasLength(1));
      final emb = faces.first.embedding;
      expect(emb, hasLength(FaceEmbeddingEngine.embeddingDim));
      final norm =
          emb.fold<double>(0, (acc, v) => acc + v * v);
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('identical bytes → near-identical embedding (cosine ≈ 1)', () async {
      final a = await engine.detectAndEmbed(bytes([9, 9, 9, 9, 9, 9]));
      final b = await engine.detectAndEmbed(bytes([9, 9, 9, 9, 9, 9]));
      expect(a, hasLength(1));
      expect(b, hasLength(1));
      final cos =
          FaceMatcher.cosine(a.first.embedding, b.first.embedding);
      expect(cos, greaterThan(0.9999));
    });

    test('different bytes → lower similarity than identical', () async {
      final a = await engine.detectAndEmbed(bytes([1, 2, 3]));
      final b = await engine.detectAndEmbed(bytes([4, 5, 6]));
      final same = await engine.detectAndEmbed(bytes([1, 2, 3]));
      final cosDiff = FaceMatcher.cosine(a.first.embedding, b.first.embedding);
      final cosSame = FaceMatcher.cosine(a.first.embedding, same.first.embedding);
      expect(cosDiff, lessThan(cosSame));
    });

    test('multi-face mode returns distinct boxes', () async {
      const multi = DebugFaceEmbeddingEngine(maxFaces: 2);
      final faces = await multi.detectAndEmbed(bytes([1, 2, 3]));
      expect(faces, hasLength(2));
      expect(faces[0].box, isNot(equals(faces[1].box)));
      expect(faces[0].confidence, greaterThan(faces[1].confidence));
    });
  });
}
