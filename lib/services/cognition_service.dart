import '../models/cognition.dart';
import 'minds_database_service.dart';
import 'she_memory_db_service.dart';
import 'she_profile_database_service.dart';
import 'logger_service.dart';

/// 认知业务逻辑服务
///
/// 封装 [MindsDatabaseService]，对外提供与旧系统（[SheProfileDatabaseService] +
/// [SheMemoryDbService]）完全兼容的公开接口，便于零侵入地替换各调用方。
///
/// ### 职责边界
/// | 操作           | 旧位置                          | 新位置              |
/// |--------------|-------------------------------|-------------------|
/// | user_profile | SheProfileDatabaseService      | cognition_user    |
/// | soul         | SheMemoryDbService (soul key)  | cognition_self    |
/// | self_notes   | SheMemoryDbService (self_notes)| cognition_self    |
///
/// ### 使用示例
/// ```dart
/// final cognition = CognitionService.instance;
///
/// // 用户档案
/// await cognition.updateUserProfileField('name', 'Eden');
/// final profile = await cognition.getAllUserProfile();
///
/// // Soul
/// await cognition.updateAgentSoul(SheService.sheId, 'I am She…');
/// final soul = await cognition.getAgentSoul(SheService.sheId);
/// ```
class CognitionService {
  static final CognitionService instance = CognitionService._();
  CognitionService._();

  final MindsDatabaseService _db = MindsDatabaseService();

  /// She 的 agentId（user_profile 的默认所有者）
  ///
  /// 直接硬编码避免循环依赖 SheService。
  static const String _sheId = 'she-builtin-agent-001';

  /// user_profile 内部初始化标志位键名（与 SheService 保持一致）
  static const String _profileInitKey = '_initialized';

  // ---------------------------------------------------------------------------
  // Self cognition — Soul & SelfNotes
  // ---------------------------------------------------------------------------

  /// 读取指定 Agent 的 soul
  Future<String?> getAgentSoul(String agentId) async {
    final self = await _db.getSelfCognition(agentId);
    return self?.soul;
  }

  /// 写入指定 Agent 的 soul（不存在则创建）
  Future<void> updateAgentSoul(String agentId, String soul) async {
    await _db.updateSoul(agentId, soul);
    LoggerService().info('Soul updated for agent=$agentId', tag: 'CognitionService');
  }

  /// 读取指定 Agent 的 self_notes
  Future<String?> getAgentSelfNotes(String agentId) async {
    final self = await _db.getSelfCognition(agentId);
    return self?.selfNotes;
  }

  /// 写入指定 Agent 的 self_notes（不存在则创建）
  Future<void> updateAgentSelfNotes(String agentId, String selfNotes) async {
    await _db.updateSelfNotes(agentId, selfNotes);
  }

  /// 读取完整的 [SelfCognition] 对象（含 capabilities 等全部字段）
  Future<SelfCognition?> getSelfCognition(String agentId) async {
    return _db.getSelfCognition(agentId);
  }

  /// 获取所有 Agent 的自我认知列表
  Future<List<SelfCognition>> getAllAgentsMindStates() async {
    return _db.getAllSelfCognitions();
  }

  // ---------------------------------------------------------------------------
  // User cognition — User Profile
  //
  // She 是 user_profile 的默认维护者；所有方法默认使用 _sheId 作为 agentId。
  // ---------------------------------------------------------------------------

  /// 用户档案是否已初始化（`_initialized == 'true'`）
  Future<bool> isUserProfileInitialized() async {
    final flag = await _db.getUserProfile(_sheId);
    return flag[_profileInitKey] == 'true';
  }

  /// 读取单个 user_profile 字段（等价于旧 getUserProfile(key)）
  Future<String?> getUserProfileField(String key) async {
    final profile = await _db.getUserProfile(_sheId);
    return profile[key];
  }

  /// 写入单个 user_profile 字段，并自动设置初始化标志位
  ///
  /// 等价于旧 `SheService.updateUserProfileField(key, value)`。
  Future<void> updateUserProfileField(String key, String value) async {
    await _db.setUserProfileField(_sheId, key, value);
    if (key != _profileInitKey) {
      await _db.setUserProfileField(_sheId, _profileInitKey, 'true');
    }
  }

