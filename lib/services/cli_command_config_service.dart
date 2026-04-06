import '../models/cli_command_config.dart';
import 'local_database_service.dart';
import 'she_service.dart';

/// CLI 命令配置业务服务
///
/// 管理 CLI 命令的全局启用/禁用状态和 She 专属开关。
/// 配置存储于 shepaw.db 的 cli_command_configs 表中。
///
/// 使用单例模式，与项目其他服务保持一致。
class CliCommandConfigService {
  CliCommandConfigService._();
  static final CliCommandConfigService instance = CliCommandConfigService._();

  final _db = LocalDatabaseService();

  // ── 配置 CRUD ──────────────────────────────────────────────────────────────

  /// 保存（创建或更新）CLI 命令配置
  Future<CliCommandConfig> saveConfig(
    String commandId, {
    bool? globalEnabled,
    bool? sheOnly,
    String? note,
    bool clearNote = false,
  }) async {
    final existing = await _db.queryCliCommandConfig(commandId);
    final now = DateTime.now().millisecondsSinceEpoch;

    late final Map<String, dynamic> data;
    if (existing == null) {
      data = {
        'command_id': commandId,
        'global_enabled': (globalEnabled ?? true) ? 1 : 0,
        'she_only': (sheOnly ?? false) ? 1 : 0,
        'note': clearNote ? null : note,
        'created_at': now,
        'updated_at': now,
      };
    } else {
      data = {
        ...existing,
        'updated_at': now,
      };
      if (globalEnabled != null) data['global_enabled'] = globalEnabled ? 1 : 0;
      if (sheOnly != null) data['she_only'] = sheOnly ? 1 : 0;
      if (clearNote) {
        data['note'] = null;
      } else if (note != null) {
        data['note'] = note;
      }
    }

    await _db.upsertCliCommandConfig(data);
    return CliCommandConfig.fromJson(data);
  }

  /// 获取单个命令配置
  ///
  /// 若数据库中无记录，返回默认配置（globalEnabled=true, sheOnly=false）。
  Future<CliCommandConfig> getConfig(String commandId) async {
    final row = await _db.queryCliCommandConfig(commandId);
    if (row != null) return CliCommandConfig.fromJson(row);

    // 未找到配置时返回默认值
    final now = DateTime.now().millisecondsSinceEpoch;
    return CliCommandConfig(
      commandId: commandId,
      globalEnabled: true,
      sheOnly: false,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 获取所有已配置的命令
  Future<List<CliCommandConfig>> getAllConfigs() async {
    final rows = await _db.queryAllCliCommandConfigs();
    return rows.map(CliCommandConfig.fromJson).toList();
  }

  /// 删除命令配置（恢复为默认值）
  Future<void> deleteConfig(String commandId) async {
    await _db.deleteCliCommandConfig(commandId);
  }

  // ── 层级查询 ────────────────────────────────────────────────────────────────

  /// 获取某个命令 ID 从根到叶的全部层级配置
  ///
  /// 例如 'context.profile.query' 返回
  /// ['context', 'context.profile', 'context.profile.query'] 三层各自的配置。
  /// 如果某一层无自定义配置，会返回默认值（globalEnabled=true, sheOnly=false）。
  Future<List<CliCommandConfig>> getHierarchyConfigs(String commandId) async {
    final segments = commandId.split('.');
    final configs = <CliCommandConfig>[];
    for (var i = 1; i <= segments.length; i++) {
      final id = segments.take(i).join('.');
      configs.add(await getConfig(id));
    }
    return configs;
  }

  /// 查找第一个限制了当前命令 ID 的祖先配置（不包含自身）
  ///
  /// 返回 null 表示没有祖先层级施加限制。
  /// 返回 (ancestorId, config) 表示该祖先层级禁用了全局开关或设置了 She 专属。
  Future<({String id, CliCommandConfig config})?> findRestrictingAncestor(
    String commandId,
  ) async {
    final segments = commandId.split('.');
    // 只检查祖先，不含自身 → i < segments.length
    for (var i = 1; i < segments.length; i++) {
      final id = segments.take(i).join('.');
      final config = await getConfig(id);
      if (!config.globalEnabled || config.sheOnly) {
        return (id: id, config: config);
      }
    }
    return null;
  }

  // ── 权限检查 ────────────────────────────────────────────────────────────────

  /// 检查 CLI 命令是否可被指定的调用者执行
  ///
  /// 支持命名空间级别的继承：
  /// - 'context.profile.query' 会依次检查 'context', 'context.profile',
  ///   'context.profile.query' 三层配置
  /// - 任意层级 globalEnabled=false 则拒绝
  /// - 任意层级 sheOnly=true 且非 She 则拒绝
  ///
  /// [commandId] 命令 ID（如 'context.profile.query'）
  /// [agentId] 当前调用者的 Agent ID（用于推断是否为 She）
  ///
  /// 返回 null 表示允许执行，返回 String 表示拒绝原因。
  Future<String?> checkPermission(String commandId, {String agentId = SheService.sheId}) async {
    final isShe = agentId == SheService.sheId;

    // 构建所有需要检查的层级 IDs
    // 例：'context.profile.query' → ['context', 'context.profile', 'context.profile.query']
    final segments = commandId.split('.');
    final idsToCheck = <String>[];
    for (var i = 1; i <= segments.length; i++) {
      idsToCheck.add(segments.take(i).join('.'));
    }

    for (final id in idsToCheck) {
      final config = await getConfig(id);

      if (!config.globalEnabled) {
        return 'Command "$commandId" is disabled (namespace "$id" is globally disabled).';
      }

      if (config.sheOnly && !isShe) {
        return 'Command "$commandId" is restricted to She only (namespace "$id" is She-only).';
      }
    }

    return null; // 允许执行
  }

  // ── 批量查询（用于系统提示词过滤）──────────────────────────────────────────

  /// 获取所有配置的 Map（commandId → CliCommandConfig）
  ///
  /// 用于在系统提示词生成时批量过滤命令。
  Future<Map<String, CliCommandConfig>> getAllConfigsMap() async {
    final all = await getAllConfigs();
    return {for (final c in all) c.commandId: c};
  }
}
