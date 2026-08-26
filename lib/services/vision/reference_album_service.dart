import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/message.dart';
import '../../models/vision/face_models.dart';
import '../../models/vision/person_visual_profile.dart';
import '../attachment_service.dart';
import '../local_database_service.dart';
import '../local_file_storage_service.dart';
import 'face_embedding_engine.dart';
import 'face_matcher.dart';
import 'face_vector_store.dart';
import 'store_face_vector_store.dart';
import 'visual_profile_extractor.dart';

/// 相册业务异常（用于 CLI 友好报错）。
class AlbumException implements Exception {
  final String message;
  const AlbumException(this.message);
  @override
  String toString() => message;
}

/// 一位家人 + 参考照数量（`album list` 展示用）。
class AlbumPersonWithStats {
  final AlbumPerson person;
  final int photoCount;
  const AlbumPersonWithStats({required this.person, required this.photoCount});
}

/// 参考相册服务：建档 / 识别 / 档案构建的编排层。
///
/// 依赖可注入（测试用内存 DB + `VedaFaceStore.open(dimension:)` 内存向量库 +
/// Debug 引擎）：
/// - [_db]：`shepaw.db`（face_persons / face_photos 元数据）
/// - [vectors]：[FaceVectorStore]（默认 [StoreFaceVectorStore] 储物袋
///   `cognition/<she>/face_vectors/` 逐向量 JSON；测试可注入 veda 内存实现）
/// - [engine]：人脸特征引擎（默认走注册表解析）
///
/// 识别链路：引擎检测人脸 → 每张脸向量库余弦检索 → [FaceMatcher] 按人聚合。
class ReferenceAlbumService {
  ReferenceAlbumService({
    LocalDatabaseService? db,
    FaceVectorStore? vectors,
    FaceEmbeddingEngine? engine,
    this.profileBuilder,
  })  : _db = db ?? LocalDatabaseService(),
        _vectors = vectors,
        _engine = engine;

  final LocalDatabaseService _db;
  final FaceVectorStore? _vectors;
  final FaceEmbeddingEngine? _engine;

  /// 视觉档案构建器（默认为 [VisualProfileExtractor]；测试可注入 stub）。
  final VisualProfileBuilder? profileBuilder;

  static const _uuid = Uuid();

  Future<FaceVectorStore>? _vectorsFuture;

  Future<FaceVectorStore> get _vectorsStore async {
    final injected = _vectors;
    if (injected != null) return injected;
    return _vectorsFuture ??= _openDefaultVectors();
  }

  /// 生产形态：储物袋 `cognition/<agent>/face_vectors/`（与 Agent 记忆同
  /// 生命周期：备份 / 恢复 / `store wipe` / 跨设备镜像统一）。
  Future<FaceVectorStore> _openDefaultVectors() =>
      StoreFaceVectorStore.open();

  Future<FaceEmbeddingEngine> get _engineAsync async =>
      _engine ?? await FaceEmbeddingEngineRegistry.instance.resolve();

  // ==================== 建档 ====================

  /// 为 [name] 登记一张基准照。
  ///
  /// 同名人已存在时复用其 person（追加参考照）；否则新建。取图中置信度最高
  /// 的人脸入库，照片原样落盘 `shepaw/images/`。
  Future<AlbumEnrollResult> enroll({
    required String name,
    required Uint8List imageBytes,
    String? relationship,
    String? caption,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const AlbumException('姓名不能为空');
    }
    final engine = await _engineAsync;
    final faces = await engine.detectAndEmbed(imageBytes);
    if (faces.isEmpty) {
      throw const AlbumException('未检测到人脸，请换一张更清晰的正面照');
    }
    faces.sort((a, b) => b.confidence.compareTo(a.confidence));
    final best = faces.first;

    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _db.getFacePersonByName(trimmed);
    final personId = existing?.id ?? 'fp_${_uuid.v4()}';
    if (existing == null) {
      await _db.upsertFacePerson(AlbumPerson(
        id: personId,
        name: trimmed,
        relationship: relationship,
        createdAt: now,
        updatedAt: now,
      ));
    }

    // 照片落盘（相对应用数据目录的路径）
    final storage = LocalFileStorageService();
    final relPath =
        await storage.saveImageBytes(imageBytes, 'jpg', type: ResourceType.images);

    final photoId = 'fph_${_uuid.v4()}';
    await _db.insertFacePhoto(AlbumPhoto(
      id: photoId,
      personId: personId,
      vedaId: photoId,
      filePath: relPath,
      sourceRef: caption,
      engine: engine.id,
      faceBoxJson: jsonEncode(best.box.toJson()),
      createdAt: now,
    ));
    await (await _vectorsStore).upsert(
      photoId: photoId,
      personId: personId,
      embedding: best.embedding,
    );

    final total = (await _db.listFacePhotosByPerson(personId)).length;
    return AlbumEnrollResult(
      personId: personId,
      personName: trimmed,
      photoId: photoId,
      facesDetected: faces.length,
      totalPhotosForPerson: total,
      engine: engine.id,
    );
  }

