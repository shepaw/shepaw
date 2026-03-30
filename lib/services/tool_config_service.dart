import 'dart:convert';

import '../models/tool_config.dart';
import 'local_database_service.dart';
import 'secure_key_manager.dart';

/// 工具配置业务服务
///
/// 职责分层：
/// - 非敏感配置（enabled, parameterOverrides, note 等）→ SQLite (tool_configs 表)
/// - 敏感 API Key → flutter_secure_storage（通过 SecureKeyManager）
///
/// 使用单例模式，与项目其他服务保持一致。
class ToolConfigService {
  ToolConfigService._();
  static final ToolConfigService instance = ToolConfigService._();

  final _db = LocalDatabaseService();

  // ── API Key 操作（SecureKeyManager）─────────────────────────────────────

  /// 获取工具的 API Key（解密）
  Future<String?> getToolApiKey(String toolName) async {
    final storageKey = SecureKeyManager.toolApiKeyStorageKey(toolName);
    return SecureKeyManager.getSecureValue(storageKey);
  }

  /// 设置工具的 API Key（加密存储）
  ///
  /// 同时更新数据库中的 has_api_key 标志
  Future<void> setToolApiKey(String toolName, String apiKey) async {
    final storageKey = SecureKeyManager.toolApiKeyStorageKey(toolName);
    await SecureKeyManager.saveSecureValue(storageKey, apiKey);

    // 同步更新或创建数据库记录，标记 has_api_key = true
    final existing = await _db.queryToolConfig(toolName);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing == null) {
      await _db.upsertToolConfig({
        'tool_name': toolName,
        'has_api_key': 1,
        'parameter_overrides': null,
        'enabled': 1,
        'she_exclusive': 0,
        'note': null,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await _db.upsertToolConfig({
        ...existing,
        'has_api_key': 1,
        'updated_at': now,
      });
    }
  }

  /// 删除工具的 API Key
  ///
  /// 同时更新数据库中的 has_api_key 标志
  Future<void> deleteToolApiKey(String toolName) async {
    final storageKey = SecureKeyManager.toolApiKeyStorageKey(toolName);
    await SecureKeyManager.deleteSecureValue(storageKey);

    // 同步更新数据库
    final existing = await _db.queryToolConfig(toolName);
    if (existing != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.upsertToolConfig({
        ...existing,
        'has_api_key': 0,
        'updated_at': now,
      });
    }
  }

  // ── 配置 CRUD（LocalDatabaseService）──────────────────────────────────────

  /// 保存（创建或更新）工具配置
  ///
  /// 只更新传入的非空字段，未传入的字段保留原值。
  Future<ToolConfig> saveToolConfig(
    String toolName, {
    Map<String, dynamic>? parameterOverrides,
    bool? enabled,
    bool? sheExclusive,
    String? note,
    bool clearParameterOverrides = false,
    bool clearNote = false,
  }) async {
    final existing = await _db.queryToolConfig(toolName);
    final now = DateTime.now().millisecondsSinceEpoch;

    late final Map<String, dynamic> data;
    if (existing == null) {
      data = {
        'tool_name': toolName,
        'has_api_key': 0,
        'parameter_overrides': clearParameterOverrides
            ? null
            : (parameterOverrides != null ? jsonEncode(parameterOverrides) : null),
        'enabled': (enabled ?? true) ? 1 : 0,
        'she_exclusive': (sheExclusive ?? false) ? 1 : 0,
        'note': clearNote ? null : note,
        'created_at': now,
        'updated_at': now,
      };
    } else {
      data = {
        ...existing,
        'updated_at': now,
      };
      if (clearParameterOverrides) {
        data['parameter_overrides'] = null;
      } else if (parameterOverrides != null) {
        data['parameter_overrides'] = jsonEncode(parameterOverrides);
      }
      if (enabled != null) data['enabled'] = enabled ? 1 : 0;
      if (sheExclusive != null) data['she_exclusive'] = sheExclusive ? 1 : 0;
      if (clearNote) {
        data['note'] = null;
      } else if (note != null) {
        data['note'] = note;
      }
    }

    await _db.upsertToolConfig(data);
    return ToolConfig.fromJson(data);
  }

  /// 获取单个工具配置
  ///
  /// 若数据库中无记录，返回 null（工具尚未配置）。
  Future<ToolConfig?> getToolConfig(String toolName) async {
    final row = await _db.queryToolConfig(toolName);
    return row == null ? null : ToolConfig.fromJson(row);
  }

  /// 获取所有已配置的工具
  Future<List<ToolConfig>> getAllToolConfigs() async {
    final rows = await _db.queryAllToolConfigs();
    return rows.map(ToolConfig.fromJson).toList();
  }

  /// 删除工具配置（同时删除对应的 API Key）
  Future<void> deleteToolConfig(String toolName) async {
    // 先删除 secure storage 中的 API Key
    final storageKey = SecureKeyManager.toolApiKeyStorageKey(toolName);
    await SecureKeyManager.deleteSecureValue(storageKey);

    // 再删除数据库记录
    await _db.deleteToolConfig(toolName);
  }

  // ── 便捷查询 ──────────────────────────────────────────────────────────────

  /// 获取工具配置的参数覆盖（已解析为 Map，无则返回 null）
  Future<Map<String, dynamic>?> getParameterOverrides(String toolName) async {
    final config = await getToolConfig(toolName);
    return config?.parameterOverrides;
  }

  /// 工具是否已配置（存在配置记录）
  Future<bool> hasConfig(String toolName) async {
    final config = await getToolConfig(toolName);
    return config != null;
  }
}
