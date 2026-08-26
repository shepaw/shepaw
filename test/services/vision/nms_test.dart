import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/vision/face_models.dart';
import 'package:shepaw/services/vision/nms.dart';

void main() {
  group('nonMaxSuppression', () {
    test('keeps higher-scoring box when IoU exceeds threshold', () {
      // 两个几乎重叠的框，第二个得分更高
      final boxes = [
        const FaceBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        const FaceBox(x: 0.12, y: 0.12, width: 0.5, height: 0.5),
      ];
      final scores = [0.6, 0.9];
      final keep = nonMaxSuppression(boxes, scores);
      expect(keep, [1]);
    });

    test('keeps both boxes when they do not overlap', () {
      final boxes = [
        const FaceBox(x: 0.0, y: 0.0, width: 0.2, height: 0.2),
        const FaceBox(x: 0.6, y: 0.6, width: 0.2, height: 0.2),
      ];
      final scores = [0.5, 0.5];
      final keep = nonMaxSuppression(boxes, scores);
      expect(keep.toSet(), {0, 1});
    });

    test('returns indices sorted by score descending', () {
      final boxes = [
        const FaceBox(x: 0.0, y: 0.0, width: 0.2, height: 0.2),
        const FaceBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
        const FaceBox(x: 0.6, y: 0.6, width: 0.2, height: 0.2),
      ];
      final scores = [0.5, 0.9, 0.7];
      final keep = nonMaxSuppression(boxes, scores);
      expect(keep, [1, 2, 0]);
    });

    test('single box short-circuits', () {
      expect(
        nonMaxSuppression(
          [const FaceBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5)],
          [0.8],
        ),
        [0],
      );
    });

    test('empty input returns empty', () {
      expect(nonMaxSuppression([], []), isEmpty);
    });

    test('suppresses only when IoU strictly exceeds threshold', () {
      // 两个刚好相切的框 IoU = 0，不应抑制
      final boxes = [
        const FaceBox(x: 0.0, y: 0.0, width: 0.3, height: 0.3),
        const FaceBox(x: 0.3, y: 0.0, width: 0.3, height: 0.3),
      ];
      final keep = nonMaxSuppression(boxes, [0.8, 0.7]);
      expect(keep.toSet(), {0, 1});
    });
  });
}