  /// 批量写入 user_profile 字段，并自动设置初始化标志位
  Future<void> updateUserProfileFields(Map<String, String> fields) async {
    await _db.setUserProfileFields(_sheId, fields);
    if (fields.isNotEmpty) {
      await _db.setUserProfileField(_sheId, _profileInitKey, 'true');
    }
  }

  /// 删除单个 user_profile 字段
  Future<void> deleteUserProfileField(String key) async {
    await _db.deleteUserProfileField(_sheId, key);
  }

  /// 获取全部 user_profile KV（等价于旧 `getAllUserProfile()`）
  Future<Map<String, String>> getAllUserProfile() async {
    return _db.getUserProfile(_sheId);
  }

  /// 获取完整的 [UserCognition] 对象（含 impression / notes 等全部字段）
  Future<UserCognition?> getUserCognition(String agentId) async {
    return _db.getUserCognition(agentId);
  }

  /// 写入 Agent 对用户的主观印象
  Future<void> updateUserImpression(String agentId, String impression) async {
    await _db.updateUserImpression(agentId, impression);
  }

  /// 写入 Agent 对用户的笔记
  Future<void> updateUserNotes(String agentId, String notes) async {
    final existing = await _db.getUserCognition(agentId);
    if (existing == null) {
      await _db.setUserCognition(UserCognition(
        agentId: agentId,
        userProfile: {},
        userNotes: notes,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      await _db.setUserCognition(existing.copyWith(userNotes: notes));
    }
  }

  // ---------------------------------------------------------------------------
  // 迁移工具
  // ---------------------------------------------------------------------------

  /// 从旧系统迁移数据到 minds.db（一次性、幂等）
  ///
  /// 迁移范围：
  ///   1. `she_memory.db` → `soul` / `self_notes` → `cognition_self`
  ///   2. `she_profile.db` → `user_profile` → `cognition_user`
  ///
  /// 迁移策略：**仅在目标数据为空时才写入**，不覆盖已有数据。
  Future<void> migrateFromLegacy() async {
    try {
      await _migrateSheMemoryToSelf();
      await _migrateProfileToUser();
      LoggerService().info('Legacy cognition migration completed', tag: 'CognitionService');
    } catch (e, st) {
      LoggerService().error(
        'Legacy cognition migration failed: $e',
        tag: 'CognitionService',
        stackTrace: st,
      );
    }
  }

  /// 将 she_memory.db 中的 soul / self_notes 迁移到 cognition_self
  Future<void> _migrateSheMemoryToSelf() async {
    final existing = await _db.getSelfCognition(_sheId);
    if (existing != null && existing.soul.isNotEmpty) {
      // 目标已有数据，跳过
      return;
    }

    final sheMemDb = SheMemoryDbService.instance;
    final soul = await sheMemDb.getSheMemory('soul');
    final selfNotes = await sheMemDb.getSheMemory('self_notes');

    if (soul != null && soul.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.setSelfCognition(SelfCognition(
        agentId: _sheId,
        soul: soul,
        selfNotes: selfNotes,
        createdAt: now,
        updatedAt: now,
      ));
      LoggerService().info(
        'Migrated soul & self_notes from she_memory.db',
        tag: 'CognitionService',
      );
    }
  }

  /// 将 she_profile.db 的 user_profile 迁移到 cognition_user
  Future<void> _migrateProfileToUser() async {
    final existingProfile = await _db.getUserProfile(_sheId);
    if (existingProfile.isNotEmpty) {
      // 目标已有数据，跳过
      return;
    }

    final profileDb = SheProfileDatabaseService();
    final legacyProfile = await profileDb.getAllUserProfile();
    if (legacyProfile.isNotEmpty) {
      await _db.setUserProfileFields(_sheId, legacyProfile);
      LoggerService().info(
        'Migrated ${legacyProfile.length} user_profile fields from she_profile.db',
        tag: 'CognitionService',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 清理
  // ---------------------------------------------------------------------------

  /// 清空 She 的 user_profile（与旧 SheProfileDatabaseService.clearUserProfile() 等价）
  Future<void> clearUserProfile() async {
    await _db.deleteUserCognition(_sheId);
  }

  /// 清空所有认知数据
  Future<void> clearAll() async => _db.clearAll();

  /// 清空单个 Agent 的认知数据
  Future<void> clearAgent(String agentId) async => _db.clearAgent(agentId);
}
