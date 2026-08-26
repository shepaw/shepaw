import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/vision/face_models.dart';
import 'package:shepaw/services/vision/face_matcher.dart';

void main() {
  const box = FaceBox(x: 0.1, y: 0.1, width: 0.4, height: 0.4);

  group('FaceMatcher.cosine', () {
    test('identical unit vectors → 1.0', () {
      const a = [1.0, 0.0, 0.0];
      const b = [1.0, 0.0, 0.0];
      expect(FaceMatcher.cosine(a, b), closeTo(1.0, 1e-9));
    });

    test('orthogonal vectors → 0.0', () {
      const a = [1.0, 0.0];
      const b = [0.0, 1.0];
      expect(FaceMatcher.cosine(a, b), closeTo(0.0, 1e-9));
    });

    test('opposite vectors → -1.0', () {
      const a = [1.0, 0.0];
      const b = [-1.0, 0.0];
      expect(FaceMatcher.cosine(a, b), closeTo(-1.0, 1e-9));
    });

    test('non-normalized vectors behave as cosine', () {
      const a = [3.0, 4.0]; // length 5
      const b = [6.0, 8.0]; // length 10, same direction
      expect(FaceMatcher.cosine(a, b), closeTo(1.0, 1e-9));
    });

    test('empty or length-mismatched vectors → 0', () {
      expect(FaceMatcher.cosine([], [1.0]), 0.0);
      expect(FaceMatcher.cosine([1.0, 2.0], [1.0]), 0.0);
    });
  });

  group('FaceMatcher.aggregateScores', () {
    test('empty hits → unknown, no candidates', () {
      final result = FaceMatcher().aggregateScores(
        box: box,
        hits: const [],
        personNames: const {'p1': '妈妈'},
      );
      expect(result.decision, FaceDecision.unknown);
      expect(result.candidates, isEmpty);
    });

    test('best ≥ recognized → recognized with top candidate', () {
      final result = const FaceMatcher().aggregateScores(
        box: box,
        hits: [
          const ScoredCandidate(photoId: 'ph1', personId: 'p1', score: 0.61),
          const ScoredCandidate(photoId: 'ph2', personId: 'p2', score: 0.3),
        ],
        personNames: const {'p1': '妈妈', 'p2': '爸爸'},
        relationships: const {'p1': '妈妈'},
      );
      expect(result.decision, FaceDecision.recognized);
      expect(result.candidates, hasLength(1));
      expect(result.candidates.first.personId, 'p1');
      expect(result.candidates.first.personName, '妈妈');
      expect(result.candidates.first.confidence, closeTo(0.61, 1e-9));
      expect(result.candidates.first.relationship, '妈妈');
      expect(result.candidates.first.evidencePhotoId, 'ph1');
    });

    test('ambiguous band → ambiguous with candidates', () {
      final result = const FaceMatcher().aggregateScores(
        box: box,
        hits: const [
          ScoredCandidate(photoId: 'ph1', personId: 'p1', score: 0.42),
        ],
      );
      expect(result.decision, FaceDecision.ambiguous);
      expect(result.candidates, hasLength(1));
    });

    test('best < ambiguous → unknown', () {
      final result = const FaceMatcher().aggregateScores(
        box: box,
        hits: const [
          ScoredCandidate(photoId: 'ph1', personId: 'p1', score: 0.2),
        ],
      );
      expect(result.decision, FaceDecision.unknown);
      expect(result.candidates, isEmpty);
    });

    test('per-person aggregation takes max (multi-photo)', () {
      final result = const FaceMatcher().aggregateScores(
        box: box,
        hits: const [
          ScoredCandidate(photoId: 'ph1', personId: 'p1', score: 0.3),
          ScoredCandidate(photoId: 'ph2', personId: 'p1', score: 0.58),
          ScoredCandidate(photoId: 'ph3', personId: 'p1', score: 0.5),
          ScoredCandidate(photoId: 'ph4', personId: 'p2', score: 0.2),
        ],
      );
      expect(result.decision, FaceDecision.recognized);
      expect(result.candidates.first.personId, 'p1');
      expect(result.candidates.first.confidence, closeTo(0.58, 1e-9));
      // meanTopK = mean of top aggregationTopK scores for p1
      expect(
        result.candidates.first.meanTopK,
        closeTo((0.58 + 0.5 + 0.3) / 3, 1e-9),
      );
    });

    test('top candidates sorted descending, capped at maxCandidates', () {
      final result = const FaceMatcher().aggregateScores(
        box: box,
        hits: [
          for (var i = 0; i < 6; i++)
            ScoredCandidate(
                photoId: 'ph$i', personId: 'p$i', score: 0.5 + i * 0.01),
        ],
      );
      final ids = [for (final c in result.candidates) c.personId];
      expect(ids, ['p5', 'p4', 'p3']);
    });
  });

  group('FaceMatcher.matchCosine', () {
    test('returns decision from gallery similarity', () {
      final query = [1.0, 0.0, 0.0];
      final gallery = const [
        CandidateEmbedding(photoId: 'ph1', personId: 'p1', embedding: [1.0, 0.0, 0.0]),
        CandidateEmbedding(photoId: 'ph2', personId: 'p2', embedding: [0.0, 1.0, 0.0]),
      ];
      final result = const FaceMatcher().matchCosine(
        box: box,
        query: query,
        gallery: gallery,
      );
      expect(result.decision, FaceDecision.recognized);
      expect(result.candidates.first.personId, 'p1');
    });
  });
}
