import 'dart:convert';
import 'dart:typed_data';

import '../../storage/local_store.dart';
import '../../storage/memory_paths.dart';
import '../../storage/pouch_scope.dart';
import '../../storage/pouch_scope_store.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';
import '../agent_memory_store_service.dart';
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
/// 落点：`pouch://<pouch>/agent:<agent>/identity/face_vectors/<photo_id>.json`
/// 与 Agent 的 soul / memory 同一个 scope，天然获得备份 / 恢复 / `store wipe`
/// 的生命周期统一，且默认私有（跨端只读不放行文件）。
///
/// 检索模型：启动/首访时读全量向量进内存索引，之后内存余弦检索
/// （量级：几十人 × 192-d，开销可忽略）；写入/删除即增删对应 JSON 文件。
/// 这种"不可变小文件"形态符合 store 内容寻址模型（对比：可变 sqlite 文件
/// 每写一次整文件重写，会抖同步游标）。
class StoreFaceVectorStore implements FaceVectorStore {
  StoreFaceVectorStore._({
    required PouchScopeStore store,
    required PouchScope scope,
  })  : _store = store,
        _scope = scope;

  /// 打开（默认归属 She 的 `agent:<she>/identity/face_vectors/`）。
  static Future<StoreFaceVectorStore> open({String? agentId}) async {
    final id = agentId ?? SheService.sheId;
    // 先把 v2 `cognition/<agent>/face_vectors/` 搬进 v3。
    await AgentMemoryStoreService.forAgent(id).ensureV2Migration();
    final store = await StoreService.instance.scopeStore();
    return StoreFaceVectorStore._(
      store: store,
      scope: MemoryPaths.scopeFor(id),
    );
  }

  final PouchScopeStore _store;
  final PouchScope _scope;

  final Map<String, _StoredVector> _byPhotoId = {};
  Future<void>? _loadFuture;

  // ── 路径 ───────────────────────────────────────────────────────────────────

  String _vectorRelPath(String photoId) => MemoryPaths.faceVectorPath(photoId);

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
    final entries = await _store.listChildren(
      _scope,
      path: MemoryPaths.faceVectorsDir(),
      limit: 10000,
    );
    return [for (final e in entries) if (!e.isDir) e];
  }

  Future<void> _writeJson(String relPath, Map<String, dynamic> json) async {
    final bytes =
        Uint8List.fromList(utf8.encode(const JsonEncoder().convert(json)));
    await _store.write(_scope, relPath, bytes);
  }

  Future<Map<String, dynamic>?> _readJson(String relPath) async {
    final bytes = await _store.read(_scope, relPath);
    if (bytes == null || bytes.isEmpty) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  Future<void> _deleteQuietly(String relPath) async {
    try {
      await _store.delete(_scope, relPath);
    } on StoreException catch (e) {
      if (e.code != StoreError.notFound) rethrow;
    }
  }
}