  // ==================== 查询 ====================

  Future<List<AlbumPerson>> listPersons() => _db.listFacePersons();

  Future<List<AlbumPersonWithStats>> listPersonsWithStats() async {
    final persons = await _db.listFacePersons();
    final result = <AlbumPersonWithStats>[];
    for (final person in persons) {
      final photos = await _db.listFacePhotosByPerson(person.id);
      result.add(
          AlbumPersonWithStats(person: person, photoCount: photos.length));
    }
    return result;
  }

  Future<AlbumPerson?> findPerson(String idOrName) =>
      _db.findFacePerson(idOrName);

  Future<List<AlbumPhoto>> listPhotos(String personId) =>
      _db.listFacePhotosByPerson(personId);

  // ==================== 删除 ====================

  /// 删除一位家人：清理向量库、显式删照片行（SQLite 默认未开
  /// `PRAGMA foreign_keys`，级联不可靠）、删 person 行、删除照片文件。
  Future<void> removePerson(String personId) async {
    final photos = await _db.listFacePhotosByPerson(personId);
    await (await _vectorsStore)
        .removePhotos([for (final p in photos) p.id]);
    for (final photo in photos) {
      await _db.deleteFacePhoto(photo.id);
    }
    await _db.deleteFacePerson(personId);

    final storage = LocalFileStorageService();
    for (final photo in photos) {
      await storage.deleteImage(photo.filePath);
    }
  }

  // ==================== 识别 ====================

  /// 识别一张图中的所有人脸，返回每张脸的匹配结果（按人聚合、阈值分层）。
  Future<List<FaceMatchResult>> recognizeImage(
    Uint8List imageBytes, {
    int topK = 3,
  }) async {
    final engine = await _engineAsync;
    final faces = await engine.detectAndEmbed(imageBytes);
    if (faces.isEmpty) return const [];

    final persons = await _db.listFacePersons();
    final names = {for (final p in persons) p.id: p.name};
    final rels = {
      for (final p in persons)
        if (p.relationship != null) p.id: p.relationship!,
    };
    final summaries = {
      for (final p in persons) p.id: _profileSummary(p.profileJson),
    };

    final vectors = await _vectorsStore;
    const matcher = FaceMatcher();
    final results = <FaceMatchResult>[];
    for (final face in faces) {
      final hits = await vectors.search(face.embedding, topK: 10);
      final scored = [
        for (final h in hits)
          ScoredCandidate(
              photoId: h.photoId, personId: h.personId, score: h.similarity),
      ];
      final matched = matcher.aggregateScores(
        box: face.box,
        hits: scored,
        personNames: names,
        relationships: rels,
      );
      results.add(FaceMatchResult(
        box: matched.box,
        decision: matched.decision,
        candidates: [
          for (final c in matched.candidates)
            ScoredPerson(
              personId: c.personId,
              personName: c.personName,
              confidence: c.confidence,
              meanTopK: c.meanTopK,
              evidencePhotoId: c.evidencePhotoId,
              relationship: c.relationship,
              profileSummary: summaries[c.personId],
            ),
        ],
      ));
    }
    return results;
  }

  // ==================== 图片输入解析 ====================

