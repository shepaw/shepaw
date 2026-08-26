import '../../models/vision/face_models.dart';

/// 非极大值抑制（NMS）：按得分降序保留彼此 IoU 低于阈值的人脸框。
///
/// 返回保留框的原始下标（已按得分降序）。
List<int> nonMaxSuppression(
  List<FaceBox> boxes,
  List<double> scores, {
  double iouThreshold = 0.45,
}) {
  assert(boxes.length == scores.length, 'boxes and scores must align');
  if (boxes.length < 2) {
    return [for (var i = 0; i < boxes.length; i++) i];
  }

  final order = List<int>.generate(boxes.length, (i) => i)
    ..sort((a, b) => scores[b].compareTo(scores[a]));

  final keep = <int>[];
  final suppressed = List<bool>.filled(boxes.length, false);

  for (var i = 0; i < order.length; i++) {
    final idx = order[i];
    if (suppressed[idx]) continue;
    keep.add(idx);
    for (var j = i + 1; j < order.length; j++) {
      final other = order[j];
      if (suppressed[other]) continue;
      if (boxes[idx].iouWith(boxes[other]) > iouThreshold) {
        suppressed[other] = true;
      }
    }
  }
  return keep;
}
