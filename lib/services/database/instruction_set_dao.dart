import 'package:sqflite/sqflite.dart';
import '../local_database_service.dart';
import '../../models/instruction_set.dart';

/// 指令集数据访问层（`instruction_sets` 表）。
extension InstructionSetDao on LocalDatabaseService {
  /// 插入或更新指令集条目（name 唯一冲突时整体替换）。
  Future<void> upsertInstructionSet(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'instruction_sets',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 按主键查询。
  Future<InstructionSet?> queryInstructionSetById(String id) async {
    final db = await database;
    final rows = await db.query(
      'instruction_sets',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : InstructionSet.fromRow(rows.first);
  }

  /// 按唯一名称查询（CLI 主要通过名称操作）。
  Future<InstructionSet?> queryInstructionSetByName(String name) async {
    final db = await database;
    final rows = await db.query(
      'instruction_sets',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : InstructionSet.fromRow(rows.first);
  }

  /// 列出全部指令，可仅过滤某个 owner（按更新时间倒序）。
  Future<List<InstructionSet>> queryAllInstructionSets({
    String? ownerAgentId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'instruction_sets',
      where: ownerAgentId == null ? null : 'owner_agent_id = ?',
      whereArgs: ownerAgentId == null ? null : [ownerAgentId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(InstructionSet.fromRow).toList();
  }

  /// 删除指令。
  Future<void> deleteInstructionSet(String id) async {
    final db = await database;
    await db.delete('instruction_sets', where: 'id = ?', whereArgs: [id]);
  }
}
