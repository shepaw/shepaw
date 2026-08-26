/// 人脸 embedding 向量存储抽象。
///
/// 实现：
/// - [VedaFaceStore]：veda（`Veda.memory` / `Veda.sqlite`），测试与轻量场景。
/// - [StoreFaceVectorStore]：储物袋 `cognition/<agent>/face_vectors/` 逐向量 JSON，
///   与 Agent 记忆同一套备份 / 恢复 / 镜像生命周期（推荐生产形态）。
library;

/// 一次向量检索命中。
class FaceVectorSearchHit {
  final String photoId;
  final String personId;
  final double similarity;

  const FaceVectorSearchHit({
    required this.photoId,
    required this.personId,
    required this.similarity,
  });
}

/// 人脸 embedding 向量存储接口。
abstract class FaceVectorStore {
  /// 写入 / 覆盖一张照片的 embedding。
  Future<void> upsert({
    required String photoId,
    required String personId,
    required List<double> embedding,
  });

  /// 余弦检索，按相似度降序，最多 [topK] 条。
  Future<List<FaceVectorSearchHit>> search(
    List<double> embedding, {
    int topK = 10,
  });

  /// 删除单张照片的向量（幂等）。
  Future<void> removePhoto(String photoId);

  /// 批量删除照片向量。
  Future<void> removePhotos(List<String> photoIds);

  /// 清空全部向量。
  Future<void> clear();

  /// 释放资源（可空实现）。
  Future<void> close();
}
