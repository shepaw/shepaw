import 'package:sqflite/sqflite.dart';

import '../../models/vision/face_models.dart';
import '../local_database_service.dart';

/// 人脸相册数据访问层：参考相册（人 + 参考照）元数据。
///
/// embedding 本体存于 veda 向量库（见 `VedaFaceStore`），本表只存
/// 元数据与照片路径；删除时需先取 veda_id 列表清理向量库。
extension FaceAlbumDao on LocalDatabaseService {
  // ==================== face_persons ====================

  /// 写入或更新一位家人。
  Future<void> upsertFacePerson(AlbumPerson person) async {
    final db = await database;
    await db.insert(
      'face_persons',
      {
        'id': person.id,
        'name': person.name,
        'relationship': person.relationship,
        'notes': person.notes,
        'profile_json': person.profileJson,
        'created_at': person.createdAt,
        'updated_at': person.updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<AlbumPerson?> getFacePersonById(String id) async {
    final db = await database;
    final rows = await db.query(
      'face_persons',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : AlbumPerson.fromRow(rows.first);
  }

  Future<AlbumPerson?> getFacePersonByName(String name) async {
    final db = await database;
    final rows = await db.query(
      'face_persons',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : AlbumPerson.fromRow(rows.first);
  }

  /// 按 id 或名字精确查找（id 优先）。
  Future<AlbumPerson?> findFacePerson(String idOrName) async {
    final byId = await getFacePersonById(idOrName);
    if (byId != null) return byId;
    return getFacePersonByName(idOrName);
  }

  Future<List<AlbumPerson>> listFacePersons() async {
    final db = await database;
    final rows = await db.query('face_persons', orderBy: 'created_at ASC');
    return [for (final r in rows) AlbumPerson.fromRow(r)];
  }

  /// 删除一位家人（级联删除其全部参考照行）。
  Future<void> deleteFacePerson(String id) async {
    final db = await database;
    await db.delete('face_persons', where: 'id = ?', whereArgs: [id]);
  }

  /// 更新档案 JSON 与更新时间。
  Future<void> updateFacePersonProfile(String id, String profileJson) async {
    final db = await database;
    await db.update(
      'face_persons',
      {
        'profile_json': profileJson,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空人脸相册（测试 / 重置用）。注意：不清理 veda 向量库。
  Future<void> clearFaceAlbum() async {
    final db = await database;
    await db.delete('face_photos');
    await db.delete('face_persons');
  }

  // ==================== face_photos ====================

  Future<void> insertFacePhoto(AlbumPhoto photo) async {
    final db = await database;
    await db.insert(
      'face_photos',
      {
        'id': photo.id,
        'person_id': photo.personId,
        'veda_id': photo.vedaId,
        'file_path': photo.filePath,
        'source_ref': photo.sourceRef,
        'engine': photo.engine,
        'face_box_json': photo.faceBoxJson,
        'created_at': photo.createdAt,
      },
    );
  }

  Future<List<AlbumPhoto>> listFacePhotosByPerson(String personId) async {
    final db = await database;
    final rows = await db.query(
      'face_photos',
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'created_at ASC',
    );
    return [for (final r in rows) AlbumPhoto.fromRow(r)];
  }

  Future<AlbumPhoto?> getFacePhotoById(String id) async {
    final db = await database;
    final rows = await db.query(
      'face_photos',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : AlbumPhoto.fromRow(rows.first);
  }

  Future<void> deleteFacePhoto(String id) async {
    final db = await database;
    await db.delete('face_photos', where: 'id = ?', whereArgs: [id]);
  }
}
