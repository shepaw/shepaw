import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/vision/face_models.dart';
import 'face_embedding_engine.dart';

/// 调试用确定性伪 embedding 引擎。
///
/// - 不对图片做真实人脸检测：按 [maxFaces] 个合成框输出。
/// - embedding 由字节流的确定性哈希生成：同字节 → 同向量（余弦≈1），
///   异字节 → 异向量。足够驱动整条管线（建档/检索/匹配）与单元测试，
///   **但不具备生物特征识别能力**，用于无模型文件时的优雅降级与开发调试。
class DebugFaceEmbeddingEngine implements FaceEmbeddingEngine {
  const DebugFaceEmbeddingEngine({this.maxFaces = 1});

  /// 每次输出几个人脸框（模拟多人）。
  final int maxFaces;

  @override
  String get id => 'debug';

  @override
  String get label => 'Debug (deterministic pixel-hash — NOT biometric)';

  @override
  bool get isDebug => true;

  @override
  Future<bool> get isAvailable async => true;

  @override
  double get highThreshold => 0.55;

  @override
  double get lowThreshold => 0.35;

  @override
  Future<List<FaceEmbedding>> detectAndEmbed(
      Uint8List imageBytes) async {
    if (imageBytes.isEmpty) return const [];

    final faces = <FaceEmbedding>[];
    for (var i = 0; i < maxFaces; i++) {
      faces.add(FaceEmbedding(
        box: _syntheticBox(i, maxFaces),
        confidence: math.max(0.6, 1.0 - i * 0.1),
        embedding: _pseudoEmbedding(imageBytes, i),
      ));
    }
    return faces;
  }

  static FaceBox _syntheticBox(int index, int total) {
    final cols = math.min(2, total);
    return FaceBox(
      x: 0.15 + (index % cols) * 0.45,
      y: 0.15 + (index ~/ cols) * 0.45,
      width: 0.4,
      height: 0.4,
    );
  }

  /// 确定性伪 embedding：字节流哈希映射到 192-d 并 L2 归一化。
  static List<double> _pseudoEmbedding(Uint8List bytes, int seed) {
    const dim = FaceEmbeddingEngine.embeddingDim;
    final emb = List<double>.filled(dim, 0);
    var acc = 0x811c9dc5 ^ (seed * 0x01000193 & 0xFFFFFFFF);
    for (var i = 0; i < bytes.length; i++) {
      acc = ((acc ^ bytes[i]) * 31) & 0xFFFFFFFF;
      emb[i % dim] += ((acc & 0xFF) / 255.0) * 2.0 - 1.0;
    }
    // 混入字节长度，避免不同长度全零输入碰撞
    emb[0] += bytes.length & 0xFF;
    emb[1] += (bytes.length >> 8) & 0xFF;

    var norm = 0.0;
    for (final v in emb) {
      norm += v * v;
    }
    norm = norm <= 0 ? 1.0 : math.sqrt(norm);
    return [for (final v in emb) v / norm];
  }
}
