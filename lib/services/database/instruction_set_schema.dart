import 'package:sqflite/sqflite.dart';

/// 指令集建表 SQL（供 `_onCreate` / v33 迁移 / 测试复用）。
///
/// `owner_agent_id` 记录生成指令的 agent（指令所属 agent），
/// 执行时自动路由回该 agent（`instructions run`）。
Future<void> createInstructionSetTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS instruction_sets (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL UNIQUE,
      description     TEXT,
      content         TEXT NOT NULL,
      owner_agent_id  TEXT NOT NULL,
      owner_agent_name TEXT NOT NULL DEFAULT '',
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_instruction_sets_owner '
      'ON instruction_sets(owner_agent_id)');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_instruction_sets_updated '
      'ON instruction_sets(updated_at DESC)');
}
