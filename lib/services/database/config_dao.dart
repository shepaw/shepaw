import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../local_database_service.dart';

/// 杂项配置类数据访问层：用户 KV、资源文件、工具配置、CLI 命令配置。
extension ConfigDao on LocalDatabaseService {
  // ==================== 用户敏感信息（KV） ====================

  /// 写入用户敏感信息（key-value）
  Future<void> setUserValue(String key, String value) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'user',
      {
        'key': key,
        'value': value,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取用户敏感信息
  Future<String?> getUserValue(String key) async {
    final db = await database;
    final results = await db.query(
      'user',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    return results.isEmpty ? null : results.first['value'] as String?;
  }

  /// 删除某个用户敏感信息 key
  Future<void> deleteUserValue(String key) async {
    final db = await database;
    await db.delete('user', where: 'key = ?', whereArgs: [key]);
  }

  /// 获取所有用户敏感信息 KV 对
  Future<Map<String, String>> getAllUserValues() async {
    final db = await database;
    final results = await db.query('user');
    return {
      for (final row in results)
        row['key'] as String: row['value'] as String,
    };
  }

  /// 清空所有用户敏感信息
  Future<void> clearUserValues() async {
    final db = await database;
    await db.delete('user');
  }

  // ==================== 资源文件操作 ====================

  /// 创建资源记录
  Future<void> createResource({
    required String id,
    required String name,
    required String filePath,
    required String fileType,
    required int fileSize,
    String? mimeType,
    String? thumbnailPath,
    required String ownerId,
    required String ownerType,
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    await db.insert(
      'resources',
      {
        'id': id,
        'name': name,
        'file_path': filePath,
        'file_type': fileType,
        'file_size': fileSize,
        'mime_type': mimeType,
        'thumbnail_path': thumbnailPath,
        'owner_id': ownerId,
        'owner_type': ownerType,
        'created_at': DateTime.now().toIso8601String(),
        'metadata': metadata != null ? jsonEncode(metadata) : null,
      },
    );
  }

  /// 根据 Owner 获取资源
  Future<List<Map<String, dynamic>>> getResourcesByOwner(String ownerId, String ownerType) async {
    final db = await database;
    return await db.query(
      'resources',
      where: 'owner_id = ? AND owner_type = ?',
      whereArgs: [ownerId, ownerType],
      orderBy: 'created_at DESC',
    );
  }

  /// 删除资源记录
  Future<void> deleteResource(String id) async {
    final db = await database;
    await db.delete('resources', where: 'id = ?', whereArgs: [id]);
  }

  // ==================== 工具配置 CRUD ====================

  /// 插入或更新工具配置（upsert）
  Future<void> upsertToolConfig(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'tool_configs',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 查询单个工具配置
  Future<Map<String, dynamic>?> queryToolConfig(String toolName) async {
    final db = await database;
    final results = await db.query(
      'tool_configs',
      where: 'tool_name = ?',
      whereArgs: [toolName],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 查询所有工具配置
  Future<List<Map<String, dynamic>>> queryAllToolConfigs() async {
    final db = await database;
    return db.query('tool_configs', orderBy: 'tool_name ASC');
  }

  /// 删除工具配置
  Future<void> deleteToolConfig(String toolName) async {
    final db = await database;
    await db.delete(
      'tool_configs',
      where: 'tool_name = ?',
      whereArgs: [toolName],
    );
  }

  // ==================== CLI 命令配置 CRUD ====================

  /// 插入或更新 CLI 命令配置（upsert）
  Future<void> upsertCliCommandConfig(Map<String, dynamic> data) async {
    final db = await database;
    await db.insert(
      'cli_command_configs',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 查询单个 CLI 命令配置
  Future<Map<String, dynamic>?> queryCliCommandConfig(String commandId) async {
    final db = await database;
    final results = await db.query(
      'cli_command_configs',
      where: 'command_id = ?',
      whereArgs: [commandId],
      limit: 1,
    );
    return results.isEmpty ? null : results.first;
  }

  /// 查询所有 CLI 命令配置
  Future<List<Map<String, dynamic>>> queryAllCliCommandConfigs() async {
    final db = await database;
    return db.query('cli_command_configs', orderBy: 'command_id ASC');
  }

  /// 删除 CLI 命令配置
  Future<void> deleteCliCommandConfig(String commandId) async {
    final db = await database;
    await db.delete(
      'cli_command_configs',
      where: 'command_id = ?',
      whereArgs: [commandId],
    );
  }
}
