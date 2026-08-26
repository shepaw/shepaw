import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../storage/device_identity.dart';
import '../../storage/local_store.dart';
import '../../storage/memory_paths.dart';
import '../../storage/runtime_paths.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';
import '../she_service.dart';
import 'face_matcher.dart';
import 'face_vector_store.dart';

/// 一条持久化的向量（内存缓存项）。
class _StoredVector {
  final String personId;
  final List<double> embedding;
  const _StoredVector({required this.personId, required this.embedding});
}

/// 储物袋形态的人脸向量存储：逐向量一个 JSON 文件。
///
/// 落点：`store://cognition/<device>/<agent>/face_vectors/<photo_id>.json`
/// 与 Agent 记忆（soul / entries）同一分区，天然获得备份 / 恢复 / `store wipe` /
/// 跨设备镜像的生命周期统一，且默认私有（跨端只读不放行文件）。
///
/// 检索模型：启动/首访时读全量向量进内存索引，之后内存余弦检索
/// （量级：几十人 × 192-d，开销可忽略）；写入/删除即增删对应 JSON 文件。
/// 这种"不可变小文件"形态符合 store 内容寻址模型（对比：可变 sqlite 文件
/// 每写一次整文件重写，会抖同步游标）。
class StoreFaceVectorStore implements FaceVectorStore {
  StoreFaceVectorStore._({
    required LocalStore store,
    required String deviceId,
    required String agentId,
  })  : _store = store,
        _deviceId = deviceId,
        _agentRoot = MemoryPaths.agentRoot(agentId);

  /// 打开（默认归属 She 的储物袋 `cognition/<she>/face_vectors/`）。
  static Future<StoreFaceVectorStore> open({String? agentId}) async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    return StoreFaceVectorStore._(
      store: store,
      deviceId: deviceId,
      agentId: agentId ?? SheService.sheId,
    );
  }

  final LocalStore _store;
  final String _deviceId;
  final String _agentRoot;

  final Map<String, _StoredVector> _byPhotoId = {};
  Future<void>? _loadFuture;

  // ── 路径 ───────────────────────────────────────────────────────────────────

  String get _vectorsDir => '$_agentRoot/face_vectors/';

  String _vectorRelPath(String photoId) =>
      '$_vectorsDir${RuntimePaths.sanitizeSegment(photoId)}.json';

  // ── FaceVectorStore ────────────────────────────────────────────────────────

  @override
  Future<void> upsert({
    required String photoId,
    required String personId,
    required List<double> embedding,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _writeJson(
      _vectorRelPath(photoId),
      {
        'photo_id': photoId,
        'person_id': personId,
        'embedding': embedding,
        'created_at': now,
      },
    );
    _byPhotoId[photoId] =
        _StoredVector(personId: personId, embedding: List.of(embedding));
  }

  @override
  Future<List<FaceVectorSearchHit>> search(
    List<double> embedding, {
    int topK = 10,
  }) async {
    await _ensureLoaded();
    final scored = <FaceVectorSearchHit>[];
    for (final entry in _byPhotoId.entries) {
      scored.add(FaceVectorSearchHit(
        photoId: entry.key,
        personId: entry.value.personId,
        similarity: FaceMatcher.cosine(embedding, entry.value.embedding),
      ));
    }
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    if (scored.length <= topK) return scored;
    return scored.sublist(0, topK);
  }

  @override
  Future<void> removePhoto(String photoId) async {
    await _ensureLoaded();
    _byPhotoId.remove(photoId);
    await _deleteQuietly(_vectorRelPath(photoId));
  }

  @override
  Future<void> removePhotos(List<String> photoIds) async {
    for (final id in photoIds) {
      await removePhoto(id);
    }
  }

  @override
  Future<void> clear() async {
    await _ensureLoaded();
    final entries = await _listVectorFiles();
    for (final e in entries) {
      await _deleteQuietly(e.path);
    }
    _byPhotoId.clear();
  }

  @override
  Future<void> close() async {
    // 无长驻资源；内存索引随实例回收
  }

  // ── 加载 / 持久化 ──────────────────────────────────────────────────────────

  Future<void> _ensureLoaded() => _loadFuture ??= _load();

  Future<void> _load() async {
    final entries = await _listVectorFiles();
    final loaded = <String, _StoredVector>{};
    for (final e in entries) {
      final json = await _readJson(e.path);
      if (json == null) continue;
      final photoId = json['photo_id'] as String?;
      final personId = json['person_id'] as String?;
      final rawEmb = json['embedding'];
      if (photoId == null || personId == null || rawEmb is! List) continue;
      final emb = <double>[];
      for (final v in rawEmb) {
        if (v is num) emb.add(v.toDouble());
      }
      if (emb.isEmpty) continue;
      loaded[photoId] = _StoredVector(personId: personId, embedding: emb);
    }
    _byPhotoId
      ..clear()
      ..addAll(loaded);
  }

  Future<List<StoreEntry>> _listVectorFiles() async {
    final entries = await _store.list(
      _deviceId,
      StoreSpace.cognition,
      prefix: _vectorsDir,
      limit: 10000,
      computeHash: false,
    );
    return [for (final e in entries) if (!e.isDir) e];
  }

  Future<void> _writeJson(String relPath, Map<String, dynamic> json) async {
    final bytes =
        Uint8List.fromList(utf8.encode(const JsonEncoder().convert(json)));
    final hash = crypto.sha256.convert(bytes).toString();
    final (uploadId, _) = await _store.writeBegin(
      deviceId: _deviceId,
      space: StoreSpace.cognition,
      path: relPath,
      size: bytes.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + LocalStore.maxReadChunk) > bytes.length
          ? bytes.length
          : offset + LocalStore.maxReadChunk;
      await _store.writeChunk(
        _deviceId,
        StoreSpace.cognition,
        uploadId,
        offset,
        bytes.sublist(offset, end),
      );
      offset = end;
    }
    final (ok, failed) = await _store.commit(
      _deviceId,
      StoreSpace.cognition,
      [uploadId],
    );
    if (failed.isNotEmpty || ok.isEmpty) {
      throw StateError('face vector write failed: $failed');
    }
  }

  Future<Map<String, dynamic>?> _readJson(String relPath) async {
    try {
      final buf = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, size, eof) = await _store.read(
          _deviceId,
          StoreSpace.cognition,
          relPath,
          offset,
          LocalStore.maxReadChunk,
        );
        if (chunk.isNotEmpty) buf.add(chunk);
        offset += chunk.length;
        if (eof || offset >= size) break;
      }
      final bytes = buf.takeBytes();
      if (bytes.isEmpty) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : null;
    } on StoreException catch (e) {
      if (e.code == StoreError.notFound) return null;
      rethrow;
    }
  }

  Future<void> _deleteQuietly(String relPath) async {
    try {
      await _store.delete(_deviceId, StoreSpace.cognition, relPath);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
  }
}
