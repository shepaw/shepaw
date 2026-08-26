/// 人脸识别核心数据类型（纯 Dart，无 Flutter/插件依赖）。
///
/// 坐标统一约定：`FaceBox` 使用**相对原图的归一化坐标**（0..1），
/// 便于跨分辨率持久化与展示（与原图宽高相乘即像素框）。
library;

import 'dart:convert';
import 'dart:math' as math;

/// 归一化人脸框（x/y 为左上角，w/h 为宽高，均为 0..1 相对原图）。
class FaceBox {
  final double x;
  final double y;
  final double width;
  final double height;

  const FaceBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;
  double get area => width * height;

  /// 与 [other] 的交并比（IoU），用于 NMS 与非极大值抑制。
  double iouWith(FaceBox other) {
    final ix0 = math.max(x, other.x);
    final iy0 = math.max(y, other.y);
    final ix1 = math.min(x + width, other.x + other.width);
    final iy1 = math.min(y + height, other.y + other.height);
    final iw = math.max(0.0, ix1 - ix0);
    final ih = math.max(0.0, iy1 - iy0);
    final inter = iw * ih;
    final union = area + other.area - inter;
    if (union <= 0) return 0;
    return inter / union;
  }

  Map<String, dynamic> toJson() =>
      {'x': x, 'y': y, 'w': width, 'h': height};

  factory FaceBox.fromJson(Map<String, dynamic> json) => FaceBox(
        x: _asDouble(json['x']) ?? 0,
        y: _asDouble(json['y']) ?? 0,
        width: _asDouble(json['w']) ?? 0,
        height: _asDouble(json['h']) ?? 0,
      );

  static double? _asDouble(dynamic v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
}

/// 单个人脸检测结果：框 + 检测置信度 + embedding 向量。
class FaceEmbedding {
  final FaceBox box;
  final double confidence;
  final List<double> embedding;

  const FaceEmbedding({
    required this.box,
    required this.confidence,
    required this.embedding,
  });
}

/// 供匹配的候选（相册中已存的一行人脸 embedding）。
class CandidateEmbedding {
  final String photoId;
  final String personId;
  final List<double> embedding;

  const CandidateEmbedding({
    required this.photoId,
    required this.personId,
    required this.embedding,
  });
}

/// 单个人脸匹配候选（已按人聚合）。
class ScoredPerson {
  final String personId;
  final String personName;
  final double confidence; // 该人所有照片中最高相似度
  final double meanTopK; // 该人 top-K 相似度均值（多照一致性次信号）
  final String? evidencePhotoId;
  final String? relationship;
  final String? profileSummary;

  const ScoredPerson({
    required this.personId,
    required this.personName,
    required this.confidence,
    required this.meanTopK,
    this.evidencePhotoId,
    this.relationship,
    this.profileSummary,
  });

  Map<String, dynamic> toJson() => {
        'person_id': personId,
        'person_name': personName,
        'confidence': double.parse(confidence.toStringAsFixed(4)),
        'mean_top_k': double.parse(meanTopK.toStringAsFixed(4)),
        'evidence_photo_id': evidencePhotoId,
        'relationship': relationship,
        'profile_summary': profileSummary,
      };
}

/// 匹配决策：已识别 / 存疑（给出候选）/ 未知。
enum FaceDecision { recognized, ambiguous, unknown }

/// 单张人脸匹配结果。
class FaceMatchResult {
  final FaceBox box;
  final FaceDecision decision;
  final List<ScoredPerson> candidates; // 降序；unknown 时为空

  const FaceMatchResult({
    required this.box,
    required this.decision,
    required this.candidates,
  });

  Map<String, dynamic> toJson() => {
        'face': box.toJson(),
        'status': decision.name,
        'candidates': candidates.map((c) => c.toJson()).toList(),
      };
}

/// 参考相册中已登记的一位家人。
class AlbumPerson {
  final String id;
  final String name;
  final String? relationship;
  final String? notes;
  final String? profileJson;
  final int createdAt;
  final int updatedAt;

  const AlbumPerson({
    required this.id,
    required this.name,
    this.relationship,
    this.notes,
    this.profileJson,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AlbumPerson.fromRow(Map<String, dynamic> row) => AlbumPerson(
        id: row['id'] as String,
        name: row['name'] as String,
        relationship: row['relationship'] as String?,
        notes: row['notes'] as String?,
        profileJson: row['profile_json'] as String?,
        createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (row['updated_at'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'relationship': relationship,
        'notes': notes,
        'profile_json': profileJson,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };
}

/// 相册中的一张参考照（一行 = 一个检测到的人脸 embedding）。
class AlbumPhoto {
  final String id;
  final String personId;
  final String vedaId; // 向量库主键，删除时反查
  final String filePath; // 照片相对应用数据目录的路径（经 LocalFileStorageService.getFullPath 解析）
  final String? sourceRef; // 来源（message_id / 本地路径 / store_uri）
  final String engine; // 产生 embedding 的引擎 id
  final String faceBoxJson; // FaceBox 归一化 JSON
  final int createdAt;

  const AlbumPhoto({
    required this.id,
    required this.personId,
    required this.vedaId,
    required this.filePath,
    this.sourceRef,
    required this.engine,
    required this.faceBoxJson,
    required this.createdAt,
  });

  factory AlbumPhoto.fromRow(Map<String, dynamic> row) => AlbumPhoto(
        id: row['id'] as String,
        personId: row['person_id'] as String,
        vedaId: row['veda_id'] as String,
        filePath: row['file_path'] as String,
        sourceRef: row['source_ref'] as String?,
        engine: row['engine'] as String,
        faceBoxJson: row['face_box_json'] as String,
        createdAt: (row['created_at'] as num?)?.toInt() ?? 0,
      );

  FaceBox get faceBox {
    try {
      return FaceBox.fromJson(
          Map<String, dynamic>.from(jsonDecode(faceBoxJson) as Map));
    } catch (_) {
      return const FaceBox(x: 0, y: 0, width: 1, height: 1);
    }
  }
}

/// 建档（enroll）结果。
class AlbumEnrollResult {
  final String personId;
  final String personName;
  final String photoId;
  final int facesDetected;
  final int totalPhotosForPerson;
  final String engine;

  const AlbumEnrollResult({
    required this.personId,
    required this.personName,
    required this.photoId,
    required this.facesDetected,
    required this.totalPhotosForPerson,
    required this.engine,
  });
}