  /// 统一图片输入：`--path` 直接读文件；`--message_id` 走消息附件。
  Future<Uint8List> resolveImageBytes({
    String? path,
    String? messageId,
  }) async {
    if (path != null && path.trim().isNotEmpty) {
      final file = File(path.trim());
      if (!await file.exists()) {
        throw AlbumException('图片文件不存在：$path');
      }
      return file.readAsBytes();
    }
    if (messageId != null && messageId.trim().isNotEmpty) {
      final row = await _db.getMessageById(messageId.trim());
      if (row == null) throw AlbumException('消息不存在：$messageId');
      final message = _messageFromRow(row);
      final attachment =
          await AttachmentService(_db).buildAttachmentData(message);
      if (attachment == null) {
        throw const AlbumException('该消息没有可读的附件');
      }
      return attachment.bytes;
    }
    throw const AlbumException('需要提供 --image 或 --message_id');
  }

  // ==================== 视觉档案 ====================

  /// 为该家人构建（或刷新）结构化视觉档案并持久化。
  ///
  /// [builder] 不传时用默认 [VisualProfileExtractor]；[photos] 不传时取
  /// 该人名下的全部参考照。
  Future<PersonVisualProfile> buildProfile(
    String personId, {
    VisualProfileBuilder? builder,
    List<AttachmentData>? photos,
  }) async {
    final person = await _db.getFacePersonById(personId);
    if (person == null) throw const AlbumException('未找到该家人');

    final attachments = photos ?? await _personPhotoAttachments(personId);
    if (attachments.isEmpty) {
      throw AlbumException('${person.name} 没有可用的参考照，无法构建档案');
    }

    final ex = builder ?? profileBuilder ?? VisualProfileExtractor();
    final profile = await ex.extract(personName: person.name, photos: attachments);
    await _db.updateFacePersonProfile(personId, profile.encode());
    return profile;
  }

  /// 读取该人名下所有参考照为 [AttachmentData]（供档案提取 / 展示）。
  Future<List<AttachmentData>> _personPhotoAttachments(String personId) async {
    final photos = await _db.listFacePhotosByPerson(personId);
    final storage = LocalFileStorageService();
    final result = <AttachmentData>[];
    for (final photo in photos) {
      try {
        final full = await storage.getFullPath(photo.filePath);
        final file = File(full);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        result.add(AttachmentData(
          fileName: p.basename(full),
          mimeType: 'image/jpeg',
          sizeBytes: bytes.length,
          bytes: bytes,
          semanticType: 'image',
        ));
      } catch (_) {
        // 单张照片读取失败不影响其余照片
      }
    }
    return result;
  }

  static String _profileSummary(String? profileJson) {
    if (profileJson == null || profileJson.isEmpty) return '';
    return parseVisualProfile(profileJson).summarize();
  }

  // ==================== 工具 ====================

  /// messages 行 → [Message]（AttachmentService 需要 Message 对象）。
  static Message _messageFromRow(Map<String, dynamic> row) {
    Map<String, dynamic>? metadata;
    final rawMeta = row['metadata'];
    if (rawMeta is String && rawMeta.isNotEmpty) {
      try {
        metadata = Map<String, dynamic>.from(jsonDecode(rawMeta) as Map);
      } catch (_) {}
    } else if (rawMeta is Map) {
      metadata = Map<String, dynamic>.from(rawMeta);
    }
    final createdAt = row['created_at'];
    final ts = createdAt is int
        ? createdAt
        : DateTime.tryParse(createdAt?.toString() ?? '')
              ?.millisecondsSinceEpoch ??
            0;
    return Message.simple(
      id: row['id'] as String? ?? '',
      channelId: row['channel_id'] as String? ?? '',
      senderId: row['sender_id'] as String? ?? '',
      senderName: row['sender_name'] as String? ?? '',
      senderType: row['sender_type'] as String? ?? 'user',
      content: row['content'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      type: _messageTypeFromRow(row['message_type'] as String?),
      replyToId: row['reply_to_id'] as String?,
      metadata: metadata,
    );
  }

  static MessageType _messageTypeFromRow(String? raw) {
    switch (raw) {
      case 'image':
        return MessageType.image;
      case 'file':
        return MessageType.file;
      case 'audio':
        return MessageType.audio;
      case 'system':
        return MessageType.system;
      default:
        return MessageType.text;
    }
  }
}
