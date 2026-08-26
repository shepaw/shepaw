import 'dart:math' as math;

import '../../models/vision/face_models.dart';

/// 一个带分数的候选命中（来自向量检索）。
class ScoredCandidate {
  final String photoId;
  final String personId;
  final double score;

  const ScoredCandidate({
    required this.photoId,
    required this.personId,
    required this.score,
  });
}

/// 人脸匹配：余弦相似度 + 按人聚合 + 阈值分层。
///
/// 阈值分层（MobileFaceNet 类模型的经验值，随引擎可调）：
/// - `best >= recognizedThreshold` → `recognized`
/// - `best >= ambiguousThreshold`  → `ambiguous`（附候选）
/// - 其余                          → `unknown`
///
/// 每人多照聚合：主置信度取该人所有照片中的 **max**（抗单张低分），
/// 同时记录 `meanTopK`（该人 top-K 均值）作为多照一致性的次信号。
class FaceMatcher {
  static const double recognizedThreshold = 0.55;
  static const double ambiguousThreshold = 0.35;
  static const int aggregationTopK = 3;
  static const int maxCandidates = 3;

  const FaceMatcher();

  /// 余弦相似度（[-1,1]）。空向量按相似度 0 处理。
  static double cosine(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na <= 0 || nb <= 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// 对查询向量与相册 embedding 全集做余弦匹配。
  ///
  /// [gallery] 为相册中已存的候选 embedding；[topK] 限制返回的候选人数。
  FaceMatchResult matchCosine({
    required FaceBox box,
    required List<double> query,
    required List<CandidateEmbedding> gallery,
  }) {
    final hits = [
      for (final c in gallery)
        ScoredCandidate(
          photoId: c.photoId,
          personId: c.personId,
          score: cosine(query, c.embedding),
        ),
    ];
    return aggregateScores(box: box, hits: hits);
  }

  /// 对已算好分数的命中做按人聚合与分层。
  FaceMatchResult aggregateScores({
    required FaceBox box,
    required List<ScoredCandidate> hits,
    Map<String, String>? personNames,
    Map<String, String>? relationships,
  }) {
    // 按人分组，记录分数序列
    final byPerson = <String, List<ScoredCandidate>>{};
    for (final h in hits) {
      byPerson.putIfAbsent(h.personId, () => []).add(h);
    }

    final scored = <ScoredPerson>[];
    for (final entry in byPerson.entries) {
      final personId = entry.key;
      final list = entry.value
        ..sort((a, b) => b.score.compareTo(a.score));
      final best = list.first.score;
      final top = list.length <= aggregationTopK
          ? list
          : list.sublist(0, aggregationTopK);
      final mean = top.fold<double>(0, (acc, c) => acc + c.score) / top.length;
      scored.add(ScoredPerson(
        personId: personId,
        personName: personNames?[personId] ?? personId,
        confidence: best,
        meanTopK: mean,
        evidencePhotoId: list.first.photoId,
        relationship: relationships?[personId],
      ));
    }
    scored.sort((a, b) => b.confidence.compareTo(a.confidence));

    final best = scored.isEmpty ? 0.0 : scored.first.confidence;
    final FaceDecision decision;
    if (scored.isEmpty || best < ambiguousThreshold) {
      decision = FaceDecision.unknown;
    } else if (best >= recognizedThreshold) {
      decision = FaceDecision.recognized;
    } else {
      decision = FaceDecision.ambiguous;
    }

    // 候选只保留达到"存疑线"的人（低于 ambiguousThreshold 的是噪声，不作为候选呈现）
    final candidates = decision == FaceDecision.unknown
        ? <ScoredPerson>[]
        : scored
            .where((s) => s.confidence >= ambiguousThreshold)
            .take(maxCandidates)
            .toList();

    return FaceMatchResult(box: box, decision: decision, candidates: candidates);
  }
}
