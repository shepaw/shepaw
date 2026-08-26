import 'package:sqflite/sqflite.dart';

/// 人脸相册建表 SQL（供 `_onCreate` / v32 迁移 / 测试复用）。
Future<void> createFaceAlbumTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS face_persons (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      relationship  TEXT,
      notes         TEXT,
      profile_json  TEXT,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_face_persons_name ON face_persons(name)');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS face_photos (
      id            TEXT PRIMARY KEY,
      person_id     TEXT NOT NULL,
      veda_id       TEXT NOT NULL,
      file_path     TEXT NOT NULL,
      source_ref    TEXT,
      engine        TEXT NOT NULL,
      face_box_json TEXT,
      created_at    INTEGER NOT NULL,
      FOREIGN KEY (person_id) REFERENCES face_persons(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_face_photos_person ON face_photos(person_id)');
}
