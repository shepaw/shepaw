import 'package:veda/veda.dart';

import 'face_vector_store.dart';

/// 人脸 embedding 的 veda 向量库封装。
///
/// - 生产：[Veda.sqlite] 持久化到 `<Documents>/shepaw/veda_face_<dim>.db`
///   （路径由调用方计算传入）。
/// - 测试：[Veda.memory]（[dbPath] 传 null）。
///
/// 与 [StoreFaceVectorStore]（储物袋 `cognition/<agent>/face_vectors/`）同实现
/// [FaceVectorStore] 接口，可在测试 / 轻量场景与生产形态间切换。
///
/// veda 无 `getAll()`，因此"删除某人的全部向量"需要调用方先从
/// `face_photos` 表查出该人的 photoId 列表，再逐个 [removePhoto]。
class VedaFaceStore implements FaceVectorStore {
  VedaFaceStore._(this._veda, this.dimension);

  final Veda _veda;
  final int dimension;

  /// 打开向量库。 [dbPath] 为 null 时使用内存实现（测试 / 无持久化场景）。
  static Future<VedaFaceStore> open({
    required int dimension,
    String? dbPath,
  }) async {
    final veda = dbPath == null
        ? Veda.memory(dimension: dimension)
        : Veda.sqlite(dimension: dimension, path: dbPath);
    await veda.initialize();
    return VedaFaceStore._(veda, dimension);
  }

  /// 写入 / 覆盖一张照片的 embedding。
  @override
  Future<void> upsert({
    required String photoId,
    required String personId,
    required List<double> embedding,
  }) async {
    await _veda.add(
      id: photoId,
      embedding: embedding,
      metadata: {'person_id': personId, 'photo_id': photoId},
    );
  }

  /// 余弦检索（veda 自动 L2 归一化，[FaceVectorSearchHit.similarity] 即余弦相似度）。
  @override
  Future<List<FaceVectorSearchHit>> search(
    List<double> embedding, {
    int topK = 10,
  }) async {
    final results = await _veda.search(embedding, topK: topK);
    return [
      for (final r in results)
        FaceVectorSearchHit(
          photoId: r.item.metadata?['photo_id'] as String? ?? r.item.id,
          personId: r.item.metadata?['person_id'] as String? ?? '',
          similarity: r.similarity,
        ),
    ];
  }

  /// 删除单张照片的向量（幂等）。
  @override
  Future<void> removePhoto(String photoId) async {
    await _veda.delete(photoId);
  }

  /// 批量删除照片向量。
  @override
  Future<void> removePhotos(List<String> photoIds) async {
    for (final id in photoIds) {
      await _veda.delete(id);
    }
  }

  /// 清空向量库。
  @override
  Future<void> clear() async {
    await _veda.clear();
  }

  /// 关闭并释放资源。
  @override
  Future<void> close() async {
    await _veda.close();
  }
}
