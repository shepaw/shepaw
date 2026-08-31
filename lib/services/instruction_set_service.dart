import 'package:uuid/uuid.dart';

import '../models/instruction_set.dart';
import 'local_database_service.dart';
import 'she_service.dart';

/// 指令集业务服务：管理可复用的任务指令。
///
/// 每个指令记录生成它的 agent（[InstructionSet.ownerAgentId]），
/// 执行时自动路由回该 agent。存储于 `shepaw.db` 的 `instruction_sets` 表。
///
/// 使用单例模式，与项目其他服务保持一致。
class InstructionSetService {
  InstructionSetService._();
  static final InstructionSetService instance = InstructionSetService._();

  static const String table = 'instruction_sets';

  /// 内置系统指令：首次访问时自动播种，无需用户手动创建。
  static const String systemInstructionName = '沉淀指令';
  static const String systemInstructionContent =
      '将最近的任务总结为一个指令，方便下次唤醒你完成相同任务时，你能够直接理解';

  final LocalDatabaseService _db = LocalDatabaseService();
  static const Uuid _uuid = Uuid();

  /// 列出全部指令，可按 owner 过滤（更新时间倒序）。
  /// 每次读取都会确保内置系统指令存在（幂等）。
  Future<List<InstructionSet>> list({String? ownerAgentId}) async {
    await seedSystemInstructions();
    return _db.queryAllInstructionSets(ownerAgentId: ownerAgentId);
  }

  /// 播种内置系统指令（幂等：按名称查询，不存在才创建）。
  ///
  /// 系统指令归属 She：从指令集执行时会路由到 She 的会话并预填内容。
  /// 播种失败（如数据库尚未就绪）不阻塞列表读取。
  Future<void> seedSystemInstructions() async {
    try {
      final existing = await _db.queryInstructionSetByName(systemInstructionName);
      if (existing != null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.upsertInstructionSet(
        InstructionSet(
          id: _uuid.v4(),
          name: systemInstructionName,
          content: systemInstructionContent,
          ownerAgentId: SheService.sheId,
          ownerAgentName: SheService.sheName,
          createdAt: now,
          updatedAt: now,
        ).toRow(),
      );
    } catch (_) {
      // 播种失败不阻塞指令集列表。
    }
  }

  /// 按主键查询。
  Future<InstructionSet?> getById(String id) =>
      _db.queryInstructionSetById(id);

  /// 按唯一名称查询。
  Future<InstructionSet?> getByName(String name) =>
      _db.queryInstructionSetByName(name);

  /// 新建指令。name 已存在时抛 [InstructionSetNameTaken]（CLI 应引导更新）。
  Future<InstructionSet> create({
    required String name,
    String? description,
    required String content,
    required String ownerAgentId,
    String ownerAgentName = '',
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('instruction name cannot be empty');
    }
    if (content.trim().isEmpty) {
      throw ArgumentError('instruction content cannot be empty');
    }
    final existing = await _db.queryInstructionSetByName(trimmedName);
    if (existing != null) {
      throw InstructionSetNameTaken(trimmedName);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = InstructionSet(
      id: _uuid.v4(),
      name: trimmedName,
      description: _clean(description),
      content: content.trim(),
      ownerAgentId: ownerAgentId,
      ownerAgentName: ownerAgentName,
      createdAt: now,
      updatedAt: now,
    );
    await _db.upsertInstructionSet(entry.toRow());
    return entry;
  }

  /// 更新已有指令（描述传空字符串可清空）。
  Future<InstructionSet> update({
    required String id,
    String? name,
    String? description,
    String? content,
  }) async {
    final existing = await _db.queryInstructionSetById(id);
    if (existing == null) {
      throw StateError('instruction not found: $id');
    }

    final newName = (name ?? existing.name).trim();
    if (newName.isEmpty) {
      throw ArgumentError('instruction name cannot be empty');
    }
    // 重名检查（排除自身）
    if (newName != existing.name) {
      final clash = await _db.queryInstructionSetByName(newName);
      if (clash != null && clash.id != id) {
        throw InstructionSetNameTaken(newName);
      }
    }

    // 描述：传空字符串表示清空；传 null 表示保持原值。
    String? newDescription;
    var clearDescription = false;
    if (description != null) {
      newDescription = _clean(description);
      clearDescription = newDescription == null;
    } else {
      newDescription = existing.description;
    }

    final updated = existing.copyWith(
      name: newName,
      description: newDescription,
      clearDescription: clearDescription,
      content: content?.trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.upsertInstructionSet(updated.toRow());
    return updated;
  }

  /// 删除指令。
  Future<void> delete(String id) async {
    await _db.deleteInstructionSet(id);
  }

  String? _clean(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}

/// name 已被占用（新建时撞名）。
class InstructionSetNameTaken implements Exception {
  InstructionSetNameTaken(this.name);
  final String name;
  @override
  String toString() => 'An instruction named "$name" already exists. '
      'Use update to modify it, or pick another name.';
}
